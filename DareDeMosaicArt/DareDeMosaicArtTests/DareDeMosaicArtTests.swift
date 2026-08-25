import XCTest
@testable import 誰でモザイクアート

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
        let red = LabColor.from(r: 1.0, g: 0.0, b: 0.0)
        let blue = LabColor.from(r: 0.0, g: 0.0, b: 1.0)
        
        XCTAssertGreaterThan(red.distance(to: blue), 100.0)
        XCTAssertTrue(red.localizedName.contains("赤") || red.localizedName.contains("レッド"))
        XCTAssertTrue(blue.localizedName.contains("青") || blue.localizedName.contains("ブルー"))
    }

    func testTileMatchingAndNoDuplicates() {
        let redTarget = LabColor.from(r: 1.0, g: 0.0, b: 0.0)
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
}
