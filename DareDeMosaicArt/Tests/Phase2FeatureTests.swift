import Foundation

/// 第2段階（アルバム指定・空間色差し替え・カスタム刻印・旧データ互換性・Maximum Cardinality Matching・局所スワップ）の網羅的テスト
func runPhase2Verification() {
    print("\n🌟 --- 「誰でモザイクアート」第2段階 厳密仕様・互換性テスト開始 ---")
    
    // 1. 旧JSONデータの移行テスト（photoSource, origin が無いJSONのデコード）
    let legacyJSON = """
    {
        "id": "11111111-2222-3333-4444-555555555555",
        "title": "旧バージョンの作品",
        "createdAt": 0,
        "updatedAt": 0,
        "targetImageData": "",
        "gridWidth": 2,
        "gridHeight": 2,
        "mode": "端末写真＋不足色撮影 (おすすめ)",
        "tiles": [
            {
                "id": "22222222-3333-4444-5555-666666666666",
                "gridX": 0,
                "gridY": 0,
                "targetLabColor": {"l": 50, "a": 20, "b": 30},
                "isLocked": true
            },
            {
                "id": "33333333-4444-5555-6666-777777777777",
                "gridX": 1,
                "gridY": 0,
                "targetLabColor": {"l": 80, "a": -10, "b": 10},
                "isLocked": false
            }
        ]
    }
    """.data(using: .utf8)!
    
    do {
        let legacyProject = try JSONDecoder().decode(MosaicProject.self, from: legacyJSON)
        assert(legacyProject.photoSource == .allLocalPhotos, "旧データの photoSource は .allLocalPhotos にデフォルト補完される必要があります")
        assert(legacyProject.tiles[0].origin == .captured, "旧データの isLocked=true なタイルは .captured に移行される必要があります")
        assert(legacyProject.tiles[1].origin == .automatic, "旧データの isLocked=false なタイルは .automatic に移行される必要があります")
        print("✅ 旧JSON後方互換性テスト: 正常に復元")
    } catch {
        fatalError("旧JSONのデコードに失敗しました: \(error)")
    }
    
    // 2. replacePhoto での重複拒否テスト
    let redTarget = LabColor.fromRGB(red: 1.0, green: 0.0, blue: 0.0)
    var testProject = MosaicProject(
        title: "差し替えテスト",
        targetImageData: Data(),
        gridWidth: 2,
        gridHeight: 1,
        mode: .hybrid,
        tiles: [
            MosaicTile(gridX: 0, gridY: 0, targetLabColor: redTarget, placedPhotoIdentifier: "photo_A"),
            MosaicTile(gridX: 1, gridY: 0, targetLabColor: redTarget, placedPhotoIdentifier: "photo_B")
        ]
    )
    
    let photoA = IndexedPhoto(id: "photo_A", labColor: redTarget)
    let photoC = IndexedPhoto(id: "photo_C", labColor: redTarget)
    
    // 他タイル(タイル0)で使用中の photo_A をタイル1に当てはめようとした場合 -> 拒否 (false)
    let rejectSuccess = MosaicEngine.shared.replacePhoto(in: &testProject, tileID: testProject.tiles[1].id, with: photoA)
    assert(rejectSuccess == false, "他タイルで使用中の写真は差し替えを拒否する必要があります")
    
    // 未使用の photo_C をタイル1に当てはめた場合 -> 成功 (true)
    let acceptSuccess = MosaicEngine.shared.replacePhoto(in: &testProject, tileID: testProject.tiles[1].id, with: photoC)
    assert(acceptSuccess == true, "未使用の写真は正常に差し替えられる必要があります")
    assert(testProject.tiles[1].placedPhotoIdentifier == "photo_C", "差し替え後のIDが更新されている必要があります")
    assert(testProject.tiles[1].origin == .manuallySelected, "差し替え後の origin は .manuallySelected である必要があります")
    print("✅ ピース差し替え重複拒否＆アトミック更新テスト: 正常")
    
    // 3. 3×3空間シグネチャによる順位検証テスト
    let gray = LabColor(l: 50, a: 0, b: 0)
    let light = LabColor(l: 85, a: 0, b: 0)
    let dark = LabColor(l: 15, a: 0, b: 0)
    
    // 左上が暗く右下が明るいターゲット
    let targetSig = SpatialColorSignature(
        average: gray,
        cells: [
            dark, gray, gray,
            gray, gray, gray,
            gray, gray, light
        ],
        contrast: 15.0
    )
    let targetTile = MosaicTile(
        gridX: 0,
        gridY: 0,
        targetLabColor: gray,
        targetSignature: targetSig,
        placedPhotoIdentifier: "current_photo_in_tile"
    )
    
    // 写真1: 平均色がgrayで、空間配置がターゲットと完全一致
    let matchingPhoto = IndexedPhoto(
        id: "photo_matched_spatial",
        labColor: gray,
        signature: SpatialColorSignature(
            average: gray,
            cells: [
                dark, gray, gray,
                gray, gray, gray,
                gray, gray, light
            ],
            contrast: 15.0
        )
    )
    
    // 写真2: 平均色は同じgrayだが、空間配置が反転（左上が明るく右下が暗い）
    let invertedPhoto = IndexedPhoto(
        id: "photo_inverted_spatial",
        labColor: gray,
        signature: SpatialColorSignature(
            average: gray,
            cells: [
                light, gray, gray,
                gray, gray, gray,
                gray, gray, dark
            ],
            contrast: 15.0
        )
    )
    
    // 候補探索（選択中タイルの現在の写真IDを除外）
    let candidates = MosaicEngine.shared.findBestMatchCandidates(
        for: targetTile,
        from: [matchingPhoto, invertedPhoto],
        excluding: ["current_photo_in_tile"],
        topK: 5
    )
    
    assert(!candidates.contains { $0.id == "current_photo_in_tile" }, "選択中タイル自身の現在の写真は除外される必要があります")
    assert(candidates.count == 2, "2件の候補が取得される必要があります")
    assert(candidates[0].id == "photo_matched_spatial", "3×3空間シグネチャが合致する写真が第1位（最上位）になる必要があります")
    assert(candidates[0].score < candidates[1].score, "空間配置が一致する候補のスコアがより低く（高評価）になる必要があります")
    print("✅ 3×3空間シグネチャ詳細順位＆自タイル写真除外テスト: 正常")
    
    // 4. 疎グラフ上での Maximum Cardinality Matching 検証テスト
    let flexibleColor = LabColor(l: 50, a: 0, b: 0)
    let constrainedColor = LabColor(l: 50, a: 5, b: 0)
    let scarceColor = LabColor(l: 50, a: 3, b: 0)
    let commonColor = LabColor(l: 50, a: -2, b: 0)
    
    let matchTiles = [
        MosaicTile(gridX: 0, gridY: 0, targetLabColor: flexibleColor),
        MosaicTile(gridX: 1, gridY: 0, targetLabColor: constrainedColor)
    ]
    let availablePhotos = [
        IndexedPhoto(id: "photo_scarce", labColor: scarceColor),
        IndexedPhoto(id: "photo_common", labColor: commonColor)
    ]
    
    let allocatedTiles = MosaicEngine.shared.matchTiles(
        tiles: matchTiles,
        availablePhotos: availablePhotos,
        allowDuplicates: false,
        passDistanceThreshold: 5.0
    )
    
    assert(allocatedTiles.allSatisfy { $0.isFilled }, "疎グラフ上の Maximum Cardinality Matching により両方のタイルが埋まる必要があります")
    assert(allocatedTiles[1].placedPhotoIdentifier == "photo_scarce", "選択肢が1つしかないタイル1に希少写真が割り当てられる必要があります")
    assert(allocatedTiles[0].placedPhotoIdentifier == "photo_common", "タイル0には photo_common が割り当てられる必要があります")
    print("✅ Maximum Cardinality Matching テスト: 正常")
    
    // 5. 局所スワップ（2-opt Break-and-Restart）による交差解消＆重複ゼロ回帰テスト
    // タイル0: 赤 (a: 20), タイル1: 青 (a: -20)
    // 写真0: 赤 (a: 20, photo_red), 写真1: 青 (a: -20, photo_blue)
    // 閾値: 45.0 (両写真とも両タイルにエッジを持つ)
    let swapTile0 = MosaicTile(gridX: 0, gridY: 0, targetLabColor: LabColor(l: 50, a: 20, b: 0))
    let swapTile1 = MosaicTile(gridX: 1, gridY: 0, targetLabColor: LabColor(l: 50, a: -20, b: 0))
    
    // 初期マッチングで交差が起きやすいよう、写真リストの順序をあえて逆に配置
    let swapPhotos = [
        IndexedPhoto(id: "photo_blue", labColor: LabColor(l: 50, a: -20, b: 0)),
        IndexedPhoto(id: "photo_red", labColor: LabColor(l: 50, a: 20, b: 0))
    ]
    
    let swapResult = MosaicEngine.shared.matchTiles(
        tiles: [swapTile0, swapTile1],
        availablePhotos: swapPhotos,
        allowDuplicates: false,
        passDistanceThreshold: 45.0
    )
    
    assert(swapResult.allSatisfy { $0.isFilled }, "すべてのタイルが埋まる必要があります")
    assert(swapResult[0].placedPhotoIdentifier == "photo_red", "局所スワップによりタイル0には赤色の写真が最適配置される必要があります")
    assert(swapResult[1].placedPhotoIdentifier == "photo_blue", "局所スワップによりタイル1には青色の写真が最適配置される必要があります")
    
    let swapPlacedIDs = swapResult.compactMap(\.placedPhotoIdentifier)
    assert(Set(swapPlacedIDs).count == swapPlacedIDs.count, "スワップ後も重複写真IDはゼロである必要があります")
    print("✅ 局所スワップ（2-opt Break-and-Restart）交差解消＆重複ゼロテスト: 正常")
    
    print("🎉 --- 第2段階 厳密仕様・互換性テストがすべて正常にパスしました！ ---")
}
