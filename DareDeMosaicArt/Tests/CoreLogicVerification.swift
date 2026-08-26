import Foundation

/// 基本的なカラー計算とモザイクエンジンの検証テスト
func runVerification() {
    print("🚀 --- 「誰でモザイクアート」コアロジック検証開始 ---")
    
    // 1. LabColor 変換テスト
    let redLab = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
    let blueLab = LabColor.fromRGB(red: 0.0, green: 0.0, blue: 1.0)
    let greenLab = LabColor.fromRGB(red: 0.0, green: 1.0, blue: 0.0)
    let similarRedLab = LabColor.fromRGB(red: 0.95, green: 0.05, blue: 0.05)
    
    print("✅ 赤色のLab値: L=\(redLab.l), a=\(redLab.a), b=\(redLab.b), 色名=\(redLab.localizedName)")
    print("✅ 青色のLab値: L=\(blueLab.l), a=\(blueLab.a), b=\(blueLab.b), 色名=\(blueLab.localizedName)")
    
    // 2. 色差計算テスト
    let redBlueDistance = redLab.distance(to: blueLab)
    let redSimilarDistance = redLab.distance(to: similarRedLab)
    
    print("✅ 赤と青の色差 ΔE: \(redBlueDistance)")
    print("✅ 類似赤との色差 ΔE: \(redSimilarDistance)")
    
    assert(redSimilarDistance < 10.0, "類似した赤同士の色差は小さいはずです")
    assert(redBlueDistance > 50.0, "赤と青の色差は大きいはずです")
    
    // 3. タイルマッチングテスト
    let targetTiles = [
        MosaicTile(gridX: 0, gridY: 0, targetLabColor: redLab),
        MosaicTile(gridX: 1, gridY: 0, targetLabColor: blueLab),
        MosaicTile(gridX: 2, gridY: 0, targetLabColor: greenLab)
    ]
    
    let samplePhotos = [
        IndexedPhoto(id: "photo_red_1", labColor: similarRedLab)
    ]
    
    let matchedTiles = MosaicEngine.shared.matchTiles(
        tiles: targetTiles,
        availablePhotos: samplePhotos,
        allowDuplicates: false,
        passDistanceThreshold: 14.0
    )
    
    print("✅ タイルマッチング結果:")
    for (i, tile) in matchedTiles.enumerated() {
        let status = tile.isFilled ? "はまったID=\(tile.placedPhotoIdentifier ?? "")" : "なし (不足色)"
        print("   タイル\(i) (\(tile.targetLabColor.localizedName)): \(status)")
    }
    
    assert(matchedTiles[0].isFilled, "赤色のタイルには似た写真がはまるはずです")
    assert(!matchedTiles[1].isFilled, "青色のタイルには写真がないので空のはずです")
    assert(!matchedTiles[2].isFilled, "緑色のタイルには写真がないので空のはずです")

    // 3.1 3×3 空間シグネチャによる詳細評価テスト
    let gray = LabColor(l: 50, a: 0, b: 0)
    let light = LabColor(l: 85, a: 0, b: 0)
    let dark = LabColor(l: 15, a: 0, b: 0)

    let targetSignature = SpatialColorSignature(
        average: gray,
        cells: [
            dark, gray, gray,
            gray, gray, gray,
            gray, gray, light
        ]
    )
    let matchingSignature = SpatialColorSignature(
        average: gray,
        cells: [
            dark, gray, gray,
            gray, gray, gray,
            gray, gray, light
        ]
    )
    let wrongPositionSignature = SpatialColorSignature(
        average: gray,
        cells: [
            light, gray, gray,
            gray, gray, gray,
            gray, gray, dark
        ]
    )

    assert(targetSignature.distance(to: matchingSignature) < 1, "同一配置のシグネチャ距離はほぼ0のはずです")
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
        passDistanceThreshold: 20
    )
    assert(spatialResult[0].placedPhotoIdentifier == "correct-layout", "3×3の色配置が合う写真が選ばれるはずです")

    // 3.2 旧保存データ（空間シグネチャなし）を引き続き読み込めること
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
    let project = MosaicProject(
        title: "テストプロジェクト",
        targetImageData: Data(),
        gridWidth: 3,
        gridHeight: 1,
        mode: .hybrid,
        tiles: matchedTiles,
        missions: missions
    )
    
    let fitResult = MosaicEngine.shared.fitCapturedPhoto(
        project: project,
        photoData: Data(),
        photoLabColor: blueLab
    )
    print("✅ 撮影ピース当てはめ結果: 成功=\(fitResult.matchedTile != nil), メッセージ: \(fitResult.message)")
    assert(fitResult.matchedTile != nil, "青い撮影写真は青いタイルにハマるはずです")
    print("   現在の進捗: \(fitResult.updatedProject.filledCount) / \(fitResult.updatedProject.totalTilesCount) (残りミッション \(fitResult.updatedProject.missions.count) 件)")
    
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
    let placedIDs = result.compactMap(\.placedPhotoIdentifier)
    let uniqueCount = Set(placedIDs).count
    let duplicateCount = placedIDs.count - uniqueCount
    
    print("✅ 50×50 / \(photoCount)写真計測: \(String(format: "%.2f", elapsed))秒、配置 \(filledCount) / 2500, ユニーク数 \(uniqueCount) / \(filledCount) (重複: \(duplicateCount)件)")
    assert(filledCount == 2_500, "標準ベンチマークでは2,500マスすべてが埋まる必要があります")
    assert(uniqueCount == 2_500, "標準ベンチマークでは2,500枚すべてがユニークである必要があります")
    assert(duplicateCount == 0, "マッチング結果に重複した写真IDが含まれてはなりません")
}
