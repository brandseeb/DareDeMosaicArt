import Foundation

/// タイムラプス時系列モデル・フレーム配分の厳密検証テスト
func runTimelapseVerification() {
    print("\n🎬 --- 「誰でモザイクアート」第3段階 タイムラプス動画機能・タイムライン検証開始 ---")
    
    // 1. 旧JSONデータの placementSequence デコードテスト
    let legacyJSON = """
    {
        "id": "11111111-2222-3333-4444-555555555555",
        "gridX": 0,
        "gridY": 0,
        "targetLabColor": {"l": 50, "a": 20, "b": 30},
        "isLocked": true
    }
    """.data(using: .utf8)!
    
    do {
        let tile = try JSONDecoder().decode(MosaicTile.self, from: legacyJSON)
        assert(tile.placementSequence == nil, "旧JSONの placementSequence は nil にデコードされる必要があります")
        print("✅ タイムラプス旧JSON後方互換性テスト: 正常")
    } catch {
        fatalError("旧タイルのデコードに失敗しました: \(error)")
    }
    
    // 2. 時系列整列テスト（placementSequenceあり、およびフォールバック）
    let tileA = MosaicTile(gridX: 1, gridY: 1, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "pA", placementSequence: 2)
    let tileB = MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "pB", placementSequence: 0)
    let tileC = MosaicTile(gridX: 2, gridY: 2, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "pC", placementSequence: 1)
    
    let sorted = TimelapseTimeline.sortTilesInSequence([tileA, tileB, tileC])
    assert(sorted.map(\.placedPhotoIdentifier) == ["pB", "pC", "pA"], "placementSequence 昇順（0, 1, 2）で整列される必要があります")
    print("✅ 時系列シーケンス整列テスト: 正常")
    
    // 未採番旧タイルのフォールバック整列テスト
    let oldAuto = MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "auto", origin: .automatic)
    let oldCaptured = MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "captured", isLocked: true, origin: .captured)
    let oldManual = MosaicTile(gridX: 0, gridY: 1, targetLabColor: LabColor(l: 50, a: 0, b: 0), placedPhotoIdentifier: "manual", isLocked: true, origin: .manuallySelected)
    
    let oldSorted = TimelapseTimeline.sortTilesInSequence([oldManual, oldAuto, oldCaptured])
    assert(oldSorted.map(\.placedPhotoIdentifier) == ["auto", "captured", "manual"], "未採番旧タイルは origin 順（automatic -> captured -> manuallySelected）にフォールバックされる必要があります")
    print("✅ 未採番旧タイルの決定論的フォールバック整列テスト: 正常")
    
    // 3. 各種グリッドサイズ（100 / 400 / 900 / 2,500 / 3,600 マス）のタイムライン完全被覆検証
    let testGridCounts = [100, 400, 900, 2500, 3600]
    for count in testGridCounts {
        let tl = TimelapseTimeline(totalTilesCount: count)
        assert(tl.validateFullCoverage(), "\(count) マスにおいて全ビルドフレーム（210フレーム）で全タイルが過不足・重複なくちょうど1回カバーされる必要があります")
        
        let firstRange = tl.newTileRange(forBuildFrame: 0)
        assert(firstRange.lowerBound == 0, "\(count) マスの第1フレームは index 0 から開始する必要があります")
        
        let lastTarget = tl.targetCumulativeCount(forFrame: 209)
        assert(lastTarget == count, "\(count) マスの最終フレーム（209）でちょうど全タイル数 \(count) に到達する必要があります")
        
        print("✅ \(count) マス タイムライン完全被覆＆重複ゼロ検証: 正常 (300フレーム/10.0秒)")
    }
    
    print("🎉 --- タイムラプス動画機能・タイムライン検証がすべて正常にパスしました！ ---")
}
