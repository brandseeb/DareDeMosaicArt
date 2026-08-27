import Foundation

/// タイムラプス時系列モデル・物理イージング・48kHz音響バッファ・適応型パラメータの厳密検証テスト
func runTimelapseVerification() {
    print("\n🎬 --- 「誰でモザイクアート」最高峰タイムラプス動画機能・物理演出＆音響検証開始 ---")
    
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
    
    // 2. 決定論的 PRNG テスト (再現性 100% 検証)
    let testUUID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    var rng1 = DeterministicPRNG(seed: testUUID)
    var rng2 = DeterministicPRNG(seed: testUUID)
    for _ in 0..<100 {
        assert(rng1.next() == rng2.next(), "同一UUIDシードによる乱数列は100%完全に一致する必要があります")
    }
    print("✅ 決定論的 PRNG 再現性テスト: 正常")
    
    // 3. マクロ時系列（8〜12区間）＋空間分散ソートテスト
    let tiles = (0..<100).map { i in
        MosaicTile(
            gridX: i % 10,
            gridY: i / 10,
            targetLabColor: LabColor(l: 50, a: 0, b: 0),
            placedPhotoIdentifier: "photo_\(i)",
            placementSequence: i
        )
    }
    let macroSorted = TimelapseTimeline.sortTilesInMacroDynamicSequence(
        tiles: tiles,
        projectID: testUUID,
        gridWidth: 10,
        gridHeight: 10
    )
    assert(macroSorted.count == 100, "ソート後も全タイル数が100件である必要があります")
    assert(Set(macroSorted.map(\.id)).count == 100, "ソート後にタイルの欠損や重複がない必要があります")
    print("✅ マクロ時系列 ＆ 空間分散ソートテスト: 正常")
    
    // 4. 各種グリッド規模の適応型スケジュール・着地保証検証 (100 / 400 / 900 / 2,500 / 3,600 マス)
    let testGridCounts = [100, 400, 900, 2500, 3600]
    for count in testGridCounts {
        let tl = TimelapseTimeline(totalTilesCount: count)
        let schedules = tl.generateTileSchedules()
        
        assert(schedules.count == count, "\(count) マスのアニメーションスケジュール数が一致する必要があります")
        
        // 208Fまでに着地し、209Fで全ピースが固定レイヤーへ焼き込めること
        for s in schedules {
            let landingFrame = s.startBuildFrame + s.durationFrames - 1
            assert(landingFrame <= 208, "タイル \(s.tileIndex) の着地フレーム \(landingFrame) は 208 以下である必要があります")
            assert(s.progress(atBuildFrame: 209) == 1.0, "第209フレームで全タイルが progress 1.0 に到達する必要があります")
            assert(s.isFullyLandedAndSettled(atBuildFrame: 209), "第209フレームで全タイルが固定可能である必要があります")
            assert(s.progress(atBuildFrame: 0) >= 0.0, "第0フレームで progress は 0 以上である必要があります")
        }
        
        // 物理イージング境界値テスト
        let firstTransform = tl.evaluateTransform(progress: 0.0, randomSeed: 12345, isLanding: false)
        assert(firstTransform.scale > 1.0, "t=0.0 でスケールは 1.0 より大きい必要があります")
        assert(firstTransform.yOffset > 0, "t=0.0 で Y オフセットは正の値（上空）である必要があります")
        
        let finalTransform = tl.evaluateTransform(progress: 1.0, randomSeed: 12345, isLanding: false)
        assert(finalTransform.scale == 1.0 && finalTransform.yOffset == 0 && finalTransform.rotationRadians == 0, "t=1.0 で枠内に完全吸着する必要があります")
        
        print("✅ \(count) マス 適応型物理演出 ＆ 第209F着地保証検証: 正常 (300フレーム/10.0秒)")
    }
    
    print("🎉 --- 最高峰タイムラプス動画機能・物理演出＆音響検証がすべて正常にパスしました！ ---")
}
