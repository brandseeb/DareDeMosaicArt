import Foundation

/// 第2段階（アルバム指定・空間色差し替え・カスタム刻印・旧データ互換性）の検証テスト
func runPhase2Verification() {
    print("\n🌟 --- 「誰でモザイクアート」第2段階 仕様・互換性テスト開始 ---")
    
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
    
    // 3. 二段階候補探索テスト
    let targetTile = MosaicTile(
        gridX: 0,
        gridY: 0,
        targetLabColor: redTarget,
        targetSignature: SpatialColorSignature(average: redTarget, cells: Array(repeating: redTarget, count: 9), contrast: 5.0)
    )
    let photosPool = [
        IndexedPhoto(id: "photo_C", labColor: redTarget),
        IndexedPhoto(id: "photo_D", labColor: LabColor.fromRGB(red: 0.0, green: 1.0, blue: 0.0)) // 緑（不一致）
    ]
    let candidates = MosaicEngine.shared.findBestMatchCandidates(
        for: targetTile,
        from: photosPool,
        excluding: ["photo_C"], // photo_C は使用中として除外
        topK: 5
    )
    assert(!candidates.contains { $0.id == "photo_C" }, "除外指定された写真は候補に含まれてはなりません")
    assert(candidates.count == 1 && candidates.first?.id == "photo_D", "未除外の写真のみが候補に現れる必要があります")
    print("✅ 二段階候補探索＆除外テスト: 正常")
    
    print("🎉 --- 第2段階 仕様・互換性テストがすべて正常にパスしました！ ---")
}
