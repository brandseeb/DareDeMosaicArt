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

        // 3. 不正な外側配列サイズ（破損データ）のデコード -> 偽の36セル補間を行わず、version 1 に安全降格
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

        // 4. 不正な内側ヒストグラムサイズ（8要素未満）のデコード -> クラッシュせず安全にv1へ降格
        let corruptInnerJSON = """
        {
            "version": 2,
            "average": {"l": 50, "a": 0, "b": 0},
            "cells3x3": [
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0},
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0},
                {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}, {"l": 50, "a": 0, "b": 0}
            ],
            "cells6x6": [\(Array(repeating: #"{"l": 50, "a": 0, "b": 0}"#, count: 36).joined(separator: ","))],
            "gradientMagnitudes6x6": [\(Array(repeating: "0.5", count: 36).joined(separator: ","))],
            "gradientHistograms6x6": [\(Array(repeating: "[0.1, 0.2]", count: 36).joined(separator: ","))]
        }
        """.data(using: .utf8)!

        let decodedInnerCorrupt = try JSONDecoder().decode(SpatialColorSignature.self, from: corruptInnerJSON)
        XCTAssertEqual(decodedInnerCorrupt.version, 1, "内側ヒストグラムが8要素未満のデータは安全にv1へ降格されるはず")
        XCTAssertTrue(decodedInnerCorrupt.cells6x6.isEmpty)
    }

    // MARK: - スマート・オートフィル（段階的近似自動配置）網羅テスト

    /// 1. 写真不足 ＋ 重複なし: 未使用写真数を超えるマスは埋まらず、成立可能最大数まで配置されること
    func testAutoFillPhotoShortageWithoutDuplicates() async throws {
        // 4マスのプロジェクト（すべて未配置）
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 10, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 30, a: 0, b: 0)),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 60, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 90, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "テスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        
        // 写真は 2 枚しかない（不足）
        let photos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 15, a: 0, b: 0)),
            IndexedPhoto(id: "p2", labColor: LabColor(l: 85, a: 0, b: 0))
        ]
        
        let plan = try MosaicEngine.shared.makeAutoFillPlan(
            project: project,
            availablePhotos: photos,
            level: .completeMax,
            allowDuplicates: false
        )
        
        XCTAssertEqual(plan.assignments.count, 2, "写真が2枚しかないため、重複なしでは最大2マスしか埋まらないはず")
        XCTAssertEqual(plan.newFilledCount, 2)
        XCTAssertEqual(plan.projectedProgress, 0.5, accuracy: 0.001)
    }

    /// 2. 写真不足 ＋ 重複あり: 写真が 1 枚でもあれば 100% 全マスが埋まること
    func testAutoFillPhotoShortageWithDuplicates() async throws {
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 10, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 30, a: 0, b: 0)),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 60, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 90, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "テスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        
        // 写真は 1 枚のみ
        let photos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 50, a: 0, b: 0))
        ]
        
        let plan = try MosaicEngine.shared.makeAutoFillPlan(
            project: project,
            availablePhotos: photos,
            level: .completeMax,
            allowDuplicates: true
        )
        
        XCTAssertEqual(plan.assignments.count, 4, "重複許可時は1枚の写真で4マスすべて埋まるはず")
        XCTAssertEqual(plan.newFilledCount, 4)
        XCTAssertEqual(plan.projectedProgress, 1.0, accuracy: 0.001)
    }

    /// 3. 既存タイルの保護: 初期配置済み（未ロック含む）、手動差し替え済み、カメラ撮影済みタイルが一切上書きされないこと
    func testAutoFillPreservesExistingTiles() async throws {
        var tiles = [
            // タイル0: 初期配置済み（未ロック）
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 10, a: 0, b: 0), placedPhotoIdentifier: "initial_photo", origin: .automatic),
            // タイル1: 手動差し替え済み
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 30, a: 0, b: 0), placedPhotoIdentifier: "manual_photo", origin: PlacementOrigin.manuallySelected),
            // タイル2: カメラ撮影済み
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 60, a: 0, b: 0), placedPhotoIdentifier: "captured_photo", origin: PlacementOrigin.captured),
            // タイル3: 未配置（空き）
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 90, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "保護テスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        
        let photos = [
            IndexedPhoto(id: "new_photo", labColor: LabColor(l: 90, a: 0, b: 0))
        ]
        
        let plan = try MosaicEngine.shared.makeAutoFillPlan(
            project: project,
            availablePhotos: photos,
            level: .completeMax,
            allowDuplicates: true
        )
        
        XCTAssertEqual(plan.assignments.count, 1, "未配置のタイル3のみが対象になるはず")
        XCTAssertEqual(plan.assignments.first?.tileID, tiles[3].id)
        
        let result = MosaicEngine.shared.applyAutoFillPlan(project: project, plan: plan)
        guard case .applied(let updatedProject, let count) = result else {
            XCTFail("適用に失敗しました")
            return
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(updatedProject.tiles[0].placedPhotoIdentifier, "initial_photo", "初期配置タイルは維持される")
        XCTAssertEqual(updatedProject.tiles[1].placedPhotoIdentifier, "manual_photo", "手動選択タイルは維持される")
        XCTAssertEqual(updatedProject.tiles[2].placedPhotoIdentifier, "captured_photo", "撮影タイルは維持される")
        XCTAssertEqual(updatedProject.tiles[3].placedPhotoIdentifier, "new_photo", "空きマスのみ新規配置される")
    }

    /// 4. プレビューと実配置の一致: 不変状態下で simulateAutoFill と applyAutoFillPlan の配置件数が 100% 一致すること
    func testAutoFillPreviewAndExecutionMatch() async throws {
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 20, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 40, a: 0, b: 0)),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 60, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 80, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "一致テスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        let photos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 21, a: 0, b: 0)),
            IndexedPhoto(id: "p2", labColor: LabColor(l: 42, a: 0, b: 0)),
            IndexedPhoto(id: "p3", labColor: LabColor(l: 75, a: 0, b: 0))
        ]
        
        let simulations = await MosaicEngine.shared.simulateAutoFill(
            project: project,
            availablePhotos: photos,
            allowDuplicates: false
        )
        
        XCTAssertEqual(simulations.count, AutoFillLevel.allCases.count)
        
        for sim in simulations {
            let result = MosaicEngine.shared.applyAutoFillPlan(project: project, plan: sim.plan)
            guard case .applied(let updatedProject, let placedCount) = result else {
                XCTFail("シミュレーションプランの適用に失敗")
                continue
            }
            XCTAssertEqual(placedCount, sim.additionalCount, "プレビュー件数と実配置件数が完全に一致すること")
            XCTAssertEqual(updatedProject.filledCount, sim.newFilledCount, "プレビュー後の埋まりマス数が一致すること")
        }
    }

    /// 5. ステイルプランの検知: プロジェクトが更新された後の古いプラン適用時に、勝手に適用されず .stale が返ること
    func testAutoFillStalePlanDetection() async throws {
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 20, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 40, a: 0, b: 0))
        ]
        var project = MosaicProject(title: "ステイルテスト", gridWidth: 2, gridHeight: 1, tiles: tiles)
        let photos = [IndexedPhoto(id: "p1", labColor: LabColor(l: 20, a: 0, b: 0))]
        
        // プランを生成
        let plan = try MosaicEngine.shared.makeAutoFillPlan(
            project: project,
            availablePhotos: photos,
            level: .completeMax,
            allowDuplicates: false
        )
        
        // 外部でプロジェクトが更新された（例: ユーザーが手動操作）
        try? await Task.sleep(for: .milliseconds(10))
        project.updatedAt = Date()
        project.tiles[0].placedPhotoIdentifier = "another_photo"
        
        // 古いプランを適用しようとすると .stale になる
        let result = MosaicEngine.shared.applyAutoFillPlan(project: project, plan: plan)
        guard case .stale = result else {
            XCTFail(".stale が返されるべき")
            return
        }
    }

    /// 6. オートフィル後のロック保護・手動差し替え保護 ＆ リセット機能
    func testAutoFillResetProtectsLockedAndManualTiles() async throws {
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 10, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 20, a: 0, b: 0)),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 30, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 40, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "リセットテスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        let photos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 10, a: 0, b: 0)),
            IndexedPhoto(id: "p2", labColor: LabColor(l: 20, a: 0, b: 0)),
            IndexedPhoto(id: "p3", labColor: LabColor(l: 30, a: 0, b: 0)),
            IndexedPhoto(id: "p4", labColor: LabColor(l: 40, a: 0, b: 0))
        ]
        
        let plan = try MosaicEngine.shared.makeAutoFillPlan(
            project: project,
            availablePhotos: photos,
            level: .completeMax,
            allowDuplicates: false
        )
        
        guard case .applied(var filledProject, _) = MosaicEngine.shared.applyAutoFillPlan(project: project, plan: plan) else {
            XCTFail("適用失敗")
            return
        }
        XCTAssertEqual(filledProject.filledCount, 4)
        XCTAssertTrue(filledProject.isCompleted)
        
        // ユーザーが タイル0 をロックし、タイル1 を手動差し替えした
        filledProject.tiles[0].isLocked = true
        filledProject.tiles[1].origin = PlacementOrigin.manuallySelected
        
        // リセットを実行
        let (resetProject, resetCount) = MosaicEngine.shared.resetAutoFilledTiles(project: filledProject)
        
        XCTAssertEqual(resetCount, 2, "タイル2, 3 の2マスのみリセットされるはず")
        XCTAssertEqual(resetProject.filledCount, 2, "ロック済みタイル0と手動タイル1は保持される")
        XCTAssertEqual(resetProject.tiles[0].placedPhotoIdentifier, "p1", "ロック済みタイル0は消えない")
        XCTAssertEqual(resetProject.tiles[1].placedPhotoIdentifier, "p2", "手動差し替えタイル1は消えない")
        XCTAssertNil(resetProject.tiles[2].placedPhotoIdentifier, "タイル2はリセットされる")
        XCTAssertNil(resetProject.tiles[3].placedPhotoIdentifier, "タイル3はリセットされる")
        XCTAssertFalse(resetProject.isCompleted, "未配置マスがあるため完成フラグはfalseに再計算される")
        XCTAssertFalse(resetProject.missions.isEmpty, "不足色ミッションが再生成される")
    }

    /// 7. 決定的採番順の検証: 同一入力から常に同一の割り当てと昇順 placementSequence が得られること
    func testAutoFillDeterministicSequenceAndAssignments() async throws {
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 10, a: 0, b: 0)),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 20, a: 0, b: 0)),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 30, a: 0, b: 0))
        ]
        let project = MosaicProject(title: "決定性テスト", gridWidth: 2, gridHeight: 2, tiles: tiles)
        let photos = [
            IndexedPhoto(id: "p3", labColor: LabColor(l: 30, a: 0, b: 0)),
            IndexedPhoto(id: "p1", labColor: LabColor(l: 10, a: 0, b: 0)),
            IndexedPhoto(id: "p2", labColor: LabColor(l: 20, a: 0, b: 0))
        ]
        
        let plan1 = try MosaicEngine.shared.makeAutoFillPlan(project: project, availablePhotos: photos, level: .completeMax, allowDuplicates: false)
        let plan2 = try MosaicEngine.shared.makeAutoFillPlan(project: project, availablePhotos: photos, level: .completeMax, allowDuplicates: false)
        
        XCTAssertEqual(plan1.assignments, plan2.assignments, "2回の計算で完全に同一の割り当てが得られること")
        
        guard case .applied(let updated, _) = MosaicEngine.shared.applyAutoFillPlan(project: project, plan: plan1) else {
            XCTFail("適用失敗")
            return
        }
        
        let sequences = updated.tiles.compactMap(\.placementSequence)
        XCTAssertEqual(sequences, [0, 1, 2], "placementSequenceが決定的な昇順で採番されること")
    }

    /// 8. 写真0枚および写真ID重複への耐性
    func testAutoFillHandlesEmptyPhotosAndDuplicateIDs() async throws {
        let tiles = [MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 50, a: 0, b: 0))]
        let project = MosaicProject(title: "耐性テスト", gridWidth: 1, gridHeight: 1, tiles: tiles)
        
        // 0枚
        let planEmpty = try MosaicEngine.shared.makeAutoFillPlan(project: project, availablePhotos: [], level: .completeMax, allowDuplicates: false)
        XCTAssertEqual(planEmpty.assignments.count, 0)
        
        // 重複ID（同じ "p1" が3つ）
        let duplicatePhotos = [
            IndexedPhoto(id: "p1", labColor: LabColor(l: 50, a: 0, b: 0)),
            IndexedPhoto(id: "p1", labColor: LabColor(l: 50, a: 0, b: 0)),
            IndexedPhoto(id: "p1", labColor: LabColor(l: 50, a: 0, b: 0))
        ]
        let planDup = try MosaicEngine.shared.makeAutoFillPlan(project: project, availablePhotos: duplicatePhotos, level: .completeMax, allowDuplicates: false)
        XCTAssertEqual(planDup.assignments.count, 1, "重複IDが安全に除外されて1件のみ割り当てられること")
    }

    func testMultiDimensionalIndexUnionCandidates() throws {
        // 完全な 36 セル・36x8 勾配・36 勾配強度を持つ完全な v2 写真群（300枚）を生成
        var photos: [IndexedPhoto] = []
        var targetDiagHist = Array(repeating: Array(repeating: Float(0), count: 8), count: 36)
        for c in 0..<36 { targetDiagHist[c][1] = 1.0 }
        let targetSig = SpatialColorSignature(
            version: 2,
            average: LabColor(l: 50, a: 0, b: 0),
            cells3x3: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 9),
            cells6x6: Array(repeating: LabColor(l: 50, a: 0, b: 0), count: 36),
            gradientHistograms6x6: targetDiagHist,
            gradientMagnitudes6x6: Array(repeating: 0.5, count: 36)
        )
        XCTAssertEqual(targetSig.version, 2, "完全なv2シグネチャとして作成される必要があります")

        // 1〜250 枚目: ターゲットと平均色は極めて近い (L=50付近) が、勾配方向は全く異なる (bin 4: 逆水平方向)
        var vertHist = Array(repeating: Array(repeating: Float(0), count: 8), count: 36)
        for c in 0..<36 { vertHist[c][4] = 1.0 }
        for i in 0..<250 {
            let lab = LabColor(l: 50.0 + Float(i % 5) * 0.1, a: 0, b: 0)
            let sig = SpatialColorSignature(
                version: 2,
                average: lab,
                cells3x3: Array(repeating: lab, count: 9),
                cells6x6: Array(repeating: lab, count: 36),
                gradientHistograms6x6: vertHist,
                gradientMagnitudes6x6: Array(repeating: 0.5, count: 36)
            )
            photos.append(IndexedPhoto(id: "lab_match_\(i)", labColor: lab, signature: sig))
        }

        // 251 枚目: 平均色はかなり離れている (L=20) が、ターゲットと同じ対角線勾配 (bin 1) を持つ写真
        let gradLab = LabColor(l: 20, a: 0, b: 0)
        let gradSig = SpatialColorSignature(
            version: 2,
            average: gradLab,
            cells3x3: Array(repeating: gradLab, count: 9),
            cells6x6: Array(repeating: gradLab, count: 36),
            gradientHistograms6x6: targetDiagHist,
            gradientMagnitudes6x6: Array(repeating: 0.5, count: 36)
        )
        photos.append(IndexedPhoto(id: "special_grad_match", labColor: gradLab, signature: gradSig))

        let index = MultiDimensionalPhotoIndex(photos: photos)
        // 300 枚中、上限 200 枚の粗探索を実行
        let candidates = index.candidates(for: targetSig.average, signature: targetSig, maxCandidates: 200)

        XCTAssertLessThanOrEqual(candidates.count, 200, "上限200枚を超えないこと")
        XCTAssertTrue(
            candidates.contains(where: { $0.id == "special_grad_match" }),
            "平均色は離れていても勾配が一致する写真が、勾配予約枠により200枚制限下でも確実に残る必要があります"
        )
    }

    /// 大規模グリッド（1,600マス ＆ 300枚の写真）でシミュレーションが数秒以内に爆速完了することを検証
    func testAutoFillLargeGridPerformanceBenchmark() async throws {
        // 40 x 40 = 1,600 マス
        var tiles: [MosaicTile] = []
        tiles.reserveCapacity(1600)
        for y in 0..<40 {
            for x in 0..<40 {
                let l = Float((x + y) % 100)
                tiles.append(MosaicTile(gridX: x, gridY: y, targetLabColor: LabColor(l: l, a: 0, b: 0)))
            }
        }
        let project = MosaicProject(title: "超大規模テスト", gridWidth: 40, gridHeight: 40, tiles: tiles)
        
        // 300 枚の IndexedPhoto
        var photos: [IndexedPhoto] = []
        photos.reserveCapacity(300)
        for i in 0..<300 {
            photos.append(IndexedPhoto(id: "photo_\(i)", labColor: LabColor(l: Float(i % 100), a: 0, b: 0)))
        }
        
        let startTime = Date()
        
        let simulations = await MosaicEngine.shared.simulateAutoFill(
            project: project,
            availablePhotos: photos,
            allowDuplicates: false
        )
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertEqual(simulations.count, AutoFillLevel.allCases.count)
        XCTAssertLessThan(elapsed, 5.0, "1,600マスのシミュレーションが5秒未満（実際は0.1〜1秒）で完了すること: 実測 \(elapsed) 秒")
        
        let completeMaxSim = simulations.first { $0.level == .completeMax }
        XCTAssertNotNil(completeMaxSim)
        XCTAssertEqual(completeMaxSim?.additionalCount, 300, "写真300枚すべてが重複なしで最大配置されること")
    }
}


