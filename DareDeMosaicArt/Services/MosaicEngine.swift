import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// ピースの手動差し替え候補アイテム
public struct PhotoMatchCandidate: Identifiable, Sendable, Equatable {
    public var id: String { photo.id }
    public let photo: IndexedPhoto
    public let score: Float // 低いほど一致度が高い
    public let matchRatio: Float // 0.0〜1.0 (パーセント表示用: 1.0が100%一致)
    
    public init(photo: IndexedPhoto, score: Float, matchRatio: Float) {
        self.photo = photo
        self.score = score
        self.matchRatio = matchRatio
    }
}

/// モザイクアートのピース割り当て・空間色探索・ミッション管理エンジン
public final class MosaicEngine: Sendable {
    public static let shared = MosaicEngine()
    
    private init() {}
    
    // MARK: - マッチングスコア共通計算式
    public func matchScore(
        targetColor: LabColor,
        targetSignature: SpatialColorSignature?,
        photo: IndexedPhoto
    ) -> Float {
        let labDist = targetColor.distance(to: photo.labColor)
        guard let targetSig = targetSignature, let photoSig = photo.signature else {
            return labDist
        }
        let spatialDist = targetSig.distance(to: photoSig)
        return labDist * 0.35 + spatialDist * 0.65
    }
    
    // MARK: - タイル自動マッチング（疎グラフ上の Maximum Cardinality Matching ＋ 局所スワップ最適化）
    public func matchTiles(
        tiles: [MosaicTile],
        availablePhotos: [IndexedPhoto],
        allowDuplicates: Bool = false,
        passDistanceThreshold: Float = 14.0
    ) -> [MosaicTile] {
        guard !availablePhotos.isEmpty else { return tiles }
        
        var updatedTiles = tiles
        var lockedPhotoIDs = Set<String>()
        
        for tile in updatedTiles where tile.isLocked && tile.isFilled {
            if let photoId = tile.placedPhotoIdentifier {
                lockedPhotoIDs.insert(photoId)
            }
        }
        
        let usablePhotos = availablePhotos.filter { !lockedPhotoIDs.contains($0.id) }
        guard !usablePhotos.isEmpty else { return updatedTiles }
        
        let photoIndexMap = Dictionary(uniqueKeysWithValues: usablePhotos.enumerated().map { ($1.id, $0) })
        let buckets = ColorBuckets(photos: usablePhotos)
        
        let assignableIndices = updatedTiles.indices.filter { !updatedTiles[$0].isLocked || !updatedTiles[$0].isFilled }
        
        if allowDuplicates {
            // 重複許可の場合: 各タイルのベストを直接適用
            for tileIdx in assignableIndices {
                let tile = updatedTiles[tileIdx]
                let candidates = buckets.candidates(for: tile.targetLabColor, maxRange: 28.0)
                var bestPhoto: IndexedPhoto? = nil
                var bestScore = Float.infinity
                
                for photo in candidates {
                    let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                    if score < bestScore && score <= passDistanceThreshold {
                        bestScore = score
                        bestPhoto = photo
                    }
                }
                
                if let best = bestPhoto {
                    updatedTiles[tileIdx].placedPhotoIdentifier = best.id
                    updatedTiles[tileIdx].placedLabColor = best.labColor
                    updatedTiles[tileIdx].placedSignature = best.signature
                    updatedTiles[tileIdx].thumbnailData = best.thumbnailData
                    updatedTiles[tileIdx].origin = .automatic
                }
            }
            return updatedTiles
        }
        
        // 重複不許可の場合: 疎グラフ構築 ＋ Kuhn's Maximum Cardinality Matching
        // 1. 各タイルごとに合格圏内（passDistanceThreshold以下）の上位候補エッジを抽出
        var adjList: [[(photoIdx: Int, score: Float)]] = Array(repeating: [], count: updatedTiles.count)
        // O(1) スコア参照用のマップ: [タイルIndex: [写真Index: スコア]]
        var edgeScoreMap: [Int: [Int: Float]] = [:]
        
        for tileIdx in assignableIndices {
            let tile = updatedTiles[tileIdx]
            let candidates = buckets.candidates(for: tile.targetLabColor, maxRange: 28.0)
            
            var validEdges: [(photoIdx: Int, score: Float)] = []
            for photo in candidates {
                let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                if score <= passDistanceThreshold, let pIdx = photoIndexMap[photo.id] {
                    validEdges.append((photoIdx: pIdx, score: score))
                }
            }
            validEdges.sort { $0.score < $1.score }
            let topEdges = Array(validEdges.prefix(16))
            adjList[tileIdx] = topEdges
            edgeScoreMap[tileIdx] = Dictionary(uniqueKeysWithValues: topEdges.map { ($0.photoIdx, $0.score) })
        }
        
        // 2. 最大二部マッチング（Kuhn's Augmenting Path Algorithm: 疎グラフ上での Maximum Cardinality Matching）
        var matchPtoT: [Int: Int] = [:] // 写真Index -> タイルIndex
        var matchTtoP: [Int: Int] = [:] // タイルIndex -> 写真Index
        
        func dfs(tileIdx: Int, visited: inout [Bool]) -> Bool {
            for edge in adjList[tileIdx] {
                let pIdx = edge.photoIdx
                if visited[pIdx] { continue }
                visited[pIdx] = true
                
                if let currentOwner = matchPtoT[pIdx] {
                    if dfs(tileIdx: currentOwner, visited: &visited) {
                        matchPtoT[pIdx] = tileIdx
                        matchTtoP[tileIdx] = pIdx
                        return true
                    }
                } else {
                    matchPtoT[pIdx] = tileIdx
                    matchTtoP[tileIdx] = pIdx
                    return true
                }
            }
            return false
        }
        
        let sortedTileIndices = assignableIndices.sorted {
            let countA = adjList[$0].count
            let countB = adjList[$1].count
            if countA != countB { return countA < countB }
            return (adjList[$0].first?.score ?? .infinity) < (adjList[$1].first?.score ?? .infinity)
        }
        
        for tileIdx in sortedTileIndices {
            var visited = Array(repeating: false, count: usablePhotos.count)
            _ = dfs(tileIdx: tileIdx, visited: &visited)
        }
        
        // 3. 局所スワップによるスコア改善（常に最新の 1 対 1 状態を参照し、不整合・重複を完全防止）
        var improved = true
        var passes = 0
        while improved && passes < 3 {
            improved = false
            passes += 1
            for t1 in assignableIndices {
                // ループごとに最新の p1 を動的に取得
                guard let p1 = matchTtoP[t1],
                      let score1_1 = edgeScoreMap[t1]?[p1] else { continue }
                
                for t2 in assignableIndices where t1 != t2 {
                    // ループごとに最新の p2 を動的に取得
                    guard let p2 = matchTtoP[t2], p1 != p2,
                          let score2_2 = edgeScoreMap[t2]?[p2] else { continue }
                    
                    // t1にp2、t2にp1がエッジとして存在するか確認
                    if let score1_2 = edgeScoreMap[t1]?[p2],
                       let score2_1 = edgeScoreMap[t2]?[p1] {
                        if (score1_2 + score2_1) < (score1_1 + score2_2) {
                            // スワップ実行と 1 対 1 整合性の更新
                            matchTtoP[t1] = p2
                            matchTtoP[t2] = p1
                            matchPtoT[p1] = t2
                            matchPtoT[p2] = t1
                            improved = true
                            // t1 の割り当てが変わったため、次の t2 へ進む前に inner ループを break して再評価
                            break
                        }
                    }
                }
            }
        }
        
        // 4. 重複安全確認 ＆ タイルへの反映（時系列順序の採番）
        var usedPhotoIndices = Set<Int>()
        var nextSeq = (updatedTiles.compactMap(\.placementSequence).max() ?? -1) + 1
        
        for (tileIdx, photoIdx) in matchTtoP {
            guard !usedPhotoIndices.contains(photoIdx) else { continue }
            usedPhotoIndices.insert(photoIdx)
            
            let photo = usablePhotos[photoIdx]
            updatedTiles[tileIdx].placedPhotoIdentifier = photo.id
            updatedTiles[tileIdx].placedLabColor = photo.labColor
            updatedTiles[tileIdx].placedSignature = photo.signature
            updatedTiles[tileIdx].thumbnailData = photo.thumbnailData
            updatedTiles[tileIdx].origin = .automatic
            if updatedTiles[tileIdx].placementSequence == nil {
                updatedTiles[tileIdx].placementSequence = nextSeq
                nextSeq += 1
            }
        }
        
        return updatedTiles
    }
    
    // MARK: - 手動差し替え用の類似色候補探索（二段階探索: Labバケット粗探索 30〜50枚 -> 3×3空間評価）
    public func findBestMatchCandidates(
        for tile: MosaicTile,
        from photos: [IndexedPhoto],
        excluding usedPhotoIDs: Set<String> = [],
        topK: Int = 8
    ) -> [PhotoMatchCandidate] {
        guard !photos.isEmpty else { return [] }
        
        let buckets = ColorBuckets(photos: photos)
        
        // 1. バケットから近傍写真を取得（除外写真を除く）
        var rawBucketPhotos = buckets.candidates(for: tile.targetLabColor, maxRange: 28.0)
            .filter { !usedPhotoIDs.contains($0.id) }
        
        if rawBucketPhotos.count < 30 {
            rawBucketPhotos = buckets.candidates(for: tile.targetLabColor, maxRange: 45.0)
                .filter { !usedPhotoIDs.contains($0.id) }
        }
        
        if rawBucketPhotos.count < topK {
            rawBucketPhotos = photos.filter { !usedPhotoIDs.contains($0.id) }
        }
        
        // 粗探索: 平均色距離でソートし、最大50枚に厳密制限
        rawBucketPhotos.sort {
            tile.targetLabColor.distance(to: $0.labColor) < tile.targetLabColor.distance(to: $1.labColor)
        }
        let coarseCandidates = Array(rawBucketPhotos.prefix(50))
        
        // 2. 厳選された30〜50枚に対してのみ 3×3空間シグネチャを詳細評価
        var scoredList: [(IndexedPhoto, Float)] = []
        scoredList.reserveCapacity(coarseCandidates.count)
        
        for photo in coarseCandidates {
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
            scoredList.append((photo, score))
        }
        
        // スコア昇順（一致度が高い順）にソート
        scoredList.sort { $0.1 < $1.1 }
        let topSlice = scoredList.prefix(topK)
        
        return topSlice.map { photo, score in
            let ratio = max(0.0, min(1.0, 1.0 - (score / 100.0)))
            return PhotoMatchCandidate(photo: photo, score: score, matchRatio: ratio)
        }
    }
    
    // MARK: - ピースのアトミック差し替え
    public func replacePhoto(
        in project: inout MosaicProject,
        tileID: UUID,
        with photo: IndexedPhoto
    ) -> Bool {
        guard let tileIndex = project.tiles.firstIndex(where: { $0.id == tileID }) else {
            return false
        }
        
        // 他のタイルですでに使われている写真IDの場合は重複拒否
        let isAlreadyUsedByOther = project.tiles.contains { tile in
            tile.id != tileID && tile.placedPhotoIdentifier == photo.id
        }
        guard !isAlreadyUsedByOther else {
            return false
        }
        
        // タイルの更新（最新連番を採番）
        let nextSeq = (project.tiles.compactMap(\.placementSequence).max() ?? -1) + 1
        project.tiles[tileIndex].placedPhotoIdentifier = photo.id
        project.tiles[tileIndex].placedLabColor = photo.labColor
        project.tiles[tileIndex].placedSignature = photo.signature
        project.tiles[tileIndex].thumbnailData = photo.thumbnailData
        project.tiles[tileIndex].isLocked = true
        project.tiles[tileIndex].origin = .manuallySelected
        project.tiles[tileIndex].placementSequence = nextSeq
        
        // ミッション再計算
        project.missions = generateMissions(from: project.tiles)
        project.isCompleted = project.tiles.allSatisfy { $0.isFilled }
        project.updatedAt = Date()
        
        return true
    }
    
    // MARK: - 撮影ピースの当てはめ
    public func fitCapturedPhoto(
        project: MosaicProject,
        photoData: Data,
        photoLabColor: LabColor,
        photoSignature: SpatialColorSignature? = nil,
        preferredTileID: UUID? = nil,
        passDistanceThreshold: Float = 16.0
    ) -> (updatedProject: MosaicProject, matchedTile: MosaicTile?, message: String) {
        var updatedProject = project
        let nextSeq = (updatedProject.tiles.compactMap(\.placementSequence).max() ?? -1) + 1
        
        // 1. ユーザーが特定マスを選択して撮り直した場合はそのマスに最優先で当てはめる
        if let targetID = preferredTileID,
           let index = updatedProject.tiles.firstIndex(where: { $0.id == targetID }) {
            let tile = updatedProject.tiles[index]
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: IndexedPhoto(id: "camera", labColor: photoLabColor, signature: photoSignature))
            
            if score <= passDistanceThreshold + 10.0 {
                var updatedTile = tile
                updatedTile.thumbnailData = photoData
                updatedTile.placedLabColor = photoLabColor
                updatedTile.placedSignature = photoSignature
                updatedTile.isLocked = true
                updatedTile.origin = .captured
                updatedTile.placementSequence = nextSeq
                updatedProject.tiles[index] = updatedTile
                
                updatedProject.missions = generateMissions(from: updatedProject.tiles)
                updatedProject.isCompleted = updatedProject.tiles.allSatisfy { $0.isFilled }
                updatedProject.updatedAt = Date()
                
                return (updatedProject, updatedTile, "ナイスショット！ピースを撮り直しました！")
            }
        }
        
        // 2. 未埋めタイルの中から最も合致するタイルを探す
        var bestIndex: Int? = nil
        var bestScore: Float = Float.infinity
        
        for (index, tile) in updatedProject.tiles.enumerated() {
            if tile.isFilled { continue }
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: IndexedPhoto(id: "camera", labColor: photoLabColor, signature: photoSignature))
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        
        if let index = bestIndex, bestScore <= passDistanceThreshold {
            var matchedTile = updatedProject.tiles[index]
            matchedTile.thumbnailData = photoData
            matchedTile.placedLabColor = photoLabColor
            matchedTile.placedSignature = photoSignature
            matchedTile.isLocked = true
            matchedTile.origin = .captured
            matchedTile.placementSequence = nextSeq
            updatedProject.tiles[index] = matchedTile
            
            updatedProject.missions = generateMissions(from: updatedProject.tiles)
            updatedProject.isCompleted = updatedProject.tiles.allSatisfy { $0.isFilled }
            updatedProject.updatedAt = Date()
            
            let remaining = updatedProject.tiles.filter { !$0.isFilled }.count
            let msg = remaining == 0 ? "🎉 おめでとうございます！すべてが埋まりました！" : "ナイスショット！ピースが1つハマりました！ (残り\(remaining)マス)"
            return (updatedProject, matchedTile, msg)
        }
        
        return (updatedProject, nil, "惜しい！ぴったりのマスが見つかりませんでした。レティクルの中心に色を捉えてもう一度撮影してみよう！")
    }
    
    // MARK: - ミッション自動生成
    public func generateMissions(from tiles: [MosaicTile]) -> [ColorMission] {
        let unfilledTiles = tiles.filter { !$0.isFilled }
        guard !unfilledTiles.isEmpty else { return [] }
        
        var clusters: [(representative: LabColor, tiles: [MosaicTile])] = []
        let clusterThreshold: Float = 16.0
        
        for tile in unfilledTiles {
            var merged = false
            for i in clusters.indices {
                if clusters[i].representative.distance(to: tile.targetLabColor) < clusterThreshold {
                    clusters[i].tiles.append(tile)
                    merged = true
                    break
                }
            }
            if !merged {
                clusters.append((representative: tile.targetLabColor, tiles: [tile]))
            }
        }
        
        clusters.sort { $0.tiles.count > $1.tiles.count }
        
        return clusters.prefix(6).map { cluster in
            ColorMission(
                targetColor: cluster.representative,
                targetSignature: nil,
                targetTileIds: cluster.tiles.map(\.id)
            )
        }
    }
}

/// 色探索バケットインデックス（Lab色空間での局所探索）
private struct ColorBuckets {
    private var buckets: [Int: [IndexedPhoto]] = [:]
    
    init(photos: [IndexedPhoto]) {
        for photo in photos {
            let key = bucketKey(for: photo.labColor)
            buckets[key, default: []].append(photo)
        }
    }
    
    func candidates(for targetColor: LabColor, maxRange: Float) -> [IndexedPhoto] {
        let lStep = max(1, Int(maxRange / 20.0))
        let aStep = max(1, Int(maxRange / 25.0))
        let bStep = max(1, Int(maxRange / 25.0))
        
        var results: [IndexedPhoto] = []
        let targetLIndex = Int(targetColor.l / 20.0)
        let targetAIndex = Int((targetColor.a + 128.0) / 25.0)
        let targetBIndex = Int((targetColor.b + 128.0) / 25.0)
        
        for dL in -lStep...lStep {
            for da in -aStep...aStep {
                for db in -bStep...bStep {
                    let key = (targetLIndex + dL) * 10000 + (targetAIndex + da) * 100 + (targetBIndex + db)
                    if let bucketPhotos = buckets[key] {
                        results.append(contentsOf: bucketPhotos)
                    }
                }
            }
        }
        
        return results
    }
    
    private func bucketKey(for color: LabColor) -> Int {
        let lIndex = Int(color.l / 20.0)
        let aIndex = Int((color.a + 128.0) / 25.0)
        let bIndex = Int((color.b + 128.0) / 25.0)
        return lIndex * 10000 + aIndex * 100 + bIndex
    }
}
