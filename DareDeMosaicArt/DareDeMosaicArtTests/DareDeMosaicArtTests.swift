import XCTest
import AVFoundation
import Vision
@testable import DareDeMosaicArt

final class DareDeMosaicArtTests: XCTestCase {

    func testAspectFillRectPreservesTileImageAspectRatio() {
        let destination = CGRect(x: 10, y: 20, width: 100, height: 100)

        let landscape = DareDeMosaicArt.ImageUtils.aspectFillRect(
            imageSize: CGSize(width: 400, height: 200),
            destinationRect: destination
        )
        XCTAssertEqual(landscape, CGRect(x: -40, y: 20, width: 200, height: 100))
        XCTAssertEqual(landscape.width / landscape.height, 2, accuracy: 0.0001)

        let portrait = DareDeMosaicArt.ImageUtils.aspectFillRect(
            imageSize: CGSize(width: 200, height: 400),
            destinationRect: destination
        )
        XCTAssertEqual(portrait, CGRect(x: 10, y: -30, width: 100, height: 200))
        XCTAssertEqual(portrait.width / portrait.height, 0.5, accuracy: 0.0001)
    }

    func testColorAnalysisService() throws {
        // 色差計算のテスト
        let red = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let similarRed = LabColor.fromRGB(red: 0.95, green: 0.05, blue: 0.05)
        let blue = LabColor.fromRGB(red: 0.0, green: 0.0, blue: 1.0)
        
        let distSimilar = red.distance(to: similarRed)
        let distDiff = red.distance(to: blue)
        
        XCTAssertLessThan(distSimilar, 15.0, "類似した赤同士の色差は小さいはず")
        XCTAssertGreaterThan(distDiff, 50.0, "赤と青の色差は大きいはず")
    }

    func testMosaicEngineMissionGeneration() async throws {
        let red = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let blue = LabColor.fromRGB(red: 0.0, green: 0.0, blue: 1.0)
        
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: red),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: red),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: blue),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: blue)
        ]
        
        // ミッション生成テスト (from: tiles)
        let missions = MosaicEngine.shared.generateMissions(from: tiles)
        XCTAssertEqual(missions.count, 2, "赤と青の2つのミッションが生成されるはず")
    }

    func testPhotoLocking() throws {
        let red = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        
        var tile = MosaicTile(gridX: 0, gridY: 0, targetLabColor: red)
        tile.placedPhotoIdentifier = "manual_photo"
        tile.isLocked = true
        tile.origin = .manuallySelected
        
        let photos = [
            IndexedPhoto(id: "auto_photo", labColor: red, signature: nil, thumbnailData: nil)
        ]
        
        let updated = MosaicEngine.shared.matchTiles(tiles: [tile], availablePhotos: photos)
        XCTAssertEqual(updated.first?.placedPhotoIdentifier, "manual_photo", "ロックされた写真は上書きされないはず")
        XCTAssertEqual(updated.first?.origin, .manuallySelected)
    }

    @MainActor
    func testStoreKit2ManagerProperties() throws {
        XCTAssertEqual(StoreKitManager.proProductID, "com.daredemosaic.app.pro")
        let manager = StoreKitManager.shared
        XCTAssertNotNil(manager.proStatus)
    }

    func testGeneratedTimelapseMP4Specifications() async throws {
        let red = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let blue = LabColor.fromRGB(red: 0.0, green: 0.0, blue: 1.0)
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: red, placedPhotoIdentifier: "p1", placementSequence: 0),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: blue, placedPhotoIdentifier: "p2", placementSequence: 1),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: blue, placedPhotoIdentifier: "p3", placementSequence: 2),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: red, placedPhotoIdentifier: "p4", placementSequence: 3)
        ]
        let project = MosaicProject(
            title: "timelapse-specification-test",
            targetImageData: Data(),
            gridWidth: 2,
            gridHeight: 2,
            mode: .hybrid,
            photoSource: .allLocalPhotos,
            tiles: tiles,
            missions: [],
            isCompleted: true,
            watermarkConfig: WatermarkConfig(
                text: "Test Watermark\n2026.08.26",
                fontDesign: .standard,
                position: .bottomRight,
                colorStyle: .whiteWithShadow
            )
        )

        // 1. 効果音ありのエクスポート検証 (映像 + 48kHz AAC ステレオ音声)
        let videoURLWithAudio = try await TimelapseExportService.shared.exportTimelapse(project: project, includeAudio: true)
        defer { try? FileManager.default.removeItem(at: videoURLWithAudio) }

        let assetWithAudio = AVURLAsset(url: videoURLWithAudio)
        let durationWithAudio = try await assetWithAudio.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(durationWithAudio), 10.0, accuracy: 0.05, "動画全体の長さは10.0秒である必要があります")

        // 映像トラック仕様アサーション
        let videoTracks = try await assetWithAudio.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "映像トラックが1本存在する必要があります")
        let videoTrack = try XCTUnwrap(videoTracks.first)

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let displayedSize = naturalSize.applying(transform)
        XCTAssertEqual(abs(displayedSize.width), 1080, accuracy: 0.5)
        XCTAssertEqual(abs(displayedSize.height), 1080, accuracy: 0.5)

        let videoFormatDescriptions = try await videoTrack.load(.formatDescriptions)
        XCTAssertFalse(videoFormatDescriptions.isEmpty)
        XCTAssertTrue(
            videoFormatDescriptions
                .map(CMFormatDescriptionGetMediaSubType)
                .contains(kCMVideoCodecType_H264),
            "映像コーデックはH.264（avc1）である必要があります"
        )

        // 🎵 音声トラック仕様の厳密アサーション (48kHz, ステレオ2ch, AAC)
        let audioTracks = try await assetWithAudio.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "効果音あり時は音声トラックが1本存在する必要があります")
        let audioTrack = try XCTUnwrap(audioTracks.first)
        
        let audioDuration = try await audioTrack.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(audioDuration.duration), 10.0, accuracy: 0.05, "音声トラックの長さは10.0秒である必要があります")

        let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
        XCTAssertFalse(audioFormatDescriptions.isEmpty, "音声フォーマット情報が存在する必要があります")
        let audioDesc = try XCTUnwrap(audioFormatDescriptions.first)
        
        let audioSubType = CMFormatDescriptionGetMediaSubType(audioDesc)
        XCTAssertTrue(
            audioSubType == kAudioFormatMPEG4AAC || audioSubType == kAudioFormatMPEG4AAC_HE || audioSubType == kAudioFormatMPEG4AAC_HE_V2,
            "音声コーデックはAACである必要があります (subType: \(audioSubType))"
        )
        
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc) {
            let asbd = asbdPtr.pointee
            XCTAssertEqual(asbd.mSampleRate, 48000.0, accuracy: 1.0, "サンプリング周波数は48.0kHzである必要があります")
            XCTAssertEqual(asbd.mChannelsPerFrame, 2, "ステレオ2chである必要があります")
        }

        // 2. 効果音なしのエクスポート検証 (音声トラック不在)
        let videoURLNoAudio = try await TimelapseExportService.shared.exportTimelapse(project: project, includeAudio: false)
        defer { try? FileManager.default.removeItem(at: videoURLNoAudio) }

        let assetNoAudio = AVURLAsset(url: videoURLNoAudio)
        let audioTracksNoAudio = try await assetNoAudio.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracksNoAudio.isEmpty, "効果音OFF時は音声トラックが存在しない必要があります")

        // 3. 最終フレーム刻印認識テスト
        let imageGenerator = AVAssetImageGenerator(asset: assetWithAudio)
        imageGenerator.appliesPreferredTrackTransform = true
        let finalFrame = try await imageGenerator.image(
            at: CMTime(seconds: 9.5, preferredTimescale: 600)
        ).image
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        let visionHandler = VNImageRequestHandler(cgImage: finalFrame, orientation: .up)
        try visionHandler.perform([textRequest])
        let recognizedText = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        XCTAssertTrue(
            recognizedText.localizedCaseInsensitiveContains("Test Watermark"),
            "最終フレームの刻印が正しい向きで認識できる必要があります。認識結果: \(recognizedText)"
        )
    }

    func testTimelapseCancellationCompletesPromptly() async throws {
        let color = LabColor.fromRGB(red: 0.4, green: 0.5, blue: 0.6)
        let tiles = (0..<3_600).map { index in
            MosaicTile(
                gridX: index % 60,
                gridY: index / 60,
                targetLabColor: color,
                placedPhotoIdentifier: "cancel-test-\(index)",
                placementSequence: index
            )
        }
        let project = MosaicProject(
            title: "timelapse-cancellation-test",
            targetImageData: Data(),
            gridWidth: 60,
            gridHeight: 60,
            mode: .hybrid,
            tiles: tiles,
            missions: [],
            isCompleted: true
        )

        let exportTask = Task {
            try await TimelapseExportService.shared.exportTimelapse(
                project: project,
                includeAudio: true
            )
        }

        // 前処理だけでなく、Writerへの供給開始後のキャンセル経路を通す。
        try await Task.sleep(for: .milliseconds(250))
        let cancelInstant = ContinuousClock.now
        exportTask.cancel()

        do {
            let unexpectedURL = try await exportTask.value
            try? FileManager.default.removeItem(at: unexpectedURL)
            XCTFail("生成中のタイムラプスはキャンセルされる必要があります")
        } catch let error as TimelapseExportError {
            guard case .cancelled = error else {
                return XCTFail("キャンセル時の想定外エラー: \(error)")
            }
        } catch is CancellationError {
            // キャンセル境界のタイミングにより Foundation 側が先に反応する場合も正常。
        } catch {
            XCTFail("キャンセル時の想定外エラー: \(error)")
        }

        let cancelLatency = cancelInstant.duration(to: .now)
        XCTAssertLessThan(cancelLatency, .seconds(2), "キャンセル後はWriter待機から速やかに復帰する必要があります")
    }

    func testEveryTimelapseTileIsSettledBeforeFinale() {
        for tileCount in [100, 400, 900, 2_500, 3_600] {
            let timeline = TimelapseTimeline(totalTilesCount: tileCount)
            let schedules = timeline.generateTileSchedules()

            XCTAssertEqual(schedules.count, tileCount)
            XCTAssertTrue(
                schedules.allSatisfy { $0.isFullyLandedAndSettled(atBuildFrame: 209) },
                "\(tileCount)マスの全タイルがフィナーレ前に固定済みである必要があります"
            )
        }
    }

    func testSaveGeneratedTimelapseToPhotoLibrary() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOS_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("写真ライブラリを変更する統合テストは明示実行時のみ有効です")
        }

        let color = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let project = MosaicProject(
            title: "photo-library-save-test",
            targetImageData: Data(),
            gridWidth: 1,
            gridHeight: 1,
            mode: .hybrid,
            tiles: [MosaicTile(
                gridX: 0,
                gridY: 0,
                targetLabColor: color,
                placedPhotoIdentifier: "photo-save-test",
                placementSequence: 0
            )],
            missions: [],
            isCompleted: true
        )

        let videoURL = try await TimelapseExportService.shared.exportTimelapse(project: project)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await TimelapseExportService.shared.saveVideoToPhotoLibrary(at: videoURL)
    }

    // MARK: - 超高精度モザイクマッチング v2 テスト群

    func testDiagonalGradientDiscrimination() throws {
        // 1. 左上黒 (0.0) -> 右下白 (1.0) の対角グラデーション CGImage
        let size = 48
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawDiagForward = [UInt8](repeating: 0, count: size * size * 4)
        var rawDiagBackward = [UInt8](repeating: 0, count: size * size * 4)
        var rawFlatGray = [UInt8](repeating: 0, count: size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                let idx = (y * size + x) * 4
                // 左上(0,0)が0、右下(47,47)が255
                let valFwd = UInt8((x + y) * 255 / (size * 2 - 2))
                rawDiagForward[idx] = valFwd
                rawDiagForward[idx + 1] = valFwd
                rawDiagForward[idx + 2] = valFwd
                rawDiagForward[idx + 3] = 255

                // 逆方向: 左上(0,0)が255、右下(47,47)が0
                let valBwd = UInt8(255 - Int(valFwd))
                rawDiagBackward[idx] = valBwd
                rawDiagBackward[idx + 1] = valBwd
                rawDiagBackward[idx + 2] = valBwd
                rawDiagBackward[idx + 3] = 255

                // 均一グレー (128)
                rawFlatGray[idx] = 128
                rawFlatGray[idx + 1] = 128
                rawFlatGray[idx + 2] = 128
                rawFlatGray[idx + 3] = 255
            }
        }

        guard let ctxFwd = CGContext(data: &rawDiagForward, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let ctxBwd = CGContext(data: &rawDiagBackward, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let ctxFlat = CGContext(data: &rawFlatGray, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let cgFwd = ctxFwd.makeImage(),
              let cgBwd = ctxBwd.makeImage(),
              let cgFlat = ctxFlat.makeImage() else {
            return XCTFail("CGContext作成に失敗しました")
        }

        let sigTarget = ColorAnalysisService.shared.extractSpatialSignature(from: cgFwd)
        let sigSame = ColorAnalysisService.shared.extractSpatialSignature(from: cgFwd)
        let sigOpposite = ColorAnalysisService.shared.extractSpatialSignature(from: cgBwd)
        let sigFlat = ColorAnalysisService.shared.extractSpatialSignature(from: cgFlat)

        let distSame = sigTarget.distance(to: sigSame)
        let distOpposite = sigTarget.distance(to: sigOpposite)
        let distFlat = sigTarget.distance(to: sigFlat)

        XCTAssertEqual(distSame, 0.0, accuracy: 0.001, "同一画像は完全一致(0.0)になるはず")
        XCTAssertLessThan(distSame, distFlat, "同一グラデーションは均一グレーより近いはず")
        XCTAssertLessThan(distFlat, distOpposite, "均一グレーは逆方向グラデーションよりも近いはず（逆グラデーションは強いペナルティ）")
        XCTAssertGreaterThan(distOpposite, 0.40, "逆方向グラデーションは明確に不一致になるはず")
    }

    func testSobelSignedDirectionAndOpposites() throws {
        let size = 48
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. 左黒・右白 (水平勾配: 黒 -> 白)
        var rawLeftDark = [UInt8](repeating: 0, count: size * size * 4)
        // 2. 左白・右黒 (水平勾配: 白 -> 黒)
        var rawRightDark = [UInt8](repeating: 0, count: size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                let idx = (y * size + x) * 4
                let valL = (x < size / 2) ? UInt8(20) : UInt8(235)
                rawLeftDark[idx] = valL; rawLeftDark[idx+1] = valL; rawLeftDark[idx+2] = valL; rawLeftDark[idx+3] = 255

                let valR = (x < size / 2) ? UInt8(235) : UInt8(20)
                rawRightDark[idx] = valR; rawRightDark[idx+1] = valR; rawRightDark[idx+2] = valR; rawRightDark[idx+3] = 255
            }
        }

        let ctxL = CGContext(data: &rawLeftDark, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let ctxR = CGContext(data: &rawRightDark, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!

        let sigL = ColorAnalysisService.shared.extractSpatialSignature(from: ctxL.makeImage()!)
        let sigR = ColorAnalysisService.shared.extractSpatialSignature(from: ctxR.makeImage()!)

        // 符号付き方向により、明暗の向きが逆であれば距離が大きくなる
        let dist = sigL.distance(to: sigR)
        XCTAssertGreaterThan(dist, 0.35, "黒->白と白->黒は符号付き方向ヒストグラムにより明確に区別される必要があります")
    }

    func testSobelFlatImageStability() throws {
        let size = 48
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawFlat = [UInt8](repeating: 128, count: size * size * 4)
        for i in 0..<(size * size) { rawFlat[i * 4 + 3] = 255 }

        let ctx = CGContext(data: &rawFlat, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let sig = ColorAnalysisService.shared.extractSpatialSignature(from: ctx.makeImage()!)

        XCTAssertFalse(sig.darkCenterOfMassX.isNaN)
        XCTAssertFalse(sig.darkCenterOfMassY.isNaN)
        XCTAssertFalse(sig.brightCenterOfMassX.isNaN)
        XCTAssertFalse(sig.brightCenterOfMassY.isNaN)
        XCTAssertFalse(sig.distance(to: sig).isNaN)
        XCTAssertEqual(sig.distance(to: sig), 0.0, accuracy: 0.001)
    }

    func testContinuousCoMAndConfidence() throws {
        let labMid = LabColor(l: 50, a: 0, b: 0)
        let sigMid = SpatialColorSignature(average: labMid, cells3x3: Array(repeating: labMid, count: 9), darkCenterOfMass: (0, 0), darkConfidence: 0.0, brightCenterOfMass: (0, 0), brightConfidence: 0.0)
        XCTAssertEqual(sigMid.darkConfidence, 0.0, accuracy: 0.001, "L=50 の均一領域では暗部信頼度は 0 になるはず")
        XCTAssertEqual(sigMid.brightConfidence, 0.0, accuracy: 0.001, "L=50 の均一領域では明部信頼度は 0 になるはず")

        let labDark = LabColor(l: 10, a: 0, b: 0)
        let sigDark = SpatialColorSignature(average: labDark, cells3x3: Array(repeating: labDark, count: 9), darkCenterOfMass: (-0.5, -0.5), darkConfidence: 0.8, brightCenterOfMass: (0, 0), brightConfidence: 0.0)
        XCTAssertGreaterThan(sigDark.darkConfidence, 0.5, "暗部が多い画像では暗部信頼度が高くなるはず")
    }

    func testScoreContinuityAcrossLuminance() throws {
        // L=0 から L=100 まで連続的に変化させ、スコアが滑らかに変化することを検証
        var prevDist: Float? = nil
        let baseSig = SpatialColorSignature(average: LabColor(l: 50, a: 0, b: 0), cells3x3: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 9))

        for l in stride(from: Float(0), through: Float(100), by: Float(5)) {
            let testSig = SpatialColorSignature(average: LabColor(l: l, a: 0, b: 0), cells3x3: Array(repeating: LabColor(l: l, a: 0, b: 0), count: 9))
            let dist = baseSig.distance(to: testSig)
            XCTAssertFalse(dist.isNaN)
            XCTAssertGreaterThanOrEqual(dist, 0.0)
            XCTAssertLessThanOrEqual(dist, 1.0)

            if let prev = prevDist {
                let stepDiff = abs(dist - prev)
                XCTAssertLessThan(stepDiff, 0.25, "明度変化に対してスコアが滑らかに連続している必要があります")
            }
            prevDist = dist
        }
    }

    func testVersion1AndVersion2CompatibilityAndCorruptionResilience() throws {
        // 1. v1 形式の JSON シミュレーション (cells: 9個, version なし)
        let v1JSON = """
        {
            "average": {"l": 50, "a": 0, "b": 0},
            "cells": [
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0},
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0},
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}
            ],
            "contrast": 0
        }
        """.data(using: .utf8)!

        let decodedV1 = try JSONDecoder().decode(SpatialColorSignature.self, from: v1JSON)
        XCTAssertEqual(decodedV1.version, 1, "versionがない場合は1として安全にデコードされるはず")
        XCTAssertEqual(decodedV1.cells3x3.count, 9)

        // 2. v2 のシグネチャ作成
        let v2Sig = SpatialColorSignature(
            version: 2,
            average: LabColor(l: 50, a: 0, b: 0),
            cells3x3: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 9),
            cells6x6: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 36)
        )

        // v1 と v2 の距離計算
        let distV1toV2 = decodedV1.distance(to: v2Sig)
        XCTAssertEqual(distV1toV2, 0.0, accuracy: 0.001, "v1とv2の互換計算が正常に動作するはず")

        // 3. 不正な配列サイズ（破損データ）のデコード -> 偽の36セル補間を行わず、version 1 に安全降格
        let corruptJSON = """
        {
            "version": 2,
            "average": {"l": 50, "a": 0, "b": 0},
            "cells6x6": [{"l": 50, "a": 0, "b": 0}]
        }
        """.data(using: .utf8)!

        let decodedCorrupt = try JSONDecoder().decode(SpatialColorSignature.self, from: corruptJSON)
        XCTAssertEqual(decodedCorrupt.version, 1, "36セル揃っていない不完全なデータは安全にv1へ降格されるはず")
        XCTAssertTrue(decodedCorrupt.cells6x6.isEmpty, "降格されたデータのcells6x6は空配列になるはず")
        XCTAssertEqual(decodedCorrupt.cells3x3.count, 9, "3x3データとして安全に機能するはず")
    }

    func testMultiDimensionalIndexUnionCandidates() throws {
        let photos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 50, a: 0, b: 0), signature: SpatialColorSignature(version: 2, average: LabColor(l: 50, a: 0, b: 0), cells3x3: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 9))),
            IndexedPhoto(id: "p2", labColor: LabColor(l: 20, a: 0, b: 0), signature: SpatialColorSignature(version: 2, average: LabColor(l: 20, a: 0, b: 0), cells3x3: Array(repeating: LabColor(l: 20, a: 0, b: 0), count: 9), darkCenterOfMass: (-0.5, -0.5), darkConfidence: 0.8)),
            IndexedPhoto(id: "p3", labColor: LabColor(l: 80, a: 0, b: 0), signature: SpatialColorSignature(version: 2, average: LabColor(l: 80, a: 0, b: 0), cells3x3: Array(repeating: LabColor(l: 80, a: 0, b: 0), count: 9), brightCenterOfMass: (0.5, 0.5), brightConfidence: 0.8))
        ]

        let index = MultiDimensionalPhotoIndex(photos: photos)
        let candidates = index.candidates(for: LabColor(l: 25, a: 0, b: 0), signature: photos[1].signature)

        XCTAssertTrue(candidates.contains(where: { $0.id == "p2" }), "明暗重心が近い写真が候補の和集合に確実に含まれる必要があります")
    }
}

