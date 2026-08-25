import Foundation

/// インデックス化された写真素材情報
public struct IndexedPhoto: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String // localIdentifier または ファイルパス
    public let labColor: LabColor
    public let signature: SpatialColorSignature?
    public let thumbnailData: Data?
    
    public init(
        id: String,
        labColor: LabColor,
        signature: SpatialColorSignature? = nil,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.labColor = labColor
        self.signature = signature
        self.thumbnailData = thumbnailData
    }
}

/// モザイクアート構築・マッチングエンジン
public final class MosaicEngine: Sendable {
    public static let shared = MosaicEngine()
    
    public init() {}
    
    // MARK: - ライブラリ写真による自動マッチング (ハイブリッドモード)
    
    /// タイル配列と利用可能な写真インデックスからベストマッチを探索して割り当て（重複使用防止）
    public func matchTiles(
        tiles: [MosaicTile],
        availablePhotos: [IndexedPhoto],
        allowDuplicates: Bool = false,
        passDistanceThreshold: Float = 14.0,
        detailedDistanceThreshold: Float = 18.0,
        coarseCandidateLimit: Int = 30
    ) -> [MosaicTile] {
        guard !availablePhotos.isEmpty else { return tiles }
        
        var updatedTiles = tiles
        var usedPhotoIds = Set<String>()
        
        // 既にロック・確定しているタイルが使っている写真IDを記録
        for tile in updatedTiles where tile.isLocked {
            if let pid = tile.placedPhotoIdentifier {
                usedPhotoIds.insert(pid)
            }
        }
        
        struct Candidate {
            let photoIndex: Int
            let score: Float
        }

        let limit = max(1, min(coarseCandidateLimit, availablePhotos.count))
        var candidatesByTile = [[Candidate]](repeating: [], count: updatedTiles.count)

        // Lab空間をしきい値幅の立方体に分け、全写真の総当たりを避ける。
        struct LabBucketKey: Hashable {
            let l: Int
            let a: Int
            let b: Int
        }
        let bucketWidth = max(1, passDistanceThreshold)
        func bucketKey(for color: LabColor) -> LabBucketKey {
            LabBucketKey(
                l: Int(floor(color.l / bucketWidth)),
                a: Int(floor(color.a / bucketWidth)),
                b: Int(floor(color.b / bucketWidth))
            )
        }
        var photoBuckets: [LabBucketKey: [Int]] = [:]
        photoBuckets.reserveCapacity(min(availablePhotos.count, 2_048))
        for (index, photo) in availablePhotos.enumerated() {
            photoBuckets[bucketKey(for: photo.labColor), default: []].append(index)
        }

        // 第1段階: 平均色だけで上位候補に絞る。大きな全候補配列は保持しない。
        for (tIdx, tile) in updatedTiles.enumerated() {
            if tile.isLocked { continue }

            let center = bucketKey(for: tile.targetLabColor)
            var nearbyPhotoIndices: [Int] = []
            for dl in -1...1 {
                for da in -1...1 {
                    for db in -1...1 {
                        let key = LabBucketKey(l: center.l + dl, a: center.a + da, b: center.b + db)
                        if let indices = photoBuckets[key] {
                            nearbyPhotoIndices.append(contentsOf: indices)
                        }
                    }
                }
            }

            let coarse = nearbyPhotoIndices
                .map { (photoIndex: $0, distance: tile.targetLabColor.distance(to: availablePhotos[$0].labColor)) }
                .filter { $0.distance <= passDistanceThreshold }
                .sorted { $0.distance < $1.distance }
                .prefix(limit)

            // 第2段階: 3×3 位置とコントラストを評価。旧データは平均色にフォールバック。
            candidatesByTile[tIdx] = coarse.compactMap { item in
                let photo = availablePhotos[item.photoIndex]
                let score: Float
                if let target = tile.targetSignature, let candidate = photo.signature {
                    score = target.distance(to: candidate)
                } else {
                    score = item.distance
                }
                guard score <= detailedDistanceThreshold else { return nil }
                return Candidate(photoIndex: item.photoIndex, score: score)
            }
            .sorted { $0.score < $1.score }
        }

        var assignedPhotoForTile = [Int?](repeating: nil, count: updatedTiles.count)

        if allowDuplicates {
            for tileIndex in updatedTiles.indices where !updatedTiles[tileIndex].isLocked {
                assignedPhotoForTile[tileIndex] = candidatesByTile[tileIndex].first?.photoIndex
            }
        } else {
            var photoToTile: [Int: Int] = [:]
            let orderedTileIndices = updatedTiles.indices
                .filter { !updatedTiles[$0].isLocked && !candidatesByTile[$0].isEmpty }
                .sorted {
                    let lhs = candidatesByTile[$0]
                    let rhs = candidatesByTile[$1]
                    if lhs.count != rhs.count { return lhs.count < rhs.count }
                    let lhsRegret = lhs.count > 1 ? lhs[1].score - lhs[0].score : Float.greatestFiniteMagnitude
                    let rhsRegret = rhs.count > 1 ? rhs[1].score - rhs[0].score : Float.greatestFiniteMagnitude
                    return lhsRegret > rhsRegret
                }

            // 制約の強いマスから増加道を探し、貴重な写真を他マスが先取りしても再割当てする。
            func assign(_ tileIndex: Int, visitedPhotos: inout Set<Int>, visitedTiles: inout Set<Int>) -> Bool {
                guard visitedTiles.insert(tileIndex).inserted else { return false }
                for candidate in candidatesByTile[tileIndex] {
                    let photo = availablePhotos[candidate.photoIndex]
                    guard !usedPhotoIds.contains(photo.id), visitedPhotos.insert(candidate.photoIndex).inserted else { continue }

                    if let previousTile = photoToTile[candidate.photoIndex] {
                        if assign(previousTile, visitedPhotos: &visitedPhotos, visitedTiles: &visitedTiles) {
                            photoToTile[candidate.photoIndex] = tileIndex
                            assignedPhotoForTile[tileIndex] = candidate.photoIndex
                            return true
                        }
                    } else {
                        photoToTile[candidate.photoIndex] = tileIndex
                        assignedPhotoForTile[tileIndex] = candidate.photoIndex
                        return true
                    }
                }
                return false
            }

            for tileIndex in orderedTileIndices {
                var visitedPhotos = Set<Int>()
                var visitedTiles = Set<Int>()
                _ = assign(tileIndex, visitedPhotos: &visitedPhotos, visitedTiles: &visitedTiles)
            }
        }

        for i in updatedTiles.indices where !updatedTiles[i].isLocked {
            if let photoIndex = assignedPhotoForTile[i] {
                let photo = availablePhotos[photoIndex]
                updatedTiles[i].placedPhotoIdentifier = photo.id
                updatedTiles[i].placedLabColor = photo.labColor
                updatedTiles[i].placedSignature = photo.signature
                updatedTiles[i].thumbnailData = photo.thumbnailData
            } else {
                updatedTiles[i].placedPhotoIdentifier = nil
                updatedTiles[i].placedLabColor = nil
                updatedTiles[i].placedSignature = nil
                updatedTiles[i].thumbnailData = nil
            }
        }
        
        return updatedTiles
    }
    
    // MARK: - 不足色のミッション生成 (クラスタリング)
    
    /// 未充足タイルから「撮影ミッション」のリストを生成
    public func generateMissions(from tiles: [MosaicTile], clusterDistance: Float = 15.0) -> [ColorMission] {
        let unfilledTiles = tiles.filter { !$0.isFilled }
        guard !unfilledTiles.isEmpty else { return [] }
        
        // 色相・明度が近いタイルをグループ化
        var clusters: [(representative: LabColor, signature: SpatialColorSignature?, tileIds: [UUID])] = []
        
        for tile in unfilledTiles {
            var matchedClusterIndex: Int? = nil
            
            for (idx, cluster) in clusters.enumerated() {
                if tile.targetLabColor.distance(to: cluster.representative) <= clusterDistance {
                    matchedClusterIndex = idx
                    break
                }
            }
            
            if let idx = matchedClusterIndex {
                clusters[idx].tileIds.append(tile.id)
            } else {
                clusters.append((representative: tile.targetLabColor, signature: tile.targetSignature, tileIds: [tile.id]))
            }
        }
        
        // 要求数が多い順にソートしてミッション化
        let sortedClusters = clusters.sorted { $0.tileIds.count > $1.tileIds.count }
        
        return sortedClusters.map { cluster in
            ColorMission(
                targetColor: cluster.representative,
                targetSignature: cluster.signature,
                targetTileIds: cluster.tileIds
            )
        }
    }
    
    // MARK: - 撮影された写真のフィッティング検証 & ピース当てはめ
    
    /// 新たに撮影した写真が、ミッションまたは未充足タイルに適合するか検証して配置
    public func tryFitCapturedPhoto(
        capturedPhoto: IndexedPhoto,
        in project: inout MosaicProject,
        targetMission: ColorMission? = nil
    ) -> (success: Bool, fittedTileCount: Int, message: String) {
        var bestTileIndex: Int? = nil
        var minDistance: Float = Float.greatestFiniteMagnitude
        
        // 優先度1: 指定されたミッションの対象タイル
        var candidateTileIds = targetMission?.targetTileIds ?? []
        
        // 指定がない場合はすべての未充足タイルを候補にする
        if candidateTileIds.isEmpty {
            candidateTileIds = project.tiles.filter { !$0.isFilled }.map { $0.id }
        }
        
        // 1. 対象タイルの探索（明示的な指定がある場合は配置済みマスの再撮影・差し替えも許可）
        for tileId in candidateTileIds {
            if let index = project.tiles.firstIndex(where: { $0.id == tileId }) {
                // targetMission が特定タイルを指定している場合は再撮影（isFilled問わず）、それ以外は未充足マスのみ
                if targetMission != nil || !project.tiles[index].isFilled {
                    let targetColor = project.tiles[index].targetLabColor
                    let distance = targetColor.distance(to: capturedPhoto.labColor)
                    
                    // 撮影写真フィッティング（色差 24.0 以下でスムーズに合格）
                    if distance <= 24.0 && distance < minDistance {
                        minDistance = distance
                        bestTileIndex = index
                    }
                }
            }
        }
        
        if let index = bestTileIndex {
            project.tiles[index].placedPhotoIdentifier = capturedPhoto.id
            project.tiles[index].placedLabColor = capturedPhoto.labColor
            project.tiles[index].placedSignature = capturedPhoto.signature
            project.tiles[index].thumbnailData = capturedPhoto.thumbnailData
            project.tiles[index].isLocked = true // 撮影ピースは確定ロック
            
            // ミッション一覧を再計算
            project.missions = generateMissions(from: project.tiles)
            project.isCompleted = project.tiles.allSatisfy { $0.isFilled }
            project.updatedAt = Date()
            return (true, 1, "ナイスショット！ピースが1つハマりました！")
        } else {
            return (false, 0, "惜しい！求めている色味と少し違うようです。もう一度挑戦してみましょう。")
        }
    }
}
