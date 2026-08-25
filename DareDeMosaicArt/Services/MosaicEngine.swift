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
        // 平均色と空間シグネチャの加重平均 (空間配置を重視)
        return labDist * 0.35 + spatialDist * 0.65
    }
    
    // MARK: - タイル自動マッチング（制約優先 Greedy 割り当て: Most Constrained First）
    public func matchTiles(
        tiles: [MosaicTile],
        availablePhotos: [IndexedPhoto],
        allowDuplicates: Bool = false,
        passDistanceThreshold: Float = 14.0
    ) -> [MosaicTile] {
        guard !availablePhotos.isEmpty else { return tiles }
        
        var updatedTiles = tiles
        var usedPhotoIDs = Set<String>()
        
        // 既にロック済み・撮影済みの写真IDを使用済みセットに登録
        for tile in updatedTiles where tile.isLocked && tile.isFilled {
            if let photoId = tile.placedPhotoIdentifier {
                usedPhotoIDs.insert(photoId)
            }
        }
        
        let buckets = ColorBuckets(photos: availablePhotos)
        
        // 未割り当てタイルごとに、適合する候補写真数とベストスコアを計算
        struct TileCandidateInfo {
            let tileIndex: Int
            let bestPhoto: IndexedPhoto?
            let bestScore: Float
            let candidateCount: Int
        }
        
        var assignableIndices = updatedTiles.indices.filter { !updatedTiles[$0].isLocked || !updatedTiles[$0].isFilled }
        
        if !allowDuplicates {
            // 重複不許可の場合：候補数が少なく（希少色）、かつスコアが良いタイルから優先して割り当てる
            while !assignableIndices.isEmpty {
                var candidateInfos: [TileCandidateInfo] = []
                candidateInfos.reserveCapacity(assignableIndices.count)
                
                for index in assignableIndices {
                    let tile = updatedTiles[index]
                    let candidates = buckets.candidates(for: tile.targetLabColor, maxRange: 28.0)
                    
                    var best: IndexedPhoto? = nil
                    var bestScore = Float.infinity
                    var validCount = 0
                    
                    for photo in candidates {
                        if usedPhotoIDs.contains(photo.id) { continue }
                        let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                        if score <= passDistanceThreshold {
                            validCount += 1
                            if score < bestScore {
                                bestScore = score
                                best = photo
                            }
                        }
                    }
                    
                    candidateInfos.append(TileCandidateInfo(
                        tileIndex: index,
                        bestPhoto: best,
                        bestScore: bestScore,
                        candidateCount: validCount
                    ))
                }
                
                // 1件以上候補があるタイルの中で、最も候補数が少ない（希少）順、次いでスコアが良い順にソート
                let validInfos = candidateInfos.filter { $0.bestPhoto != nil }
                guard let mostConstrained = validInfos.min(by: {
                    if $0.candidateCount != $1.candidateCount {
                        return $0.candidateCount < $1.candidateCount
                    }
                    return $0.bestScore < $1.bestScore
                }) else {
                    // これ以上マッチする写真がなくなったため終了
                    break
                }
                
                let targetIndex = mostConstrained.tileIndex
                if let photo = mostConstrained.bestPhoto {
                    updatedTiles[targetIndex].placedPhotoIdentifier = photo.id
                    updatedTiles[targetIndex].placedLabColor = photo.labColor
                    updatedTiles[targetIndex].placedSignature = photo.signature
                    updatedTiles[targetIndex].thumbnailData = photo.thumbnailData
                    updatedTiles[targetIndex].origin = .automatic
                    usedPhotoIDs.insert(photo.id)
                }
                
                assignableIndices.removeAll { $0 == targetIndex }
            }
        } else {
            // 重複許可の場合：各タイルのベストを直接適用
            for index in assignableIndices {
                let tile = updatedTiles[index]
                let candidates = buckets.candidates(for: tile.targetLabColor, maxRange: 28.0)
                
                var bestPhoto: IndexedPhoto? = nil
                var bestScore = Float.infinity
                
                for photo in candidates {
                    let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                    if score < bestScore {
                        bestScore = score
                        bestPhoto = photo
                    }
                }
                
                if let best = bestPhoto, bestScore <= passDistanceThreshold {
                    updatedTiles[index].placedPhotoIdentifier = best.id
                    updatedTiles[index].placedLabColor = best.labColor
                    updatedTiles[index].placedSignature = best.signature
                    updatedTiles[index].thumbnailData = best.thumbnailData
                    updatedTiles[index].origin = .automatic
                }
            }
        }
        
        return updatedTiles
    }
    
    // MARK: - 手動差し替え用の類似色候補探索（二段階探索: Labバケット粗探索 -> 3×3空間評価）
    public func findBestMatchCandidates(
        for tile: MosaicTile,
        from photos: [IndexedPhoto],
        excluding usedPhotoIDs: Set<String> = [],
        topK: Int = 8
    ) -> [PhotoMatchCandidate] {
        guard !photos.isEmpty else { return [] }
        
        let buckets = ColorBuckets(photos: photos)
        
        // 1. まず標準範囲(maxRange=30.0)で近傍バケットから粗抽出
        var coarseCandidates = buckets.candidates(for: tile.targetLabColor, maxRange: 30.0)
            .filter { !usedPhotoIDs.contains($0.id) }
        
        // 候補が極端に少なければ範囲を拡大(maxRange=50.0)
        if coarseCandidates.count < topK * 2 {
            coarseCandidates = buckets.candidates(for: tile.targetLabColor, maxRange: 50.0)
                .filter { !usedPhotoIDs.contains($0.id) }
        }
        
        // それでも足りなければ全写真から除外写真以外を対象
        if coarseCandidates.count < topK {
            coarseCandidates = photos.filter { !usedPhotoIDs.contains($0.id) }
        }
        
        // 2. 3x3空間シグネチャによる詳細スコア計算
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
        
        // タイルの更新
        project.tiles[tileIndex].placedPhotoIdentifier = photo.id
        project.tiles[tileIndex].placedLabColor = photo.labColor
        project.tiles[tileIndex].placedSignature = photo.signature
        project.tiles[tileIndex].thumbnailData = photo.thumbnailData
        project.tiles[tileIndex].isLocked = true
        project.tiles[tileIndex].origin = .manuallySelected
        
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
