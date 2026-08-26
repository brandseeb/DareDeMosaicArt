import Foundation
import AVFoundation
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// タイムラプス動画エクスポートのエラー
public enum TimelapseExportError: LocalizedError, Sendable {
    case uncompletedProject
    case cancelled
    case writerCreationFailed(String)
    case encodingFailed(String)
    case contextCreationFailed
    
    public var errorDescription: String? {
        switch self {
        case .uncompletedProject:
            return "すべてのピースが埋まると制作タイムラプス動画を作成できます。"
        case .cancelled:
            return "動画の作成がキャンセルされました。"
        case .writerCreationFailed(let msg):
            return "動画ライターの初期化に失敗しました: \(msg)"
        case .encodingFailed(let msg):
            return "動画のエンコードに失敗しました: \(msg)"
        case .contextCreationFailed:
            return "描画コンテキストの作成に失敗しました。"
        }
    }
}

/// タイムラプス動画生成サービス（Xcode 26 / iOS 17〜25 互換・累積描画・キャンセル対応）
public final class TimelapseExportService: Sendable {
    public static let shared = TimelapseExportService()
    
    public static let videoDimension: Int = 1080
    
    private init() {}
    
    // MARK: - 古い一時 MP4 ファイルの自動清掃（アプリ起動時に呼び出し）
    public static func cleanupOldTemporaryFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return }
        
        let thresholdDate = Date().addingTimeInterval(-24 * 3600) // 24時間以上前の一時ファイル
        for file in files where file.pathExtension.lowercased() == "mp4" && file.lastPathComponent.hasPrefix("timelapse-") {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let creationDate = attrs[.creationDate] as? Date,
               creationDate < thresholdDate {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    // MARK: - タイムラプス動画の生成
    public func exportTimelapse(
        project: MosaicProject,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        guard project.isCompleted else {
            throw TimelapseExportError.uncompletedProject
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelapse-\(UUID().uuidString).mp4")
        
        // 生成中にキャンセルや例外が発生した場合は一時ファイルを確実に削除
        do {
            try await renderVideo(project: project, outputURL: outputURL, onProgress: onProgress)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
    
    private func renderVideo(
        project: MosaicProject,
        outputURL: URL,
        onProgress: (@Sendable (Float) -> Void)?
    ) async throws {
        let dimension = Self.videoDimension
        let totalTiles = project.tiles.count
        let timeline = TimelapseTimeline(totalTilesCount: totalTiles)
        let sortedTiles = TimelapseTimeline.sortTilesInSequence(project.tiles)
        
        // 1. 各タイル画像を 1080p の 1 マス分に事前リサイズ・キャッシュ (O(N) で1回のみ)
        let tilePixelWidth = CGFloat(dimension) / CGFloat(max(1, project.gridWidth))
        let tilePixelHeight = CGFloat(dimension) / CGFloat(max(1, project.gridHeight))
        
        let identifiers = sortedTiles.compactMap(\.placedPhotoIdentifier)
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        
        var cachedTileCGImages: [UUID: CGImage] = [:]
        cachedTileCGImages.reserveCapacity(sortedTiles.count)
        
        for tile in sortedTiles {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            
            let tileImage: UIImage?
            if let identifier = tile.placedPhotoIdentifier, let asset = assetsByIdentifier[identifier] {
                tileImage = await requestImageForTimelapse(for: asset, targetPixels: max(tilePixelWidth, tilePixelHeight) * 1.5)
            } else if let data = tile.thumbnailData {
                tileImage = UIImage(data: data)
            } else {
                tileImage = nil
            }
            
            if let tileImage, let cg = ImageUtils.normalizeOrientationAndFit(image: tileImage, maxDimension: CGFloat(max(tilePixelWidth, tilePixelHeight) * 1.5)).cgImage {
                cachedTileCGImages[tile.id] = cg
            }
        }
        
        // 2. AVAssetWriter のセットアップ
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw TimelapseExportError.writerCreationFailed(error.localizedDescription)
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimension,
            AVVideoHeightKey: dimension,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000, // 8 Mbps 高画質
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: dimension,
            kCVPixelBufferHeightKey as String: dimension,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        guard writer.canAdd(writerInput) else {
            throw TimelapseExportError.writerCreationFailed("Writer cannot add input")
        }
        writer.add(writerInput)
        
        guard writer.startWriting() else {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "Start writing failed")
        }
        writer.startSession(atSourceTime: .zero)
        
        // 3. 累積オフスクリーン描画コンテキスト（1080×1080）の準備
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let baseContext = CGContext(
                data: nil,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw TimelapseExportError.contextCreationFailed
        }
        
        // 背景を薄いグレーで初期化
        baseContext.setFillColor(UIColor(white: 0.15, alpha: 1.0).cgColor)
        baseContext.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        
        // ガイド元画像をうっすら背景に描画
        if !project.targetImageData.isEmpty, let targetUI = UIImage(data: project.targetImageData), let targetCG = targetUI.cgImage {
            baseContext.saveGState()
            baseContext.setAlpha(0.12)
            baseContext.draw(targetCG, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            baseContext.restoreGState()
        }
        
        // グリッド線の描画
        baseContext.setStrokeColor(UIColor(white: 0.25, alpha: 0.5).cgColor)
        baseContext.setLineWidth(1.0)
        for x in 0...project.gridWidth {
            let px = CGFloat(x) * tilePixelWidth
            baseContext.move(to: CGPoint(x: px, y: 0))
            baseContext.addLine(to: CGPoint(x: px, y: CGFloat(dimension)))
        }
        for y in 0...project.gridHeight {
            let py = CGFloat(y) * tilePixelHeight
            baseContext.move(to: CGPoint(x: 0, y: py))
            baseContext.addLine(to: CGPoint(x: CGFloat(dimension), y: py))
        }
        baseContext.strokePath()
        
        guard let pool = adaptor.pixelBufferPool else {
            throw TimelapseExportError.encodingFailed("PixelBufferPool is nil")
        }
        
        let fps = TimelapseTimeline.fps
        let timescale: Int32 = 600
        let frameDuration = CMTime(value: Int64(timescale / fps), timescale: timescale)
        var currentPresentationTime = CMTime.zero
        
        var globalFrame = 0
        let totalFramesCount = TimelapseTimeline.totalFrames
        
        // -------------------------------------------------------------
        // フェーズ1: オープニング (30フレーム = 1.0秒)
        // -------------------------------------------------------------
        for _ in 0..<TimelapseTimeline.openingFrames {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            
            try await appendFrame(
                context: baseContext,
                adaptor: adaptor,
                input: writerInput,
                pool: pool,
                at: currentPresentationTime
            )
            currentPresentationTime = CMTimeAdd(currentPresentationTime, frameDuration)
            globalFrame += 1
            onProgress?(Float(globalFrame) / Float(totalFramesCount))
        }
        
        // -------------------------------------------------------------
        // フェーズ2: ビルドフェーズ (210フレーム = 7.0秒)
        // -------------------------------------------------------------
        for buildFrame in 0..<TimelapseTimeline.buildFrames {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            
            let range = timeline.newTileRange(forBuildFrame: buildFrame)
            if !range.isEmpty {
                for tileIndex in range {
                    let tile = sortedTiles[tileIndex]
                    let rect = CGRect(
                        x: CGFloat(tile.gridX) * tilePixelWidth,
                        y: CGFloat(project.gridHeight - tile.gridY - 1) * tilePixelHeight,
                        width: tilePixelWidth,
                        height: tilePixelHeight
                    )
                    
                    // タイル色塗り
                    baseContext.setFillColor(tile.targetLabColor.uiColor.cgColor)
                    baseContext.fill(rect)
                    
                    // タイル写真描画
                    if let cgImage = cachedTileCGImages[tile.id] {
                        baseContext.saveGState()
                        baseContext.clip(to: rect)
                        baseContext.draw(cgImage, in: rect)
                        baseContext.restoreGState()
                    }
                }
            }
            
            try await appendFrame(
                context: baseContext,
                adaptor: adaptor,
                input: writerInput,
                pool: pool,
                at: currentPresentationTime
            )
            currentPresentationTime = CMTimeAdd(currentPresentationTime, frameDuration)
            globalFrame += 1
            onProgress?(Float(globalFrame) / Float(totalFramesCount))
        }
        
        // -------------------------------------------------------------
        // フェーズ3: フィナーレ (60フレーム = 2.0秒)
        // 最初の30フレームで刻印がフェードイン、後半30フレームで完成静止
        // -------------------------------------------------------------
        let watermarkConfig = project.watermarkConfig
        
        for finaleFrame in 0..<TimelapseTimeline.finaleFrames {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            
            let watermarkAlpha: CGFloat
            if finaleFrame < 30 {
                watermarkAlpha = CGFloat(finaleFrame + 1) / 30.0
            } else {
                watermarkAlpha = 1.0
            }
            
            // 刻印がある場合は一時コンテキストにコピーして重ね合わせ
            if let watermarkConfig, !watermarkConfig.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let finaleContext = CGContext(
                    data: nil,
                    width: dimension,
                    height: dimension,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ), let baseSnapshot = baseContext.makeImage() else {
                    throw TimelapseExportError.contextCreationFailed
                }
                
                finaleContext.draw(baseSnapshot, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
                drawWatermarkOverlay(context: finaleContext, config: watermarkConfig, dimension: CGFloat(dimension), alpha: watermarkAlpha)
                
                try await appendFrame(
                    context: finaleContext,
                    adaptor: adaptor,
                    input: writerInput,
                    pool: pool,
                    at: currentPresentationTime
                )
            } else {
                try await appendFrame(
                    context: baseContext,
                    adaptor: adaptor,
                    input: writerInput,
                    pool: pool,
                    at: currentPresentationTime
                )
            }
            
            currentPresentationTime = CMTimeAdd(currentPresentationTime, frameDuration)
            globalFrame += 1
            onProgress?(Float(globalFrame) / Float(totalFramesCount))
        }
        
        // 4. エンコードの完了待機
        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        if writer.status != .completed {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "Finalize failed")
        }
    }
    
    // MARK: - フレームの書き込み
    private func appendFrame(
        context: CGContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        pool: CVPixelBufferPool,
        at time: CMTime
    ) async throws {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms待機
        }
        
        var pixelBufferOut: CVPixelBuffer? = nil
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw TimelapseExportError.encodingFailed("Failed to allocate pixel buffer from pool")
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer),
              let contextData = context.data else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw TimelapseExportError.encodingFailed("Failed to access buffer bytes")
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let contextBytesPerRow = context.bytesPerRow
        let height = context.height
        
        if bytesPerRow == contextBytesPerRow {
            memcpy(pixelData, contextData, bytesPerRow * height)
        } else {
            for y in 0..<height {
                let dest = pixelData.advanced(by: y * bytesPerRow)
                let src = contextData.advanced(by: y * contextBytesPerRow)
                memcpy(dest, src, min(bytesPerRow, contextBytesPerRow))
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        if !adaptor.append(pixelBuffer, withPresentationTime: time) {
            throw TimelapseExportError.encodingFailed("Failed to append pixel buffer at time: \(time.seconds)")
        }
    }
    
    // MARK: - 刻印オーバーレイ描画
    private func drawWatermarkOverlay(
        context: CGContext,
        config: WatermarkConfig,
        dimension: CGFloat,
        alpha: CGFloat
    ) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        
        let text = sanitizeWatermarkText(config.text)
        let fontSize: CGFloat = dimension * 0.024
        let font: UIFont
        switch config.fontDesign {
        case .standard: font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        case .serif: font = UIFont.systemFont(ofSize: fontSize, weight: .medium).fontDescriptor.withDesign(.serif).flatMap { UIFont(descriptor: $0, size: fontSize) } ?? UIFont.systemFont(ofSize: fontSize, weight: .medium)
        case .monospaced: font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        case .rounded: font = UIFont.systemFont(ofSize: fontSize, weight: .medium).fontDescriptor.withDesign(.rounded).flatMap { UIFont(descriptor: $0, size: fontSize) } ?? UIFont.systemFont(ofSize: fontSize, weight: .medium)
        }
        
        let textColor: UIColor
        switch config.colorStyle {
        case .whiteWithShadow: textColor = UIColor.white.withAlphaComponent(alpha)
        case .blackWithShadow: textColor = UIColor.black.withAlphaComponent(alpha)
        case .gold: textColor = UIColor(red: 0.95, green: 0.80, blue: 0.40, alpha: alpha)
        }
        
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7 * alpha)
        shadow.shadowOffset = CGSize(width: 2, height: 2)
        shadow.shadowBlurRadius = 4
        
        let paragraphStyle = NSMutableParagraphStyle()
        switch config.position {
        case .bottomRight: paragraphStyle.alignment = .right
        case .bottomLeft: paragraphStyle.alignment = .left
        case .bottomCenter, .footerBar: paragraphStyle.alignment = .center
        }
        paragraphStyle.lineBreakMode = .byTruncatingTail
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .shadow: shadow,
            .paragraphStyle: paragraphStyle
        ]
        
        let margin: CGFloat = dimension * 0.03
        let maxTextWidth = dimension - (margin * 2)
        let textRectBounding = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: fontSize * 2.6),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        
        let textRect: CGRect
        switch config.position {
        case .footerBar:
            let barHeight: CGFloat = textRectBounding.height + margin * 1.5
            let barRect = CGRect(x: 0, y: dimension - barHeight, width: dimension, height: barHeight)
            context.setFillColor(UIColor.black.withAlphaComponent(0.65 * alpha).cgColor)
            context.fill(barRect)
            textRect = CGRect(
                x: (dimension - textRectBounding.width) / 2,
                y: dimension - barHeight + (barHeight - textRectBounding.height) / 2,
                width: textRectBounding.width,
                height: textRectBounding.height
            )
        case .bottomRight:
            textRect = CGRect(
                x: dimension - margin - textRectBounding.width,
                y: dimension - margin - textRectBounding.height,
                width: textRectBounding.width,
                height: textRectBounding.height
            )
        case .bottomLeft:
            textRect = CGRect(
                x: margin,
                y: dimension - margin - textRectBounding.height,
                width: textRectBounding.width,
                height: textRectBounding.height
            )
        case .bottomCenter:
            textRect = CGRect(
                x: (dimension - textRectBounding.width) / 2,
                y: dimension - margin - textRectBounding.height,
                width: textRectBounding.width,
                height: textRectBounding.height
            )
        }
        
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
    
    private func requestImageForTimelapse(for asset: PHAsset, targetPixels: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let gate = TimelapseImageGate(continuation)
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetPixels, height: targetPixels),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    gate.resume(with: nil)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                gate.resume(with: image)
            }
        }
    }
}

private func sanitizeWatermarkText(_ rawText: String) -> String {
    let lines = rawText.components(separatedBy: "\n")
    let limitedLines = lines.prefix(2)
    let joined = limitedLines.joined(separator: "\n")
    if joined.count > 60 {
        return String(joined.prefix(60))
    }
    return joined
}

private final class TimelapseImageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(returning: image)
    }
}
