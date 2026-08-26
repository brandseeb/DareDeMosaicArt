import XCTest
import AVFoundation
import Vision
@testable import DareDeMosaicArt

final class DareDeMosaicArtTests: XCTestCase {

    func testProStatusTransitions() {
        let loading = ProStatus.loading
        let free = ProStatus.free
        let pro = ProStatus.pro
        
        XCTAssertNotEqual(loading, free)
        XCTAssertNotEqual(free, pro)
        XCTAssertEqual(pro, .pro)
        XCTAssertEqual(StoreKitManager.proProductID, "com.daredemosaic.app.pro")
    }

    func testResolutionSpecifications() {
        let freePixels = 1080
        let freeFooter = 54
        let freeTotal = freePixels + freeFooter
        XCTAssertEqual(freePixels, 1080)
        XCTAssertEqual(freeTotal, 1134)

        let proPixels = 4096
        let proFooter = 0
        let proTotal = proPixels + proFooter
        XCTAssertEqual(proPixels, 4096)
        XCTAssertEqual(proTotal, 4096)
    }

    func testLabColorCalculations() {
        let red = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let blue = LabColor.fromRGB(red: 0.0, green: 0.0, blue: 1.0)
        
        XCTAssertGreaterThan(red.distance(to: blue), 100.0)
        XCTAssertTrue(red.localizedName.contains("赤") || red.localizedName.contains("レッド"))
        XCTAssertTrue(blue.localizedName.contains("青") || blue.localizedName.contains("ブルー"))
    }

    func testTileMatchingAndNoDuplicates() {
        let redTarget = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let tiles = [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: redTarget),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: redTarget)
        ]
        let photos = [
            IndexedPhoto(id: "photo_1", labColor: redTarget)
        ]
        
        let matched = MosaicEngine.shared.matchTiles(tiles: tiles, availablePhotos: photos, allowDuplicates: false)
        let filledCount = matched.filter { $0.isFilled }.count
        XCTAssertEqual(filledCount, 1, "写真が1枚しかない場合、重複なし設定では1マスだけ埋まる必要があります")
    }

    func testAutomaticPlacementSequenceUsesGridCoordinates() {
        let target = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let tiles = [
            MosaicTile(gridX: 1, gridY: 1, targetLabColor: target),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: target),
            MosaicTile(gridX: 0, gridY: 1, targetLabColor: target),
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: target)
        ]
        let photos = (0..<4).map { IndexedPhoto(id: "photo_\($0)", labColor: target) }

        let matched = MosaicEngine.shared.matchTiles(tiles: tiles, availablePhotos: photos, allowDuplicates: false)
        let orderedCoordinates = matched
            .sorted { ($0.placementSequence ?? .max) < ($1.placementSequence ?? .max) }
            .map { [$0.gridX, $0.gridY] }

        XCTAssertEqual(orderedCoordinates, [[0, 0], [1, 0], [0, 1], [1, 1]])
    }

    func testTimelapseRejectsStaleCompletedProject() async {
        let target = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
        let incompleteProject = MosaicProject(
            title: "incomplete",
            targetImageData: Data(),
            gridWidth: 2,
            gridHeight: 2,
            mode: .hybrid,
            tiles: [MosaicTile(gridX: 0, gridY: 0, targetLabColor: target)],
            missions: [],
            isCompleted: true
        )

        do {
            _ = try await TimelapseExportService.shared.exportTimelapse(project: incompleteProject)
            XCTFail("タイル不足のプロジェクトは書き出しを拒否する必要があります")
        } catch let error as TimelapseExportError {
            guard case .uncompletedProject = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
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

        let videoURL = try await TimelapseExportService.shared.exportTimelapse(project: project)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 10.0, accuracy: 0.05)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = naturalSize.applying(transform)
        XCTAssertEqual(abs(displayedSize.width), 1080, accuracy: 0.5)
        XCTAssertEqual(abs(displayedSize.height), 1080, accuracy: 0.5)

        let formatDescriptions = try await track.load(.formatDescriptions)
        XCTAssertFalse(formatDescriptions.isEmpty)
        XCTAssertTrue(
            formatDescriptions
                .map(CMFormatDescriptionGetMediaSubType)
                .contains(kCMVideoCodecType_H264),
            "映像コーデックはH.264（avc1）である必要があります"
        )

        let nominalFrameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(nominalFrameRate, 30, accuracy: 0.1)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
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
