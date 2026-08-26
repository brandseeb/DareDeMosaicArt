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
    case photoLibraryAccessDenied
    case outputFileMissing
    
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
        case .photoLibraryAccessDenied:
            return "写真ライブラリへのアクセスが許可されていません。"
        case .outputFileMissing:
            return "生成された動画ファイルが見つかりません。"
        }
    }
}

/// タイムラプス動画生成サービス（適応型物理アニメーション・角丸矩形影キャッシュ・48kHz AAC音響合成・着地フチ発光）
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
    
    // MARK: - 写真ライブラリへの保存（テスト・外部共有用）
    public func saveVideoToPhotoLibrary(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TimelapseExportError.outputFileMissing
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? TimelapseExportError.photoLibraryAccessDenied)
                }
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
    
    // MARK: - メインレンダリング処理 (requestMediaDataWhenReady による高効率エンコード)
    private func renderVideoWithAdaptiveAnimation(
        project: MosaicProject,
        includeAudio: Bool,
        outputURL: URL,
        writerBox: WriterBox,
        onProgress: (@Sendable (Float) -> Void)?
    ) async throws {
        let dimension = Self.videoDimension
        
        // 1. マクロ時系列（8〜12区間）＋3幕構成（散布 -> スパイラル・波 -> エッジ密度・重要領域）
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
        
        // 3. 真の角丸矩形シャドウ画像の事前レンダリングキャッシュ
        let shadowCache = PrecomputedRoundedRectShadowCache.createCache(complexity: timeline.config.shadowComplexity)
        
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
        
        let totalFramesCount = TimelapseTimeline.totalFrames
        var prng = DeterministicPRNG(seed: project.id)
        let tileSeeds: [UInt64] = (0..<totalTiles).map { _ in prng.next() }
        
        // -------------------------------------------------------------
        // 7. requestMediaDataWhenReady による高効率・安全な非同期エンコード
        // -------------------------------------------------------------
        let videoQueue = DispatchQueue(label: "com.daredemosaic.timelapse.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.daredemosaic.timelapse.audio", qos: .userInitiated)
        
        let dispatchGroup = DispatchGroup()
        
        final class RenderState: @unchecked Sendable {
            var currentFrame: Int = 0
            var bakedTiles = Set<Int>()
            var error: Error? = nil
            var audioSampleOffset: Int = 0
        }
        let state = RenderState()
        
        // A. 映像トラックの供給
        dispatchGroup.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if state.currentFrame >= totalFramesCount {
                    videoInput.markAsFinished()
                    dispatchGroup.leave()
                    break
                }
                
                let f = state.currentFrame
                let presentationTime = CMTime(value: Int64(f * (Int(timescale) / fps)), timescale: timescale)
                
                do {
                    if f < TimelapseTimeline.openingFrames {
                        // オープニング
                        try self.syncAppendFrame(context: baseContext, adaptor: adaptor, pool: pool, at: presentationTime)
                    } else if f < TimelapseTimeline.openingFrames + TimelapseTimeline.buildFrames {
                        // ビルドフェーズ
                        let buildFrame = f - TimelapseTimeline.openingFrames
                        
                        for schedule in tileSchedules {
                            if schedule.isFullyLandedAndSettled(atBuildFrame: buildFrame) && !state.bakedTiles.contains(schedule.tileIndex) {
                                state.bakedTiles.insert(schedule.tileIndex)
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
                        
                        guard let baseSnapshot = baseContext.makeImage() else {
                            throw TimelapseExportError.contextCreationFailed
                        }
                        frameContext.draw(baseSnapshot, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
                        
                        let activeSchedules = tileSchedules.filter {
                            $0.isActive(atBuildFrame: buildFrame) && !state.bakedTiles.contains($0.tileIndex)
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
                            
                            if transform.shadowAlpha > 0.02, let shadowCG = shadowCache.shadowImage {
                                frameContext.saveGState()
                                let shadowRect = drawRect.offsetBy(dx: 0, dy: -transform.shadowYOffset)
                                    .insetBy(dx: -transform.shadowBlur, dy: -transform.shadowBlur)
                                frameContext.setAlpha(transform.shadowAlpha)
                                frameContext.draw(shadowCG, in: shadowRect)
                                frameContext.restoreGState()
                            }
                            
                            let rgb = tile.targetLabColor.toRGB()
                            frameContext.setFillColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1.0)
                            frameContext.fill(drawRect)
                            
                            if let cg = cachedTileCGImages[tile.id] {
                                frameContext.saveGState()
                                frameContext.clip(to: drawRect)
                                frameContext.draw(cg, in: drawRect)
                                frameContext.restoreGState()
                            }
                            
                            if transform.isLanding {
                                frameContext.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.75)
                                frameContext.setLineWidth(max(2.0, tilePixelWidth * 0.10))
                                frameContext.stroke(drawRect)
                            }
                            
                            frameContext.restoreGState()
                        }
                        
                        try self.syncAppendFrame(context: frameContext, adaptor: adaptor, pool: pool, at: presentationTime)
                    } else {
                        // フィナーレ
                        let finaleFrame = f - (TimelapseTimeline.openingFrames + TimelapseTimeline.buildFrames)
                        
                        guard let finalBaseSnapshot = baseContext.makeImage() else {
                            throw TimelapseExportError.contextCreationFailed
                        }
                        frameContext.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
                        
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
                        
                        if finaleFrame < 5 {
                            let glowAlpha = 0.15 * (1.0 - CGFloat(finaleFrame) / 5.0)
                            frameContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: glowAlpha)
                            frameContext.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
                        }
                        
                        #if canImport(UIKit)
                        if let watermarkConfig = project.watermarkConfig, !watermarkConfig.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let watermarkAlpha: CGFloat = (finaleFrame < 30) ? CGFloat(finaleFrame + 1) / 30.0 : 1.0
                            self.drawWatermarkOverlay(context: frameContext, config: watermarkConfig, dimension: CGFloat(dimension), alpha: watermarkAlpha)
                        }
                        #endif
                        
                        try self.syncAppendFrame(context: frameContext, adaptor: adaptor, pool: pool, at: presentationTime)
                    }
                    
                    state.currentFrame += 1
                    onProgress?(Float(state.currentFrame) / Float(totalFramesCount))
                } catch {
                    state.error = error
                    videoInput.markAsFinished()
                    dispatchGroup.leave()
                    break
                }
            }
        }
        
        // B. 音声トラックの供給
        if let helper = audioPcmHelper, let aInput = audioInput {
            dispatchGroup.enter()
            let chunkSize = 1024
            aInput.requestMediaDataWhenReady(on: audioQueue) {
                while aInput.isReadyForMoreMediaData {
                    if state.audioSampleOffset >= helper.totalSamples {
                        aInput.markAsFinished()
                        dispatchGroup.leave()
                        break
                    }
                    
                    let remaining = helper.totalSamples - state.audioSampleOffset
                    let samplesThisChunk = min(chunkSize, remaining)
                    
                    do {
                        try helper.appendChunk(sampleOffset: state.audioSampleOffset, count: samplesThisChunk, to: aInput)
                        state.audioSampleOffset += samplesThisChunk
                    } catch {
                        state.error = error
                        aInput.markAsFinished()
                        dispatchGroup.leave()
                        break
                    }
                }
            }
        }
        
        // 両方のトラックが書き込み完了するのを待機
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dispatchGroup.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
        
        if let err = state.error {
            throw err
        }
        
        // 8. ファイルの書き込み終了
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        if writer.status != .completed {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "Finalize failed")
        }
    }
    
    // MARK: - 1フレームの同期書き込み
    private func syncAppendFrame(
        context: CGContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool,
        at time: CMTime
    ) throws {
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
        context.saveGState()
        // CGContext（原点左下）を UIKit 座標系（原点左上）へフリップ
        context.translateBy(x: 0, y: dimension)
        context.scaleBy(x: 1.0, y: -1.0)
        
        UIGraphicsPushContext(context)
        defer {
            UIGraphicsPopContext()
            context.restoreGState()
        }
        
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
    public let totalSamples: Int
    
    init?(tileSchedules: [TimelapseTimeline.TileAnimState]) {
        let totalDuration = TimelapseTimeline.totalDurationSeconds
        let totalSamplesCount = Int(sampleRate * totalDuration) // 480,000 サンプル
        self.totalSamples = totalSamplesCount
        var pcm = [Float](repeating: 0.0, count: totalSamplesCount)
        
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
                guard startSample + i < totalSamplesCount else { break }
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
                guard sIdx < totalSamplesCount else { break }
                let t = Float(i) / Float(sampleRate)
                let env = exp(-t * 2.2) * (1.0 - exp(-t * 80.0))
                pcm[sIdx] += sin(2.0 * .pi * noteFreq * t) * env * 0.16
            }
        }
        
        // 3. ピークリミッター (-1.0 dBFS)
        let maxPeak = pcm.map { abs($0) }.max() ?? 0.0
        if maxPeak > 0.891 {
            let gain = 0.891 / maxPeak
            for i in 0..<totalSamplesCount { pcm[i] *= gain }
        }
        
        // 4. 16-bit インターリーブステレオ PCM バッファ (1,920,000 bytes)
        var stereo = [Int16](repeating: 0, count: totalSamplesCount * 2)
        for i in 0..<totalSamplesCount {
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
    
    func appendChunk(
        sampleOffset: Int,
        count: Int,
        to audioInput: AVAssetWriterInput
    ) throws {
        let byteCount = count * 4
        guard (sampleOffset + count) * 2 <= int16StereoBuffer.count else { return }
        
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
            throw TimelapseExportError.audioEncodingFailed("CMBlockBuffer creation failed: \(bStatus)")
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
            sampleCount: count,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBufferOut
        )
        
        guard sbufStatus == noErr, let sampleBuffer = sampleBufferOut else {
            throw TimelapseExportError.audioEncodingFailed("CMAudioSampleBufferCreate failed with status: \(sbufStatus)")
        }
        
        if !audioInput.append(sampleBuffer) {
            throw TimelapseExportError.audioEncodingFailed("audioInput.append failed")
        }
    }
}

// MARK: - 真の角丸矩形シャドウのプリレンダリング画像キャッシュ
private struct PrecomputedRoundedRectShadowCache: Sendable {
    let shadowImage: CGImage?
    
    static func createCache(complexity: Int) -> PrecomputedRoundedRectShadowCache {
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
            return PrecomputedRoundedRectShadowCache(shadowImage: nil)
        }
        
        let rect = CGRect(x: 20, y: 20, width: 88, height: 88)
        let cornerRadius: CGFloat = 16.0
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 16.0, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        
        return PrecomputedRoundedRectShadowCache(shadowImage: ctx.makeImage())
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
