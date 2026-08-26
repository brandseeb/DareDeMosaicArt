import XCTest
import AVFoundation
import Vision
@testable import DareDeMosaicArt

final class DareDeMosaicArtTests: XCTestCase {

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
}
