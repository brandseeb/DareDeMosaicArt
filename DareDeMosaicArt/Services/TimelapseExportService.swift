import Foundation
import AVFoundation
import Photos
import CoreGraphics
import CoreMedia

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// タイムラプス動画エクスポートのエラー
public enum TimelapseExportError: LocalizedError, Sendable {
    case uncompletedProject
    case cancelled
    case writerCreationFailed(String)
    case encodingFailed(String)
    case contextCreationFailed
    case audioEncodingFailed(String)
    
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
        case .audioEncodingFailed(let msg):
            return "音声のエンコードに失敗しました: \(msg)"
        }
    }
}

/// タイムラプス動画生成サービス（適応型物理アニメーション・角丸影キャッシュ・48kHz AAC音響合成）
public final class TimelapseExportService: Sendable {
    public static let shared = TimelapseExportService()
    
    public static let videoDimension: Int = 1080
    public static let audioSampleRate: Double = 48000.0
    
    private init() {}
    
    // MARK: - 古い一時 MP4 ファイルの自動清掃
    public static func cleanupOldTemporaryFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return }
        
        let thresholdDate = Date().addingTimeInterval(-24 * 3600)
        for file in files where file.pathExtension.lowercased() == "mp4" && file.lastPathComponent.hasPrefix("timelapse-") {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let creationDate = attrs[.creationDate] as? Date,
               creationDate < thresholdDate {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    // MARK: - タイムラプス動画のエクスポート
    public func exportTimelapse(
        project: MosaicProject,
        includeAudio: Bool = true,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        guard project.isCompleted else {
            throw TimelapseExportError.uncompletedProject
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelapse-\(UUID().uuidString).mp4")
        
        let writerBox = WriterBox()
        
        do {
            try await renderVideoWithAdaptiveAnimation(
                project: project,
                includeAudio: includeAudio,
                outputURL: outputURL,
                writerBox: writerBox,
                onProgress: onProgress
            )
            return outputURL
        } catch {
            if let writer = writerBox.writer, writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
    
    // MARK: - メインレンダリング処理
    private func renderVideoWithAdaptiveAnimation(
        project: MosaicProject,
        includeAudio: Bool,
        outputURL: URL,
        writerBox: WriterBox,
        onProgress: (@Sendable (Float) -> Void)?
    ) async throws {
        let dimension = Self.videoDimension
        
        // 1. マクロ時系列（8〜12区間）＋空間分散による制御された配置シーケンス
        let sortedTiles = TimelapseTimeline.sortTilesInMacroDynamicSequence(
            tiles: project.tiles,
            projectID: project.id,
            gridWidth: project.gridWidth,
            gridHeight: project.gridHeight
        )
        guard !sortedTiles.isEmpty else {
            throw TimelapseExportError.uncompletedProject
        }
        
        let totalTiles = sortedTiles.count
        let timeline = TimelapseTimeline(
            totalTilesCount: totalTiles,
            gridWidth: project.gridWidth,
            gridHeight: project.gridHeight
        )
        let tileSchedules = timeline.generateTileSchedules()
        
        // 2. 各タイルの事前リサイズ・キャッシュ (O(N))
        let tilePixelWidth = CGFloat(dimension) / CGFloat(max(1, project.gridWidth))
        let tilePixelHeight = CGFloat(dimension) / CGFloat(max(1, project.gridHeight))
        
        var cachedTileCGImages: [UUID: CGImage] = [:]
        cachedTileCGImages.reserveCapacity(sortedTiles.count)
        
        #if canImport(UIKit)
        let identifiers = sortedTiles.compactMap(\.placedPhotoIdentifier)
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        
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
        #endif
        
        // 3. 角丸矩形シャドウ画像の事前レンダリングキャッシュ
        let shadowCache = PrecomputedShadowCache.createCache(complexity: timeline.config.shadowComplexity)
        
        // 4. 48kHz PCM オーディオバッファの事前生成 (約 1.92MB)
        let audioPcmHelper: AudioPcmHelper?
        if includeAudio {
            audioPcmHelper = AudioPcmHelper(tileSchedules: tileSchedules)
        } else {
            audioPcmHelper = nil
        }
        
        // 5. AVAssetWriter セットアップ
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writerBox.writer = writer
        } catch {
            throw TimelapseExportError.writerCreationFailed(error.localizedDescription)
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimension,
            AVVideoHeightKey: dimension,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: dimension,
            kCVPixelBufferHeightKey as String: dimension,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        guard writer.canAdd(videoInput) else {
            throw TimelapseExportError.writerCreationFailed("Writer cannot add video input")
        }
        writer.add(videoInput)
        
        var audioInput: AVAssetWriterInput? = nil
        if let _ = audioPcmHelper {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }
        
        guard writer.startWriting() else {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "Start writing failed")
        }
        writer.startSession(atSourceTime: .zero)
        
        // 6. 描画用コンテキストの準備
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let baseContext = CGContext(
                data: nil,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let frameContext = CGContext(
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
        
        // 背景初期化
        baseContext.setFillColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        baseContext.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        
        #if canImport(UIKit)
        if !project.targetImageData.isEmpty, let targetUI = UIImage(data: project.targetImageData), let targetCG = targetUI.cgImage {
            baseContext.saveGState()
            baseContext.setAlpha(0.12)
            baseContext.draw(targetCG, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            baseContext.restoreGState()
        }
        #endif
        
        // グリッド線
        baseContext.setStrokeColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.5)
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
        let frameDuration = CMTime(value: Int64(timescale) / Int64(fps), timescale: timescale)
        var currentPresentationTime = CMTime.zero
        
        var globalFrame = 0
        let totalFramesCount = TimelapseTimeline.totalFrames
        let samplesPerFrame = Int(Self.audioSampleRate) / fps // 1600 サンプル / フレーム
        
        var prng = DeterministicPRNG(seed: project.id)
        let tileSeeds: [UInt64] = (0..<totalTiles).map { _ in prng.next() }
        
        var bakedTiles = Set<Int>()
        bakedTiles.reserveCapacity(totalTiles)
        
        // -------------------------------------------------------------
        // 全300フレームの完全同期レンダリングループ (映像 + 音声 1フレームずつ供給)
        // -------------------------------------------------------------
        for f in 0..<totalFramesCount {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            
            // A. 音声サンプルバッファ（1,600 サンプル）を同期追加
            if let helper = audioPcmHelper, let aInput = audioInput {
                try helper.appendFrameAudio(
                    frameIndex: f,
                    samplesPerFrame: samplesPerFrame,
                    audioInput: aInput
                )
            }
            
            // B. 映像フレームの描画
            if f < TimelapseTimeline.openingFrames {
                // フェーズ1: オープニング (0..<30F)
                try await appendFrame(
                    context: baseContext,
                    adaptor: adaptor,
                    input: videoInput,
                    pool: pool,
                    at: currentPresentationTime
                )
            } else if f < TimelapseTimeline.openingFrames + TimelapseTimeline.buildFrames {
                // フェーズ2: ビルドフェーズ (30..<240F / buildFrame: 0..<210)
                let buildFrame = f - TimelapseTimeline.openingFrames
                
                // 1. 完全着地 (progress >= 1.0) したタイルをベースコンテキストへ焼き込み
                for schedule in tileSchedules {
                    let p = schedule.progress(atBuildFrame: buildFrame)
                    if p >= 1.0 && !bakedTiles.contains(schedule.tileIndex) {
                        bakedTiles.insert(schedule.tileIndex)
                        let tile = sortedTiles[schedule.tileIndex]
                        let targetRect = CGRect(
                            x: CGFloat(tile.gridX) * tilePixelWidth,
                            y: CGFloat(project.gridHeight - tile.gridY - 1) * tilePixelHeight,
                            width: tilePixelWidth,
                            height: tilePixelHeight
                        )
                        
                        let rgb = tile.targetLabColor.toRGB()
                        baseContext.setFillColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1.0)
                        baseContext.fill(targetRect)
                        
                        if let cg = cachedTileCGImages[tile.id] {
                            baseContext.saveGState()
                            baseContext.clip(to: targetRect)
                            baseContext.draw(cg, in: targetRect)
                            baseContext.restoreGState()
                        }
                    }
                }
                
                // 2. フレームコンテキストにベースレイヤーを描画
                guard let baseSnapshot = baseContext.makeImage() else {
                    throw TimelapseExportError.contextCreationFailed
                }
                frameContext.draw(baseSnapshot, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
                
                // 3. アクティブピースを固定深度順で描画
                let activeSchedules = tileSchedules.filter {
                    $0.isActive(atBuildFrame: buildFrame) && !bakedTiles.contains($0.tileIndex)
                }.sorted {
                    let tileA = sortedTiles[$0.tileIndex]
                    let tileB = sortedTiles[$1.tileIndex]
                    return (tileA.gridY * project.gridWidth + tileA.gridX) < (tileB.gridY * project.gridWidth + tileB.gridX)
                }
                
                for schedule in activeSchedules {
                    let tile = sortedTiles[schedule.tileIndex]
                    let t = schedule.progress(atBuildFrame: buildFrame)
                    let isLanding = schedule.isLandingFrame(atBuildFrame: buildFrame)
                    let transform = timeline.evaluateTransform(progress: t, randomSeed: tileSeeds[schedule.tileIndex], isLanding: isLanding)
                    
                    let targetRect = CGRect(
                        x: CGFloat(tile.gridX) * tilePixelWidth,
                        y: CGFloat(project.gridHeight - tile.gridY - 1) * tilePixelHeight,
                        width: tilePixelWidth,
                        height: tilePixelHeight
                    )
                    
                    let centerX = targetRect.midX + transform.xOffset
                    let centerY = targetRect.midY + transform.yOffset
                    let w = targetRect.width * transform.scale
                    let h = targetRect.height * transform.scale
                    let drawRect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                    
                    frameContext.saveGState()
                    frameContext.translateBy(x: centerX, y: centerY)
                    frameContext.rotate(by: transform.rotationRadians)
                    
                    // ① 角丸矩形立体シャドウの描画
                    if transform.shadowAlpha > 0.02, let shadowCG = shadowCache.shadowImage {
                        frameContext.saveGState()
                        let shadowRect = drawRect.offsetBy(dx: 0, dy: -transform.shadowYOffset)
                            .insetBy(dx: -transform.shadowBlur, dy: -transform.shadowBlur)
                        frameContext.setAlpha(transform.shadowAlpha)
                        frameContext.draw(shadowCG, in: shadowRect)
                        frameContext.restoreGState()
                    }
                    
                    // ② パネル本体の描画
                    let rgb = tile.targetLabColor.toRGB()
                    frameContext.setFillColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1.0)
                    frameContext.fill(drawRect)
                    
                    if let cg = cachedTileCGImages[tile.id] {
                        frameContext.saveGState()
                        frameContext.clip(to: drawRect)
                        frameContext.draw(cg, in: drawRect)
                        frameContext.restoreGState()
                    }
                    
                    // ③ 着地瞬間のフチ発光
                    if transform.isLanding {
                        frameContext.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.6)
                        frameContext.setLineWidth(max(1.5, tilePixelWidth * 0.08))
                        frameContext.stroke(drawRect)
                    }
                    
                    frameContext.restoreGState()
                }
                
                try await appendFrame(
                    context: frameContext,
                    adaptor: adaptor,
                    input: videoInput,
                    pool: pool,
                    at: currentPresentationTime
                )
            } else {
                // フェーズ3: フィナーレ (240..<300F / finaleFrame: 0..<60)
                let finaleFrame = f - (TimelapseTimeline.openingFrames + TimelapseTimeline.buildFrames)
                
                guard let finalBaseSnapshot = baseContext.makeImage() else {
                    throw TimelapseExportError.contextCreationFailed
                }
                frameContext.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
                
                // 緩やかなカメラズームアウト (1.02x -> 1.0x)
                let zoomScale: CGFloat
                if finaleFrame < 30 {
                    let zoomT = CGFloat(finaleFrame) / 30.0
                    zoomScale = 1.02 - 0.02 * sin(.pi * 0.5 * zoomT)
                } else {
                    zoomScale = 1.0
                }
                
                let zoomedW = CGFloat(dimension) * zoomScale
                let zoomedH = CGFloat(dimension) * zoomScale
                let zoomedRect = CGRect(
                    x: (CGFloat(dimension) - zoomedW) / 2,
                    y: (CGFloat(dimension) - zoomedH) / 2,
                    width: zoomedW,
                    height: zoomedH
                )
                frameContext.draw(finalBaseSnapshot, in: zoomedRect)
                
                // ソフトグロー (第0〜4F)
                if finaleFrame < 5 {
                    let glowAlpha = 0.15 * (1.0 - CGFloat(finaleFrame) / 5.0)
                    frameContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: glowAlpha)
                    frameContext.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
                }
                
                // 刻印フェードイン
                #if canImport(UIKit)
                if let watermarkConfig = project.watermarkConfig, !watermarkConfig.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let watermarkAlpha: CGFloat = (finaleFrame < 30) ? CGFloat(finaleFrame + 1) / 30.0 : 1.0
                    drawWatermarkOverlay(context: frameContext, config: watermarkConfig, dimension: CGFloat(dimension), alpha: watermarkAlpha)
                }
                #endif
                
                try await appendFrame(
                    context: frameContext,
                    adaptor: adaptor,
                    input: videoInput,
                    pool: pool,
                    at: currentPresentationTime
                )
            }
            
            currentPresentationTime = CMTimeAdd(currentPresentationTime, frameDuration)
            globalFrame += 1
            onProgress?(Float(globalFrame) / Float(totalFramesCount))
        }
        
        // 7. エンコードの完了待機（映像・音声ともに終了確認）
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        if writer.status != .completed {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "Finalize failed")
        }
    }
    
    // MARK: - 1フレームのビデオ書き込み
    private func appendFrame(
        context: CGContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        pool: CVPixelBufferPool,
        at time: CMTime
    ) async throws {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled { throw TimelapseExportError.cancelled }
            try await Task.sleep(nanoseconds: 5_000_000)
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
    
    #if canImport(UIKit)
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
    #endif
}

// MARK: - 48kHz PCM オーディオシンセサイズヘルパー
private final class AudioPcmHelper: Sendable {
    private let int16StereoBuffer: [Int16]
    private let formatDescription: CMAudioFormatDescription
    private let sampleRate: Double = 48000.0
    
    init?(tileSchedules: [TimelapseTimeline.TileAnimState]) {
        let totalDuration = TimelapseTimeline.totalDurationSeconds
        let totalSamples = Int(sampleRate * totalDuration) // 480,000 サンプル
        var pcm = [Float](repeating: 0.0, count: totalSamples)
        
        // 1. グループ着地クリック音の合成
        var landingFrames = Set<Int>()
        for schedule in tileSchedules {
            landingFrames.insert(schedule.startBuildFrame + schedule.durationFrames - 1)
        }
        let sortedLandingFrames = landingFrames.sorted()
        let frequencies: [Float] = [880.0, 1174.66, 1479.98]
        
        var lastSoundSample = -4800
        for (idx, buildFrame) in sortedLandingFrames.enumerated() {
            let globalFrame = buildFrame + TimelapseTimeline.openingFrames
            let startSample = Int(Double(globalFrame) / Double(TimelapseTimeline.fps) * sampleRate)
            
            guard startSample - lastSoundSample >= 2400 else { continue }
            lastSoundSample = startSample
            
            let freq = frequencies[idx % frequencies.count]
            let soundDur = Int(0.025 * sampleRate) // 25ms
            for i in 0..<soundDur {
                guard startSample + i < totalSamples else { break }
                let t = Float(i) / Float(sampleRate)
                let env = exp(-t * 120.0)
                pcm[startSample + i] += sin(2.0 * .pi * freq * t) * env * 0.22
            }
        }
        
        // 2. 完成チャイム音の合成 (第240F = 8.0s)
        let chimeStart = Int(8.0 * sampleRate)
        let chimeNotes: [Float] = [523.25, 659.25, 783.99, 1046.50]
        let chimeDur = Int(1.8 * sampleRate)
        for (noteIdx, noteFreq) in chimeNotes.enumerated() {
            let offset = Int(Double(noteIdx) * 0.08 * sampleRate)
            for i in 0..<chimeDur {
                let sIdx = chimeStart + offset + i
                guard sIdx < totalSamples else { break }
                let t = Float(i) / Float(sampleRate)
                let env = exp(-t * 2.2) * (1.0 - exp(-t * 80.0))
                pcm[sIdx] += sin(2.0 * .pi * noteFreq * t) * env * 0.16
            }
        }
        
        // 3. ピークリミッター (-1.0 dBFS)
        let maxPeak = pcm.map { abs($0) }.max() ?? 0.0
        if maxPeak > 0.891 {
            let gain = 0.891 / maxPeak
            for i in 0..<totalSamples { pcm[i] *= gain }
        }
        
        // 4. 16-bit インターリーブステレオ PCM バッファ (1,920,000 bytes)
        var stereo = [Int16](repeating: 0, count: totalSamples * 2)
        for i in 0..<totalSamples {
            let val = Int16(max(-1.0, min(1.0, pcm[i])) * 32767.0)
            stereo[i * 2] = val
            stereo[i * 2 + 1] = val
        }
        self.int16StereoBuffer = stereo
        
        // 5. ASBD & CMAudioFormatDescription の事前作成
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        var fDesc: CMAudioFormatDescription? = nil
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fDesc
        )
        guard status == noErr, let format = fDesc else { return nil }
        self.formatDescription = format
    }
    
    func appendFrameAudio(
        frameIndex: Int,
        samplesPerFrame: Int,
        audioInput: AVAssetWriterInput
    ) throws {
        let sampleOffset = frameIndex * samplesPerFrame
        let byteCount = samplesPerFrame * 4
        guard (sampleOffset + samplesPerFrame) * 2 <= int16StereoBuffer.count else { return }
        
        var blockBufferOut: CMBlockBuffer? = nil
        let bStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard bStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            throw TimelapseExportError.audioEncodingFailed("CMBlockBuffer creation failed")
        }
        
        int16StereoBuffer.withUnsafeBytes { rawPtr in
            let src = rawPtr.baseAddress!.advanced(by: sampleOffset * 4)
            CMBlockBufferReplaceDataBytes(
                with: src,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        
        let presentationTime = CMTime(value: Int64(sampleOffset), timescale: Int32(sampleRate))
        var sampleBufferOut: CMSampleBuffer? = nil
        let sbufStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: samplesPerFrame,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBufferOut
        )
        
        if sbufStatus == noErr, let sampleBuffer = sampleBufferOut {
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
}

// MARK: - 角丸矩形シャドウのプリレンダリング画像キャッシュ
private struct PrecomputedShadowCache: Sendable {
    let shadowImage: CGImage?
    
    static func createCache(complexity: Int) -> PrecomputedShadowCache {
        let size = 128
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return PrecomputedShadowCache(shadowImage: nil)
        }
        
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = CGFloat(size / 2)
        let colors = [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)
        ] as CFArray
        
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.35, endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
        }
        
        return PrecomputedShadowCache(shadowImage: ctx.makeImage())
    }
}

private final class WriterBox: @unchecked Sendable {
    var writer: AVAssetWriter? = nil
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

#if canImport(UIKit)
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
#endif
