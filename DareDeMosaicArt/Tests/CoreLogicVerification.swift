import Foundation

// MARK: - テスト用スクリプト (SwiftCLI検証)

func runVerification() {
    print("🚀 --- 「誰でモザイクアート」コアロジック検証開始 ---")
    
    // 1. LabColor 変換テスト
    let redRGB = (r: Float(1.0), g: Float(0.0), b: Float(0.0))
    let redLab = LabColor.fromRGB(red: redRGB.r, green: redRGB.g, blue: redRGB.b)
    print("✅ 赤色のLab値: L=\(redLab.l), a=\(redLab.a), b=\(redLab.b), 色名=\(redLab.localizedName)")
    assert(redLab.l > 50 && redLab.a > 70, "赤色の変換に異常があります")
    assert(redLab.localizedName.contains("赤"), "純赤が赤系の色名になるはずです")
    
    let blueRGB = (r: Float(0.0), g: Float(0.0), b: Float(1.0))
    let blueLab = LabColor.fromRGB(red: blueRGB.r, green: blueRGB.g, blue: blueRGB.b)
    print("✅ 青色のLab値: L=\(blueLab.l), a=\(blueLab.a), b=\(blueLab.b), 色名=\(blueLab.localizedName)")
    assert(blueLab.b < -50, "青色の変換に異常があります")
    assert(blueLab.localizedName.contains("青"), "純青が青系の色名になるはずです")

    let brightGreen = LabColor.fromRGB(red: 0, green: 1, blue: 0)
    let greenMission = ColorMission(targetColor: brightGreen)
    assert(greenMission.hint.contains("若葉") || greenMission.hint.contains("緑"), "明るい緑に白色用のヒントを出してはいけません")
    
    // 2. 色差計算 (ΔE) テスト
    let distRedToBlue = redLab.distance(to: blueLab)
    print("✅ 赤と青の色差 ΔE: \(distRedToBlue)")
    assert(distRedToBlue > 100.0, "異なる色の色差が小さすぎます")
    
    let similarRed = LabColor.fromRGB(red: 0.95, green: 0.05, blue: 0.05)
    let distSimilar = redLab.distance(to: similarRed)
    print("✅ 類似赤との色差 ΔE: \(distSimilar)")
    assert(distSimilar < 10.0, "類似色の色差が大きすぎます")
    
    // 3. モザイクマッチングテスト
    let tiles = [
        MosaicTile(gridX: 0, gridY: 0, targetLabColor: redLab),
        MosaicTile(gridX: 1, gridY: 0, targetLabColor: blueLab),
        MosaicTile(gridX: 2, gridY: 0, targetLabColor: LabColor.fromRGB(red: 0.0, green: 1.0, blue: 0.0)) // 緑
    ]
    
    let photos = [
        IndexedPhoto(id: "photo_red_1", labColor: similarRed),
        IndexedPhoto(id: "photo_white_1", labColor: LabColor(l: 95, a: 0, b: 0))
    ]
    
    let matchedTiles = MosaicEngine.shared.matchTiles(
        tiles: tiles,
        availablePhotos: photos,
        passDistanceThreshold: 14.0
    )
    
    print("✅ タイルマッチング結果:")
    print("   タイル0 (赤): はまったID=\(matchedTiles[0].placedPhotoIdentifier ?? "なし (不足色)")")
    print("   タイル1 (青): はまったID=\(matchedTiles[1].placedPhotoIdentifier ?? "なし (不足色)")")
    print("   タイル2 (緑): はまったID=\(matchedTiles[2].placedPhotoIdentifier ?? "なし (不足色)")")
    assert(matchedTiles[0].placedPhotoIdentifier == "photo_red_1", "類似の赤がマッチするはずです")
    assert(matchedTiles[1].placedPhotoIdentifier == nil, "青は手持ち写真にないため不足色になるはずです")

    // 3.1 同じ平均色でも「左上が黒」と「右下が黒」を区別できること
    let black = LabColor(l: 5, a: 0, b: 0)
    let white = LabColor(l: 95, a: 0, b: 0)
    let gray = LabColor(l: 50, a: 0, b: 0)
    let targetCells = [black, black, white, black, white, white, white, white, white]
    let reversedCells = Array(targetCells.reversed())
    let targetSignature = SpatialColorSignature(average: gray, cells: targetCells)
    let matchingSignature = SpatialColorSignature(average: gray, cells: targetCells)
    let wrongPositionSignature = SpatialColorSignature(average: gray, cells: reversedCells)
    assert(targetSignature.distance(to: matchingSignature) == 0)
    assert(targetSignature.distance(to: wrongPositionSignature) > 10, "平均色が同じでも明暗の位置違いを検出するはずです")

    let spatialTile = MosaicTile(
        gridX: 0,
        gridY: 0,
        targetLabColor: gray,
        targetSignature: targetSignature
    )
    let spatialPhotos = [
        IndexedPhoto(id: "wrong-layout", labColor: gray, signature: wrongPositionSignature),
        IndexedPhoto(id: "correct-layout", labColor: gray, signature: matchingSignature)
    ]
    let spatialResult = MosaicEngine.shared.matchTiles(
        tiles: [spatialTile],
        availablePhotos: spatialPhotos,
        passDistanceThreshold: 20,
        detailedDistanceThreshold: 30
    )
    assert(spatialResult[0].placedPhotoIdentifier == "correct-layout", "3×3の色配置が合う写真が選ばれるはずです")

    // 3.2 写真1しか使えないマスを優先し、両方のマスを埋めること
    let flexibleColor = LabColor(l: 50, a: 0, b: 0)
    let constrainedColor = LabColor(l: 50, a: 3, b: 0)
    let scarcePhotoColor = LabColor(l: 50, a: 1, b: 0)
    let alternativePhotoColor = LabColor(l: 50, a: -1, b: 0)
    let allocationResult = MosaicEngine.shared.matchTiles(
        tiles: [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: flexibleColor),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: constrainedColor)
        ],
        availablePhotos: [
            IndexedPhoto(id: "scarce", labColor: scarcePhotoColor),
            IndexedPhoto(id: "alternative", labColor: alternativePhotoColor)
        ],
        passDistanceThreshold: 2.1,
        detailedDistanceThreshold: 2.1,
        coarseCandidateLimit: 2
    )
    assert(allocationResult.allSatisfy(\.isFilled), "再割り当てによって両方のマスが埋まるはずです")
    assert(allocationResult[1].placedPhotoIdentifier == "scarce")

    // 3.3 旧保存データ（空間シグネチャなし）を引き続き読み込めること
    let legacyTileJSON = #"{"id":"00000000-0000-0000-0000-000000000001","gridX":0,"gridY":0,"targetLabColor":{"l":50,"a":0,"b":0},"isLocked":false}"#.data(using: .utf8)!
    let legacyTile = try! JSONDecoder().decode(MosaicTile.self, from: legacyTileJSON)
    assert(legacyTile.targetSignature == nil && legacyTile.placedSignature == nil)
    
    // 4. ミッション生成テスト
    let missions = MosaicEngine.shared.generateMissions(from: matchedTiles)
    print("✅ 不足色ミッション生成数: \(missions.count) 件")
    for mission in missions {
        print("   👉 ミッション: \(mission.title), 残り\(mission.remainingCount)マス, ヒント: \(mission.hint)")
    }
    assert(missions.count == 2, "青と緑の2件のミッションが生成されるはずです")
    
    // 5. 撮影ピース当てはめテスト
    var project = MosaicProject(
        title: "テストプロジェクト",
        targetImageData: Data(),
        gridWidth: 3,
        gridHeight: 1,
        mode: .hybrid,
        tiles: matchedTiles,
        missions: missions
    )
    
    let capturedBluePhoto = IndexedPhoto(id: "captured_blue_photo", labColor: blueLab)
    let fitResult = MosaicEngine.shared.tryFitCapturedPhoto(
        capturedPhoto: capturedBluePhoto,
        in: &project,
        targetMission: missions.first(where: { $0.title.contains("青") || $0.title.contains("ブルー") })
    )
    print("✅ 撮影ピース当てはめ結果: 成功=\(fitResult.success), メッセージ: \(fitResult.message)")
    assert(fitResult.success, "青い撮影写真は青いタイルにハマるはずです")
    print("   現在の進捗: \(project.filledTilesCount) / \(project.totalTilesCount) (残りミッション \(project.missions.count) 件)")
    
    print("🎉 --- すべてのコアロジック検証が正常にパスしました！ ---")
}

func runPerformanceVerification(photoCount: Int = 3_000) {
    print("🏁 --- 50×50 / \(photoCount)写真 マッチング計測開始 ---")
    let tiles = (0..<2_500).map { index -> MosaicTile in
        let color = LabColor(
            l: Float(20 + index % 61),
            a: Float((index * 7) % 81 - 40),
            b: Float((index * 13) % 81 - 40)
        )
        let signature = SpatialColorSignature(average: color, cells: Array(repeating: color, count: 9))
        return MosaicTile(
            gridX: index % 50,
            gridY: index / 50,
            targetLabColor: color,
            targetSignature: signature
        )
    }
    let photos = (0..<photoCount).map { index -> IndexedPhoto in
        let color = LabColor(
            l: Float(20 + (index * 5) % 61),
            a: Float((index * 11) % 81 - 40),
            b: Float((index * 17) % 81 - 40)
        )
        let signature = SpatialColorSignature(average: color, cells: Array(repeating: color, count: 9))
        return IndexedPhoto(id: "benchmark-\(index)", labColor: color, signature: signature)
    }

    let start = Date()
    let result = MosaicEngine.shared.matchTiles(tiles: tiles, availablePhotos: photos)
    let elapsed = Date().timeIntervalSince(start)
    let filledCount = result.filter(\.isFilled).count
    print("✅ 50×50 / \(photoCount)写真計測: \(String(format: "%.2f", elapsed))秒、配置 \(filledCount) / 2500")
    assert(filledCount > 2_000, "十分な候補がある計測データで配置数が少なすぎます")
}
