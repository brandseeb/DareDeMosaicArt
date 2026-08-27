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
        if let targetSig = targetSignature, let photoSig = photo.signature {
            return targetSig.distance(to: photoSig)
        }
        let labDist = targetColor.distance(to: photo.labColor)
        return max(0.0, min(1.0, labDist / 40.0))
    }
    
    // MARK: - タイル自動マッチング（疎グラフ上の Maximum Cardinality Matching ＋ 局所スワップ最適化）
    public func matchTiles(
        tiles: [MosaicTile],
        availablePhotos: [IndexedPhoto],
        allowDuplicates: Bool = false,
        passDistanceThreshold: Float = 0.38,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
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
        let index = MultiDimensionalPhotoIndex(photos: usablePhotos)
        
        let assignableIndices = updatedTiles.indices.filter { !updatedTiles[$0].isLocked || !updatedTiles[$0].isFilled }
        let totalAssignable = assignableIndices.count
        
        if allowDuplicates {
            // 重複許可の場合: 各タイルのベストを直接適用
            var processed = 0
            for tileIdx in assignableIndices {
                let tile = updatedTiles[tileIdx]
                let candidates = index.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 200)
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
                
                processed += 1
                if let onProgress, processed % max(1, totalAssignable / 20) == 0 || processed == totalAssignable {
                    onProgress(processed, totalAssignable)
                }
            }
            return updatedTiles
        }
        
        // 重複不許可の場合: 疎グラフ構築 ＋ Kuhn's Maximum Cardinality Matching
        // 1. 各タイルごとに合格圏内（passDistanceThreshold以下）の上位候補エッジを抽出
        var adjList: [[(photoIdx: Int, score: Float)]] = Array(repeating: [], count: updatedTiles.count)
        var edgeScoreMap: [Int: [Int: Float]] = [:]
        
        var evaluatedCount = 0
        for tileIdx in assignableIndices {
            let tile = updatedTiles[tileIdx]
            let candidates = index.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 200)
            
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
            
            evaluatedCount += 1
            if let onProgress, evaluatedCount % max(1, totalAssignable / 20) == 0 || evaluatedCount == totalAssignable {
                onProgress(evaluatedCount, totalAssignable)
            }
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
        
        // 4. 重複安全確認 ＆ タイルへの反映（幾何学的・決定論的順序での採番）
        var usedPhotoIndices = Set<Int>()
        var nextSeq = (updatedTiles.compactMap(\.placementSequence).max() ?? -1) + 1
        
        let deterministicTileIndices = assignableIndices.sorted { lhs, rhs in
            let left = updatedTiles[lhs]
            let right = updatedTiles[rhs]
            if left.gridY != right.gridY { return left.gridY < right.gridY }
            if left.gridX != right.gridX { return left.gridX < right.gridX }
            return left.id.uuidString < right.id.uuidString
        }
        for tileIdx in deterministicTileIndices {
            guard let photoIdx = matchTtoP[tileIdx], !usedPhotoIndices.contains(photoIdx) else { continue }
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
    
    // MARK: - 手動差し替え用の類似色候補探索（多次元和集合粗探索 -> 高精度詳細評価）
    public func findBestMatchCandidates(
        for tile: MosaicTile,
        from photos: [IndexedPhoto],
        excluding usedPhotoIDs: Set<String> = [],
        topK: Int = 8
    ) -> [PhotoMatchCandidate] {
        guard !photos.isEmpty else { return [] }
        
        let usablePhotos = photos.filter { !usedPhotoIDs.contains($0.id) }
        guard !usablePhotos.isEmpty else { return [] }
        
        let index = MultiDimensionalPhotoIndex(photos: usablePhotos)
        return findBestMatchCandidates(for: tile, using: index, excluding: [], topK: topK)
    }

    /// 構築済みインデックスを再利用する候補探索。ピースを切り替えるたびの全写真再インデックス化を避ける。
    public func findBestMatchCandidates(
        for tile: MosaicTile,
        using index: MultiDimensionalPhotoIndex,
        excluding usedPhotoIDs: Set<String> = [],
        topK: Int = 8
    ) -> [PhotoMatchCandidate] {
        let candidates = index.candidates(
            for: tile.targetLabColor,
            signature: tile.targetSignature,
            maxCandidates: 100,
            excluding: usedPhotoIDs
        )
        
        var scoredList: [(IndexedPhoto, Float)] = []
        scoredList.reserveCapacity(candidates.count)
        
        for photo in candidates {
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
            scoredList.append((photo, score))
        }
        
        // スコア昇順（一致度が高い順）にソート
        scoredList.sort { $0.1 < $1.1 }
        let topSlice = scoredList.prefix(topK)
        
        return topSlice.map { photo, score in
            let ratio = max(0.0, min(1.0, 1.0 - (score / 0.38)))
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
        targetTileIDs: [UUID] = [],
        passDistanceThreshold: Float = 0.38
    ) -> (updatedProject: MosaicProject, matchedTile: MosaicTile?, message: String) {
        var updatedProject = project
        let nextSeq = (updatedProject.tiles.compactMap(\.placementSequence).max() ?? -1) + 1
        let cameraPhoto = IndexedPhoto(id: "camera", labColor: photoLabColor, signature: photoSignature)
        
        // 1. ユーザーが特定マスを選択して撮り直した場合はそのマスに最優先で当てはめる
        if let targetID = preferredTileID,
           let index = updatedProject.tiles.firstIndex(where: { $0.id == targetID }) {
            var updatedTile = updatedProject.tiles[index]
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
        
        // 2. ミッション対象マス（targetTileIDs）の中の未埋めマスから最も合致するタイルを探す
        let targetIdSet = Set(targetTileIDs)
        var bestTargetIndex: Int? = nil
        var bestTargetScore: Float = Float.infinity
        
        if !targetIdSet.isEmpty {
            for (index, tile) in updatedProject.tiles.enumerated() {
                if tile.isFilled || !targetIdSet.contains(tile.id) { continue }
                let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: cameraPhoto)
                if score < bestTargetScore {
                    bestTargetScore = score
                    bestTargetIndex = index
                }
            }
        }
        
        // 3. プロジェクト全体の未埋めマスの中から最も合致するタイルを探す
        var bestGlobalIndex: Int? = nil
        var bestGlobalScore: Float = Float.infinity
        
        for (index, tile) in updatedProject.tiles.enumerated() {
            if tile.isFilled { continue }
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: cameraPhoto)
            if score < bestGlobalScore {
                bestGlobalScore = score
                bestGlobalIndex = index
            }
        }
        
        // ミッション対象マスがあれば最優先、なければ全体の最良マスを選択
        let chosenIndex = bestTargetIndex ?? bestGlobalIndex
        
        if let index = chosenIndex {
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
        
        return (updatedProject, nil, "すべてのマスが既に埋まっています！")
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

/// 3つの独立空間インデックス（Lab、明暗重心、勾配ヒストグラム）による和集合粗探索インデックス
public struct MultiDimensionalPhotoIndex: Sendable {
    private let allPhotos: [IndexedPhoto]
    private var labBuckets: [Int: [Int]] = [:]
    private var comBuckets: [Int: [Int]] = [:]
    private var gradientBuckets: [Int: [Int]] = [:]
    
    public init(photos: [IndexedPhoto]) {
        self.allPhotos = photos
        for (idx, photo) in photos.enumerated() {
            // 1. Lab バケット
            let lK = Int(photo.labColor.l / 15.0)
            let aK = Int((photo.labColor.a + 128.0) / 20.0)
            let bK = Int((photo.labColor.b + 128.0) / 20.0)
            let labKey = lK * 10000 + aK * 100 + bK
            labBuckets[labKey, default: []].append(idx)
            
            // 2. 連続量子化明暗重心 & 比率バケット (X, Y を 5分割: -1.0..1.0 -> 0..4)
            if let sig = photo.signature {
                let darkXBin = min(4, max(0, Int((sig.darkCenterOfMassX + 1.0) * 2.5)))
                let darkYBin = min(4, max(0, Int((sig.darkCenterOfMassY + 1.0) * 2.5)))
                let ratioBin = min(3, max(0, Int(sig.darkRatio * 4.0)))
                let comKey = ratioBin * 100 + darkXBin * 10 + darkYBin
                comBuckets[comKey, default: []].append(idx)
                
                // 3. 画像全体加算勾配主方向バケット (36セル全体のヒストグラム合計)
                var globalHist = [Float](repeating: 0, count: 8)
                var globalMagSum: Float = 0
                for c in 0..<sig.gradientHistograms6x6.count {
                    let cellMag = c < sig.gradientMagnitudes6x6.count ? sig.gradientMagnitudes6x6[c] : 0.0
                    globalMagSum += cellMag
                    for b in 0..<8 {
                        globalHist[b] += sig.gradientHistograms6x6[c][b] * cellMag
                    }
                }
                
                let meanGlobalMag = globalMagSum / Float(max(1, sig.gradientHistograms6x6.count))
                if meanGlobalMag > 0.03 {
                    var maxBin = 0
                    var maxVal: Float = -1
                    for b in 0..<8 {
                        if globalHist[b] > maxVal {
                            maxVal = globalHist[b]
                            maxBin = b
                        }
                    }
                    let magBin = min(3, Int(meanGlobalMag * 10.0))
                    let gradKey = magBin * 10 + maxBin
                    gradientBuckets[gradKey, default: []].append(idx)
                }
            }
        }
    }
    
    public func candidates(
        for targetColor: LabColor,
        signature: SpatialColorSignature?,
        maxCandidates: Int = 200,
        excluding excludedPhotoIDs: Set<String> = []
    ) -> [IndexedPhoto] {
        // 1. Lab 近傍バケット探索 (±1)
        var labCandidateIndices = Set<Int>()
        let targetL = Int(targetColor.l / 15.0)
        let targetA = Int((targetColor.a + 128.0) / 20.0)
        let targetB = Int((targetColor.b + 128.0) / 20.0)
        
        for dL in -1...1 {
            for da in -1...1 {
                for db in -1...1 {
                    let key = (targetL + dL) * 10000 + (targetA + da) * 100 + (targetB + db)
                    if let list = labBuckets[key] {
                        for pIdx in list {
                            labCandidateIndices.insert(pIdx)
                        }
                    }
                }
            }
        }
        
        // signature が nil の場合（または写真側にシグネチャがない場合）は Lab 距離のみで即座に上位を抽出して超高速リターン
        guard let tSig = signature, !tSig.cells6x6.isEmpty else {
            if !excludedPhotoIDs.isEmpty {
                labCandidateIndices = labCandidateIndices.filter { !excludedPhotoIDs.contains(allPhotos[$0].id) }
            }
            if labCandidateIndices.count < min(30, allPhotos.count) {
                for i in 0..<allPhotos.count {
                    if excludedPhotoIDs.contains(allPhotos[i].id) { continue }
                    labCandidateIndices.insert(i)
                    if labCandidateIndices.count >= maxCandidates { break }
                }
            }
            let sortedLab = labCandidateIndices.map { (idx: $0, dist: targetColor.distance(to: allPhotos[$0].labColor)) }
                .sorted { $0.dist < $1.dist }
                .prefix(maxCandidates)
                .map { allPhotos[$0.idx] }
            return Array(sortedLab)
        }
        
        var comCandidateIndices = Set<Int>()
        var gradCandidateIndices = Set<Int>()
        
        // 2. 連続量子化重心近傍バケット探索 (±1)
        if let sig = signature {
            let darkXBin = min(4, max(0, Int((sig.darkCenterOfMassX + 1.0) * 2.5)))
            let darkYBin = min(4, max(0, Int((sig.darkCenterOfMassY + 1.0) * 2.5)))
            let ratioBin = min(3, max(0, Int(sig.darkRatio * 4.0)))
            
            for rB in max(0, ratioBin - 1)...min(3, ratioBin + 1) {
                for dx in -1...1 {
                    let targetX = darkXBin + dx
                    guard targetX >= 0 && targetX <= 4 else { continue }
                    for dy in -1...1 {
                        let targetY = darkYBin + dy
                        guard targetY >= 0 && targetY <= 4 else { continue }
                        let comKey = rB * 100 + targetX * 10 + targetY
                        if let list = comBuckets[comKey] {
                            for pIdx in list {
                                comCandidateIndices.insert(pIdx)
                            }
                        }
                    }
                }
            }
            
            // 3. 画像全体加算勾配主方向バケット探索 (±1)
            var globalHist = [Float](repeating: 0, count: 8)
            var globalMagSum: Float = 0
            for c in 0..<sig.gradientHistograms6x6.count {
                let cellMag = c < sig.gradientMagnitudes6x6.count ? sig.gradientMagnitudes6x6[c] : 0.0
                globalMagSum += cellMag
                for b in 0..<8 {
                    globalHist[b] += sig.gradientHistograms6x6[c][b] * cellMag
                }
            }
            let meanGlobalMag = globalMagSum / Float(max(1, sig.gradientHistograms6x6.count))
            if meanGlobalMag > 0.03 {
                var maxBin = 0
                var maxVal: Float = -1
                for b in 0..<8 {
                    if globalHist[b] > maxVal {
                        maxVal = globalHist[b]
                        maxBin = b
                    }
                }
                let magBin = min(3, Int(meanGlobalMag * 10.0))
                for mb in max(0, magBin - 1)...min(3, magBin + 1) {
                    for b in [ (maxBin + 7) % 8, maxBin, (maxBin + 1) % 8 ] {
                        let gradKey = mb * 10 + b
                        if let list = gradientBuckets[gradKey] {
                            for pIdx in list {
                                gradCandidateIndices.insert(pIdx)
                            }
                        }
                    }
                }
            }
        }
        
        // signature が nil の場合（または写真側にシグネチャがない場合）は Lab 距離のみで即座に上位を抽出して高速リターン
        guard let tSig = signature, !tSig.cells6x6.isEmpty else {
            if !excludedPhotoIDs.isEmpty {
                labCandidateIndices = labCandidateIndices.filter { !excludedPhotoIDs.contains(allPhotos[$0].id) }
            }
            let sortedLab = labCandidateIndices.map { (idx: $0, dist: targetColor.distance(to: allPhotos[$0].labColor)) }
                .sorted { $0.dist < $1.dist }
                .prefix(maxCandidates)
                .map { allPhotos[$0.idx] }
            return Array(sortedLab)
        }
        
        if !excludedPhotoIDs.isEmpty {
            labCandidateIndices = labCandidateIndices.filter { !excludedPhotoIDs.contains(allPhotos[$0].id) }
            comCandidateIndices = comCandidateIndices.filter { !excludedPhotoIDs.contains(allPhotos[$0].id) }
            gradCandidateIndices = gradCandidateIndices.filter { !excludedPhotoIDs.contains(allPhotos[$0].id) }
        }

        // フォールバック（除外後の候補が少なすぎる場合は未使用写真から補充）
        let allUniqueCount = labCandidateIndices.union(comCandidateIndices).union(gradCandidateIndices).count
        if allUniqueCount < min(30, max(0, allPhotos.count - excludedPhotoIDs.count)) {
            for i in 0..<allPhotos.count {
                if excludedPhotoIDs.contains(allPhotos[i].id) { continue }
                labCandidateIndices.insert(i)
                if labCandidateIndices.count >= maxCandidates { break }
            }
        }
        
        // 予約枠の割り振りと各ソースごとの上位抽出（Lab 40%, CoM 30%, 勾配 30%）
        let labQuota = max(1, Int(Float(maxCandidates) * 0.40))  // 例: 80枚
        let comQuota = max(1, Int(Float(maxCandidates) * 0.30))  // 例: 60枚
        let gradQuota = max(1, Int(Float(maxCandidates) * 0.30)) // 例: 60枚
        
        let topLab = Array(labCandidateIndices.map { (idx: $0, dist: targetColor.distance(to: allPhotos[$0].labColor)) }
            .sorted { $0.dist < $1.dist }
            .prefix(labQuota)
            .map(\.idx))
            
        let topCom = Array(comCandidateIndices.map { idx -> (idx: Int, dist: Float) in
            guard let pSig = allPhotos[idx].signature else {
                return (idx, targetColor.distance(to: allPhotos[idx].labColor))
            }
            let dx = tSig.darkCenterOfMassX - pSig.darkCenterOfMassX
            let dy = tSig.darkCenterOfMassY - pSig.darkCenterOfMassY
            let dCoM = sqrt(dx * dx + dy * dy)
            return (idx, dCoM + abs(tSig.darkRatio - pSig.darkRatio))
        }.sorted { $0.dist < $1.dist }
        .prefix(comQuota)
        .map(\.idx))
        
        let hasGradHist = !tSig.gradientHistograms6x6.isEmpty
        let topGrad = Array(gradCandidateIndices.map { idx -> (idx: Int, dist: Float) in
            guard hasGradHist, let pSig = allPhotos[idx].signature, !pSig.gradientHistograms6x6.isEmpty else {
                return (idx, targetColor.distance(to: allPhotos[idx].labColor))
            }
            var sumDiff: Float = 0
            for c in 0..<min(tSig.gradientHistograms6x6.count, pSig.gradientHistograms6x6.count) {
                for b in 0..<8 {
                    sumDiff += abs(tSig.gradientHistograms6x6[c][b] - pSig.gradientHistograms6x6[c][b])
                }
            }
            return (idx, sumDiff)
        }.sorted { $0.dist < $1.dist }
        .prefix(gradQuota)
        .map(\.idx))
        
        // 予約枠の結合
        var finalCandidateIndices = Set<Int>()
        finalCandidateIndices.formUnion(topLab)
        finalCandidateIndices.formUnion(topCom)
        finalCandidateIndices.formUnion(topGrad)
        
        // もし maxCandidates に達していなければ、全プールから簡易複合スコア順で補充
        if finalCandidateIndices.count < maxCandidates {
            let remainingPool = labCandidateIndices.union(comCandidateIndices).union(gradCandidateIndices)
                .subtracting(finalCandidateIndices)
            let sortedRemaining = remainingPool.map { idx -> (idx: Int, score: Float) in
                (idx, quickCoarseScore(targetColor: targetColor, targetSig: tSig, photo: allPhotos[idx]))
            }.sorted { $0.score < $1.score }
            
            for item in sortedRemaining {
                finalCandidateIndices.insert(item.idx)
                if finalCandidateIndices.count >= maxCandidates { break }
            }
        }
        
        return finalCandidateIndices.map { allPhotos[$0] }
    }
    
    private func quickCoarseScore(targetColor: LabColor, targetSig: SpatialColorSignature?, photo: IndexedPhoto) -> Float {
        let labDist = max(0.0, min(1.0, targetColor.distance(to: photo.labColor) / 40.0))
        guard let tSig = targetSig, let pSig = photo.signature else {
            return labDist
        }
        let darkDx = tSig.darkCenterOfMassX - pSig.darkCenterOfMassX
        let darkDy = tSig.darkCenterOfMassY - pSig.darkCenterOfMassY
        let comDist = min(1.0, sqrt(darkDx * darkDx + darkDy * darkDy) / 2.0)
        let ratioDist = min(1.0, abs(tSig.darkRatio - pSig.darkRatio))
        return labDist * 0.40 + comDist * 0.35 + ratioDist * 0.25
    }
}

// MARK: - スマート・オートフィル（空きマスの段階的近似自動配置）

/// オートフィルの緩和レベル
public enum AutoFillLevel: String, CaseIterable, Sendable, Identifiable {
    case relaxed5    // +5% ゆるめる
    case relaxed15   // +15% ゆるめる
    case relaxed30   // +30% ゆるめる
    case completeMax // 可能な限り埋める / 100% 完全完成
    
    public var id: String { rawValue }
    
    public var shortTitle: String {
        switch self {
        case .relaxed5: return "+5% ゆるめる"
        case .relaxed15: return "+15% ゆるめる"
        case .relaxed30: return "+30% ゆるめる"
        case .completeMax: return "可能な限り埋める"
        }
    }
    
    public var detailDescription: String {
        switch self {
        case .relaxed5: return "アート品質を最優先し、惜しかった近似写真を優先配置"
        case .relaxed15: return "全体の自然さを保ちながらバランス良く配置"
        case .relaxed30: return "積極的に近似写真を配置して完成度を大きく向上"
        case .completeMax: return "手持ちの写真を最大限活用して空きマスを一括配置"
        }
    }
    
    public func threshold(baseThreshold: Float = 0.38) -> Float {
        switch self {
        case .relaxed5:    return min(1.0, baseThreshold * 1.05)
        case .relaxed15:   return min(1.0, baseThreshold * 1.15)
        case .relaxed30:   return min(1.0, baseThreshold * 1.30)
        case .completeMax: return 1.0
        }
    }
}

/// オートフィル割り当て情報
public struct AutoFillAssignment: Sendable, Equatable {
    public let tileID: UUID
    public let photo: IndexedPhoto
    public let score: Float
    
    public init(tileID: UUID, photo: IndexedPhoto, score: Float) {
        self.tileID = tileID
        self.photo = photo
        self.score = score
    }
}

/// オートフィル配置計画（純粋関数生成物）
public struct AutoFillPlan: Sendable, Equatable {
    public let projectId: UUID
    public let projectUpdatedAt: Date
    public let allowDuplicates: Bool
    public let level: AutoFillLevel
    public let assignments: [AutoFillAssignment]
    public let newFilledCount: Int
    public let totalTilesCount: Int
    public let projectedProgress: Float
    
    public init(
        projectId: UUID,
        projectUpdatedAt: Date,
        allowDuplicates: Bool,
        level: AutoFillLevel,
        assignments: [AutoFillAssignment],
        newFilledCount: Int,
        totalTilesCount: Int,
        projectedProgress: Float
    ) {
        self.projectId = projectId
        self.projectUpdatedAt = projectUpdatedAt
        self.allowDuplicates = allowDuplicates
        self.level = level
        self.assignments = assignments
        self.newFilledCount = newFilledCount
        self.totalTilesCount = totalTilesCount
        self.projectedProgress = projectedProgress
    }
}

/// オートフィル適用の結果型
public enum AutoFillApplyResult: Sendable {
    case applied(project: MosaicProject, placedCount: Int)
    case stale      // プロジェクト状態が変更されている（再シミュレーション必要）
    case invalid    // 不正な操作
}

/// UI用シミュレーション結果モデル
public struct AutoFillSimulation: Identifiable, Sendable {
    public var id: AutoFillLevel { level }
    public let level: AutoFillLevel
    public let title: String
    public let detail: String
    public let additionalCount: Int
    public let newFilledCount: Int
    public let totalTilesCount: Int
    public let projectedProgress: Float
    public let isFullCompletion: Bool
    public let statusMessage: String
    public let isExecutable: Bool
    public let plan: AutoFillPlan
    
    public init(
        level: AutoFillLevel,
        title: String,
        detail: String,
        additionalCount: Int,
        newFilledCount: Int,
        totalTilesCount: Int,
        projectedProgress: Float,
        isFullCompletion: Bool,
        statusMessage: String,
        isExecutable: Bool,
        plan: AutoFillPlan
    ) {
        self.level = level
        self.title = title
        self.detail = detail
        self.additionalCount = additionalCount
        self.newFilledCount = newFilledCount
        self.totalTilesCount = totalTilesCount
        self.projectedProgress = projectedProgress
        self.isFullCompletion = isFullCompletion
        self.statusMessage = statusMessage
        self.isExecutable = isExecutable
        self.plan = plan
    }
}

// MARK: - MosaicEngine オートフィル拡張
extension MosaicEngine {
    
    /// 空きマスに対するオートフィル計画の決定論的生成
    public func makeAutoFillPlan(
        project: MosaicProject,
        availablePhotos: [IndexedPhoto],
        level: AutoFillLevel,
        allowDuplicates: Bool,
        baseThreshold: Float = 0.38
    ) throws -> AutoFillPlan {
        if Task.isCancelled { throw CancellationError() }
        
        // 1. 写真 ID の完全な重複排除（決定的に昇順ソートして 1 件ずつ抽出）
        var seenPhotoIDs = Set<String>()
        var uniquePhotos: [IndexedPhoto] = []
        for photo in availablePhotos.sorted(by: { $0.id < $1.id }) {
            if !seenPhotoIDs.contains(photo.id) {
                seenPhotoIDs.insert(photo.id)
                uniquePhotos.append(photo)
            }
        }
        
        let threshold = level.threshold(baseThreshold: baseThreshold)
        let initialFilledCount = project.filledCount
        let totalCount = project.totalTilesCount
        
        guard !uniquePhotos.isEmpty else {
            return AutoFillPlan(
                projectId: project.id,
                projectUpdatedAt: project.updatedAt,
                allowDuplicates: allowDuplicates,
                level: level,
                assignments: [],
                newFilledCount: initialFilledCount,
                totalTilesCount: totalCount,
                projectedProgress: project.progress
            )
        }
        
        // 2. 対象タイルの厳格抽出（!isFilled && !isLocked のみ、gridY -> gridX -> id 順で決定的ソート）
        let targetTiles = project.tiles.filter { !$0.isFilled && !$0.isLocked }.sorted {
            if $0.gridY != $1.gridY { return $0.gridY < $1.gridY }
            if $0.gridX != $1.gridX { return $0.gridX < $1.gridX }
            return $0.id.uuidString < $1.id.uuidString
        }
        
        guard !targetTiles.isEmpty else {
            return AutoFillPlan(
                projectId: project.id,
                projectUpdatedAt: project.updatedAt,
                allowDuplicates: allowDuplicates,
                level: level,
                assignments: [],
                newFilledCount: initialFilledCount,
                totalTilesCount: totalCount,
                projectedProgress: project.progress
            )
        }
        
        // 3. 未使用写真の抽出（重複不許可の場合）
        let usedPhotoIDs = Set(project.tiles.compactMap(\.placedPhotoIdentifier))
        let usablePhotos = allowDuplicates ? uniquePhotos : uniquePhotos.filter { !usedPhotoIDs.contains($0.id) }
        
        guard !usablePhotos.isEmpty else {
            return AutoFillPlan(
                projectId: project.id,
                projectUpdatedAt: project.updatedAt,
                allowDuplicates: allowDuplicates,
                level: level,
                assignments: [],
                newFilledCount: initialFilledCount,
                totalTilesCount: totalCount,
                projectedProgress: project.progress
            )
        }
        
        let photoIndexMap = Dictionary(uniqueKeysWithValues: usablePhotos.enumerated().map { ($1.id, $0) })
        let photoIndex = MultiDimensionalPhotoIndex(photos: usablePhotos)
        
        // 4. 重複許可の場合の割り当て（高速1-pass探索）
        if allowDuplicates {
            var assignments: [AutoFillAssignment] = []
            assignments.reserveCapacity(targetTiles.count)
            
            for tile in targetTiles {
                if Task.isCancelled { throw CancellationError() }
                
                let candidates = photoIndex.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 64)
                var bestPhoto: IndexedPhoto? = nil
                var bestScore = Float.infinity
                
                for photo in candidates {
                    let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                    if score.isFinite && !score.isNaN && score <= threshold {
                        if score < bestScore || (score == bestScore && photo.id < (bestPhoto?.id ?? "")) {
                            bestScore = score
                            bestPhoto = photo
                        }
                    }
                }
                
                // level == .completeMax で万一候補内で見つからない場合、全写真から探索
                if bestPhoto == nil && level == .completeMax {
                    for photo in usablePhotos {
                        let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                        if score.isFinite && !score.isNaN && score <= threshold {
                            if score < bestScore || (score == bestScore && photo.id < (bestPhoto?.id ?? "")) {
                                bestScore = score
                                bestPhoto = photo
                            }
                        }
                    }
                }
                
                if let best = bestPhoto {
                    assignments.append(AutoFillAssignment(tileID: tile.id, photo: best, score: bestScore))
                }
            }
            
            let newTotal = initialFilledCount + assignments.count
            let projected = totalCount > 0 ? Float(newTotal) / Float(totalCount) : 1.0
            return AutoFillPlan(
                projectId: project.id,
                projectUpdatedAt: project.updatedAt,
                allowDuplicates: allowDuplicates,
                level: level,
                assignments: assignments,
                newFilledCount: newTotal,
                totalTilesCount: totalCount,
                projectedProgress: projected
            )
        }
        
        // 5. 重複不許可の場合（Greedy 最優先割り当て ＆ Kuhn 増大路 ＆ 2-opt）
        var adjList: [[(photoIdx: Int, score: Float)]] = Array(repeating: [], count: targetTiles.count)
        var scoreCache: [Int: [Int: Float]] = [:]
        var allCandidateEdges: [(tIdx: Int, photoIdx: Int, score: Float)] = []
        
        for (tIdx, tile) in targetTiles.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let candidates = photoIndex.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 48)
            var validEdges: [(photoIdx: Int, score: Float)] = []
            validEdges.reserveCapacity(candidates.count)
            
            for photo in candidates {
                let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                if score.isFinite && !score.isNaN && score <= threshold, let pIdx = photoIndexMap[photo.id] {
                    validEdges.append((photoIdx: pIdx, score: score))
                    allCandidateEdges.append((tIdx: tIdx, photoIdx: pIdx, score: score))
                }
            }
            validEdges.sort {
                if $0.score != $1.score { return $0.score < $1.score }
                return usablePhotos[$0.photoIdx].id < usablePhotos[$1.photoIdx].id
            }
            
            let topEdges = Array(validEdges.prefix(32))
            adjList[tIdx] = topEdges
            scoreCache[tIdx] = Dictionary(uniqueKeysWithValues: topEdges.map { ($0.photoIdx, $0.score) })
        }
        
        var matchPtoT = Array<Int?>(repeating: nil, count: usablePhotos.count)
        var matchTtoP = Array<Int?>(repeating: nil, count: targetTiles.count)
        
        // 5-1. Greedy 最優先割り当て（スコア昇順＝最も似ているペアから確定）
        allCandidateEdges.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.tIdx != $1.tIdx { return $0.tIdx < $1.tIdx }
            return usablePhotos[$0.photoIdx].id < usablePhotos[$1.photoIdx].id
        }
        for edge in allCandidateEdges {
            if matchTtoP[edge.tIdx] == nil && matchPtoT[edge.photoIdx] == nil {
                matchTtoP[edge.tIdx] = edge.photoIdx
                matchPtoT[edge.photoIdx] = edge.tIdx
            }
        }
        
        // 5-2. Kuhn 増大路探索（Greedy で未割り当てのマスを追加最大化）
        var visitedToken = Array(repeating: 0, count: usablePhotos.count)
        var currentToken = 0
        
        func dfs(tIdx: Int, token: Int) -> Bool {
            for edge in adjList[tIdx] {
                let pIdx = edge.photoIdx
                if visitedToken[pIdx] == token { continue }
                visitedToken[pIdx] = token
                
                if let currentOwner = matchPtoT[pIdx] {
                    if dfs(tIdx: currentOwner, token: token) {
                        matchPtoT[pIdx] = tIdx
                        matchTtoP[tIdx] = pIdx
                        return true
                    }
                } else {
                    matchPtoT[pIdx] = tIdx
                    matchTtoP[tIdx] = pIdx
                    return true
                }
            }
            return false
        }
        
        let unassignedIndices = (0..<targetTiles.count).filter { matchTtoP[$0] == nil }
        for tIdx in unassignedIndices {
            currentToken += 1
            _ = dfs(tIdx: tIdx, token: currentToken)
        }
        
        var bestMatchingTtoP: [Int: Int] = [:]
        for (tIdx, maybePIdx) in matchTtoP.enumerated() {
            if let pIdx = maybePIdx {
                bestMatchingTtoP[tIdx] = pIdx
            }
        }
        
        // 5-3. .completeMax で 32 候補でも不足する場合、未割り当てタイルと未使用写真をストリーミングで補完
        if level == .completeMax && bestMatchingTtoP.count < min(targetTiles.count, usablePhotos.count) {
            if Task.isCancelled { throw CancellationError() }
            
            var assignedPhotos = Set(bestMatchingTtoP.values)
            let unassignedTileIndices = (0..<targetTiles.count).filter { bestMatchingTtoP[$0] == nil }
            var remainingPool = (0..<usablePhotos.count).filter { !assignedPhotos.contains($0) }
            
            for tIdx in unassignedTileIndices {
                if remainingPool.isEmpty { break }
                let tile = targetTiles[tIdx]
                
                var bestPoolIdx = 0
                var bestScore: Float = Float.infinity
                for (idx, pIdx) in remainingPool.enumerated() {
                    let p = usablePhotos[pIdx]
                    let s = max(0.0, min(1.0, tile.targetLabColor.distance(to: p.labColor) / 40.0))
                    if s < bestScore {
                        bestScore = s
                        bestPoolIdx = idx
                    }
                }
                
                let chosenPIdx = remainingPool.remove(at: bestPoolIdx)
                bestMatchingTtoP[tIdx] = chosenPIdx
                assignedPhotos.insert(chosenPIdx)
                if scoreCache[tIdx] == nil { scoreCache[tIdx] = [:] }
                scoreCache[tIdx]?[chosenPIdx] = bestScore
            }
        }
        
        // 6. 2-opt スワップ改善
        if bestMatchingTtoP.count > 1 {
            bestMatchingTtoP = optimizeAutoFill2Opt(
                matching: bestMatchingTtoP,
                tiles: targetTiles,
                photos: usablePhotos,
                scoreCache: &scoreCache,
                adjList: adjList
            )
        }
        
        // 7. 割り当て配列の構築（決定的に targetTiles 順）
        var assignments: [AutoFillAssignment] = []
        assignments.reserveCapacity(bestMatchingTtoP.count)
        
        for tIdx in 0..<targetTiles.count {
            if let pIdx = bestMatchingTtoP[tIdx] {
                let tile = targetTiles[tIdx]
                let photo = usablePhotos[pIdx]
                let score = scoreCache[tIdx]?[pIdx] ?? matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                assignments.append(AutoFillAssignment(tileID: tile.id, photo: photo, score: score))
            }
        }
        
        let newTotal = initialFilledCount + assignments.count
        let projected = totalCount > 0 ? Float(newTotal) / Float(totalCount) : 1.0
        return AutoFillPlan(
            projectId: project.id,
            projectUpdatedAt: project.updatedAt,
            allowDuplicates: allowDuplicates,
            level: level,
            assignments: assignments,
            newFilledCount: newTotal,
            totalTilesCount: totalCount,
            projectedProgress: projected
        )
    }
    
    /// 高速局所 2-opt 最適化（自身の候補リストに含まれる写真を持つタイル間のみ評価して O(N * K) に短縮）
    private func optimizeAutoFill2Opt(
        matching: [Int: Int],
        tiles: [MosaicTile],
        photos: [IndexedPhoto],
        scoreCache: inout [Int: [Int: Float]],
        adjList: [[(photoIdx: Int, score: Float)]]
    ) -> [Int: Int] {
        var currentMatching = matching
        var photoToTileMap = Dictionary(uniqueKeysWithValues: currentMatching.map { ($1, $0) })
        let matchedTileIndices = Array(currentMatching.keys).sorted()
        
        func getScore(tIdx: Int, pIdx: Int) -> Float {
            if let cached = scoreCache[tIdx]?[pIdx] { return cached }
            let s = matchScore(targetColor: tiles[tIdx].targetLabColor, targetSignature: tiles[tIdx].targetSignature, photo: photos[pIdx])
            if scoreCache[tIdx] == nil { scoreCache[tIdx] = [:] }
            scoreCache[tIdx]?[pIdx] = s
            return s
        }
        
        for _ in 0..<2 {
            if Task.isCancelled { break }
            var passImproved = false
            
            for t1 in matchedTileIndices {
                guard let p1 = currentMatching[t1] else { continue }
                
                // t1 の上位候補に含まれる写真を持つ相手タイル t2 のみを評価
                let candidatePhotoIdxs = adjList[t1].prefix(8).map(\.photoIdx)
                for p2 in candidatePhotoIdxs {
                    guard p2 != p1, let t2 = photoToTileMap[p2] else { continue }
                    
                    let curScore = getScore(tIdx: t1, pIdx: p1) + getScore(tIdx: t2, pIdx: p2)
                    let swappedScore = getScore(tIdx: t1, pIdx: p2) + getScore(tIdx: t2, pIdx: p1)
                    
                    if swappedScore + 0.0001 < curScore {
                        currentMatching[t1] = p2
                        currentMatching[t2] = p1
                        photoToTileMap[p2] = t1
                        photoToTileMap[p1] = t2
                        passImproved = true
                        break
                    }
                }
            }
            if !passImproved { break }
        }
        
        return currentMatching
    }
    
    /// オートフィル計画の適用（整合性検証 ＆ 決定的採番 ＆ 完全更新）
    public func applyAutoFillPlan(
        project: MosaicProject,
        plan: AutoFillPlan
    ) -> AutoFillApplyResult {
        // 1. プロジェクト状態の整合性検証（ステイル防止）
        guard plan.projectId == project.id && plan.projectUpdatedAt == project.updatedAt else {
            return .stale
        }
        
        let assignmentMap = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.tileID, $0) })
        
        // 2. 各対象タイルの最新状態を検証（空きマスかつ未ロックであること）
        for assignment in plan.assignments {
            guard let tile = project.tiles.first(where: { $0.id == assignment.tileID }),
                  !tile.isFilled,
                  !tile.isLocked else {
                return .stale
            }
        }
        
        // 3. 重複不許可の場合、写真が現在も未使用であることを検証
        if !plan.allowDuplicates {
            let usedIDs = Set(project.tiles.compactMap(\.placedPhotoIdentifier))
            for assignment in plan.assignments {
                if usedIDs.contains(assignment.photo.id) {
                    return .stale
                }
            }
        }
        
        // 4. タイルの更新（決定的な採番順）
        var updatedTiles = project.tiles
        var currentMaxSequence = updatedTiles.compactMap(\.placementSequence).max() ?? -1
        
        // タイル座標順（gridY * width + gridX）でソートして昇順に採番
        let sortedTileIndices = updatedTiles.indices
            .filter { assignmentMap[updatedTiles[$0].id] != nil }
            .sorted { idx1, idx2 in
                let t1 = updatedTiles[idx1]
                let t2 = updatedTiles[idx2]
                if t1.gridY != t2.gridY { return t1.gridY < t2.gridY }
                return t1.gridX < t2.gridX
            }
        
        for idx in sortedTileIndices {
            let tileID = updatedTiles[idx].id
            guard let assignment = assignmentMap[tileID] else { continue }
            
            currentMaxSequence += 1
            updatedTiles[idx].placedPhotoIdentifier = assignment.photo.id
            updatedTiles[idx].placedLabColor = assignment.photo.labColor
            updatedTiles[idx].placedSignature = assignment.photo.signature
            updatedTiles[idx].thumbnailData = assignment.photo.thumbnailData
            updatedTiles[idx].origin = .autoFilled
            updatedTiles[idx].isLocked = false
            updatedTiles[idx].placementSequence = currentMaxSequence
        }
        
        // 5. 不足色ミッション、完成状態、更新日時の再構築
        let newMissions = generateMissions(from: updatedTiles)
        let isNowCompleted = updatedTiles.allSatisfy { $0.isFilled }
        
        var newProject = project
        newProject.tiles = updatedTiles
        newProject.missions = newMissions
        newProject.isCompleted = isNowCompleted
        newProject.updatedAt = Date()
        
        return .applied(project: newProject, placedCount: plan.assignments.count)
    }
    
    /// 全レベルのシミュレーション結果を一括高速生成（1-pass 候補キャッシュ共有）
    public func simulateAutoFill(
        project: MosaicProject,
        availablePhotos: [IndexedPhoto],
        allowDuplicates: Bool,
        baseThreshold: Float = 0.38
    ) async -> [AutoFillSimulation] {
        if Task.isCancelled { return [] }
        
        // 1. 写真 ID の完全な重複排除
        var seenPhotoIDs = Set<String>()
        var uniquePhotos: [IndexedPhoto] = []
        for photo in availablePhotos.sorted(by: { $0.id < $1.id }) {
            if !seenPhotoIDs.contains(photo.id) {
                seenPhotoIDs.insert(photo.id)
                uniquePhotos.append(photo)
            }
        }
        
        let initialFilledCount = project.filledCount
        let totalCount = project.totalTilesCount
        let emptyTiles = project.tiles.filter { !$0.isFilled && !$0.isLocked }.sorted {
            if $0.gridY != $1.gridY { return $0.gridY < $1.gridY }
            if $0.gridX != $1.gridX { return $0.gridX < $1.gridX }
            return $0.id.uuidString < $1.id.uuidString
        }
        
        let usedPhotoIDs = Set(project.tiles.compactMap(\.placedPhotoIdentifier))
        let usablePhotos = allowDuplicates ? uniquePhotos : uniquePhotos.filter { !usedPhotoIDs.contains($0.id) }
        
        guard !emptyTiles.isEmpty && !usablePhotos.isEmpty else {
            return AutoFillLevel.allCases.map { level in
                let plan = AutoFillPlan(
                    projectId: project.id,
                    projectUpdatedAt: project.updatedAt,
                    allowDuplicates: allowDuplicates,
                    level: level,
                    assignments: [],
                    newFilledCount: initialFilledCount,
                    totalTilesCount: totalCount,
                    projectedProgress: project.progress
                )
                return AutoFillSimulation(
                    level: level,
                    title: level.shortTitle,
                    detail: level.detailDescription,
                    additionalCount: 0,
                    newFilledCount: initialFilledCount,
                    totalTilesCount: totalCount,
                    projectedProgress: project.progress,
                    isFullCompletion: initialFilledCount >= totalCount && totalCount > 0,
                    statusMessage: "配置可能な写真がありません",
                    isExecutable: false,
                    plan: plan
                )
            }
        }
        
        // 2. 候補抽出 ＆ スコア計算を 1 回だけ行い全レベルで共有
        // 2. 候補抽出 ＆ スコア計算を並列・高速に 1 回だけ行い全レベルで共有
        let photoIndexMap = Dictionary(uniqueKeysWithValues: usablePhotos.enumerated().map { ($1.id, $0) })
        let photoIndex = MultiDimensionalPhotoIndex(photos: usablePhotos)
        
        let emptyTilesCount = emptyTiles.count
        var tileCandidates: [[(photoIdx: Int, score: Float)]] = Array(repeating: [], count: emptyTilesCount)
        var globalScoreCache: [Int: [Int: Float]] = [:]
        
        // チャンク並列化で CPU 全コアを活用
        let chunkSize = max(1, emptyTilesCount / 8)
        let chunks = stride(from: 0, to: emptyTilesCount, by: chunkSize).map {
            Array($0..<min($0 + chunkSize, emptyTilesCount))
        }
        
        let calculatedChunks: [[(Int, [(photoIdx: Int, score: Float)])]] = await withTaskGroup(
            of: [(Int, [(photoIdx: Int, score: Float)])].self,
            returning: [[(Int, [(photoIdx: Int, score: Float)])]].self
        ) { group in
            for chunkIndices in chunks {
                group.addTask {
                    var localResults: [(Int, [(photoIdx: Int, score: Float)])] = []
                    localResults.reserveCapacity(chunkIndices.count)
                    
                    for tIdx in chunkIndices {
                        let tile = emptyTiles[tIdx]
                        let candidates = photoIndex.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 48)
                        var validEdges: [(photoIdx: Int, score: Float)] = []
                        validEdges.reserveCapacity(candidates.count)
                        
                        for photo in candidates {
                            let score = self.matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                            if score.isFinite && !score.isNaN, let pIdx = photoIndexMap[photo.id] {
                                validEdges.append((photoIdx: pIdx, score: score))
                            }
                        }
                        validEdges.sort {
                            if $0.score != $1.score { return $0.score < $1.score }
                            return usablePhotos[$0.photoIdx].id < usablePhotos[$1.photoIdx].id
                        }
                        localResults.append((tIdx, Array(validEdges.prefix(32))))
                    }
                    return localResults
                }
            }
            
            var allChunks: [[(Int, [(photoIdx: Int, score: Float)])]] = []
            for await chunkResult in group {
                allChunks.append(chunkResult)
            }
            return allChunks
        }
        
        var globalAllEdges: [(tIdx: Int, photoIdx: Int, score: Float)] = []
        for chunk in calculatedChunks {
            for (tIdx, topEdges) in chunk {
                tileCandidates[tIdx] = topEdges
                globalScoreCache[tIdx] = Dictionary(uniqueKeysWithValues: topEdges.map { ($0.photoIdx, $0.score) })
                for edge in topEdges {
                    globalAllEdges.append((tIdx: tIdx, photoIdx: edge.photoIdx, score: edge.score))
                }
            }
        }
        
        // 全エッジをスコア昇順（最も似ている順）で 1 回だけ事前ソート
        globalAllEdges.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.tIdx != $1.tIdx { return $0.tIdx < $1.tIdx }
            return usablePhotos[$0.photoIdx].id < usablePhotos[$1.photoIdx].id
        }
        
        var simulations: [AutoFillSimulation] = []
        simulations.reserveCapacity(AutoFillLevel.allCases.count)
        
        for level in AutoFillLevel.allCases {
            if Task.isCancelled { return [] }
            let threshold = level.threshold(baseThreshold: baseThreshold)
            
            let plan: AutoFillPlan
            if allowDuplicates {
                var assignments: [AutoFillAssignment] = []
                assignments.reserveCapacity(emptyTiles.count)
                for (tIdx, tile) in emptyTiles.enumerated() {
                    let filtered = tileCandidates[tIdx].filter { $0.score <= threshold }
                    if let best = filtered.first {
                        assignments.append(AutoFillAssignment(tileID: tile.id, photo: usablePhotos[best.photoIdx], score: best.score))
                    } else if level == .completeMax, let fallback = tileCandidates[tIdx].first {
                        assignments.append(AutoFillAssignment(tileID: tile.id, photo: usablePhotos[fallback.photoIdx], score: fallback.score))
                    }
                }
                let newTotal = initialFilledCount + assignments.count
                let projected = totalCount > 0 ? Float(newTotal) / Float(totalCount) : 1.0
                plan = AutoFillPlan(
                    projectId: project.id,
                    projectUpdatedAt: project.updatedAt,
                    allowDuplicates: allowDuplicates,
                    level: level,
                    assignments: assignments,
                    newFilledCount: newTotal,
                    totalTilesCount: totalCount,
                    projectedProgress: projected
                )
            } else {
                // 重複なし Greedy 優先 ＋ Kuhn 増大路マッチング
                var adjList: [[(photoIdx: Int, score: Float)]] = Array(repeating: [], count: emptyTiles.count)
                
                for (tIdx, edges) in tileCandidates.enumerated() {
                    let valid = edges.filter { $0.score <= threshold }
                    if valid.isEmpty && level == .completeMax {
                        adjList[tIdx] = edges
                    } else {
                        adjList[tIdx] = valid
                    }
                }
                
                var matchPtoT = Array<Int?>(repeating: nil, count: usablePhotos.count)
                var matchTtoP = Array<Int?>(repeating: nil, count: emptyTiles.count)
                
                // 1. Greedy 最優先割り当て（事前にソートされたエッジからスコア閾値内のものを即座に確定）
                for edge in globalAllEdges {
                    if level != .completeMax && edge.score > threshold {
                        break // ソート済みのためこれ以降はすべて閾値超過
                    }
                    if matchTtoP[edge.tIdx] == nil && matchPtoT[edge.photoIdx] == nil {
                        matchTtoP[edge.tIdx] = edge.photoIdx
                        matchPtoT[edge.photoIdx] = edge.tIdx
                    }
                }
                
                // 2. Kuhn 増大路探索（未割り当てマスを追加最大化）
                var visitedToken = Array(repeating: 0, count: usablePhotos.count)
                var currentToken = 0
                
                func dfs(tIdx: Int, token: Int) -> Bool {
                    for edge in adjList[tIdx] {
                        let pIdx = edge.photoIdx
                        if visitedToken[pIdx] == token { continue }
                        visitedToken[pIdx] = token
                        
                        if let currentOwner = matchPtoT[pIdx] {
                            if dfs(tIdx: currentOwner, token: token) {
                                matchPtoT[pIdx] = tIdx
                                matchTtoP[tIdx] = pIdx
                                return true
                            }
                        } else {
                            matchPtoT[pIdx] = tIdx
                            matchTtoP[tIdx] = pIdx
                            return true
                        }
                    }
                    return false
                }
                
                let unassignedIndices = (0..<emptyTiles.count).filter { matchTtoP[$0] == nil }
                for tIdx in unassignedIndices {
                    currentToken += 1
                    _ = dfs(tIdx: tIdx, token: currentToken)
                }
                
                var matching: [Int: Int] = [:]
                for (tIdx, maybePIdx) in matchTtoP.enumerated() {
                    if let pIdx = maybePIdx {
                        matching[tIdx] = pIdx
                    }
                }
                
                // .completeMax 高速補完
                if level == .completeMax && matching.count < min(emptyTiles.count, usablePhotos.count) {
                    var assignedPhotos = Set(matching.values)
                    let unassigned = (0..<emptyTiles.count).filter { matching[$0] == nil }
                    var remainingPool = (0..<usablePhotos.count).filter { !assignedPhotos.contains($0) }
                    
                    for tIdx in unassigned {
                        if remainingPool.isEmpty { break }
                        let tile = emptyTiles[tIdx]
                        
                        // 高速なクイックスコアで残存プールから最良を選択
                        var bestPoolIdx = 0
                        var bestScore: Float = Float.infinity
                        for (idx, pIdx) in remainingPool.enumerated() {
                            let p = usablePhotos[pIdx]
                            let s = max(0.0, min(1.0, tile.targetLabColor.distance(to: p.labColor) / 40.0))
                            if s < bestScore {
                                bestScore = s
                                bestPoolIdx = idx
                            }
                        }
                        
                        let chosenPIdx = remainingPool.remove(at: bestPoolIdx)
                        matching[tIdx] = chosenPIdx
                        assignedPhotos.insert(chosenPIdx)
                        if globalScoreCache[tIdx] == nil { globalScoreCache[tIdx] = [:] }
                        globalScoreCache[tIdx]?[chosenPIdx] = bestScore
                    }
                }
                
                // 高速局所 2-opt
                if matching.count > 1 {
                    matching = optimizeAutoFill2Opt(
                        matching: matching,
                        tiles: emptyTiles,
                        photos: usablePhotos,
                        scoreCache: &globalScoreCache,
                        adjList: adjList
                    )
                }
                
                var assignments: [AutoFillAssignment] = []
                assignments.reserveCapacity(matching.count)
                for tIdx in 0..<emptyTiles.count {
                    if let pIdx = matching[tIdx] {
                        let tile = emptyTiles[tIdx]
                        let photo = usablePhotos[pIdx]
                        let score = globalScoreCache[tIdx]?[pIdx] ?? matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: photo)
                        assignments.append(AutoFillAssignment(tileID: tile.id, photo: photo, score: score))
                    }
                }
                
                let newTotal = initialFilledCount + assignments.count
                let projected = totalCount > 0 ? Float(newTotal) / Float(totalCount) : 1.0
                plan = AutoFillPlan(
                    projectId: project.id,
                    projectUpdatedAt: project.updatedAt,
                    allowDuplicates: allowDuplicates,
                    level: level,
                    assignments: assignments,
                    newFilledCount: newTotal,
                    totalTilesCount: totalCount,
                    projectedProgress: projected
                )
            }
            
            let additional = plan.assignments.count
            let newTotal = plan.newFilledCount
            let total = plan.totalTilesCount
            let progress = plan.projectedProgress
            let isFull = (newTotal >= total && total > 0)
            
            let title: String
            let statusMessage: String
            let isExecutable = additional > 0
            
            if level == .completeMax {
                if allowDuplicates && !usablePhotos.isEmpty {
                    title = "100% 完全完成"
                    statusMessage = isExecutable ? "残り \(additional) マスすべてを配置して完成させます" : "すでにすべてのマスが埋まっています"
                } else if !allowDuplicates && usablePhotos.count < emptyTiles.count {
                    title = "可能な限り埋める"
                    statusMessage = isExecutable ? "写真上限まで最大 \(additional) マス配置します (進捗 \(Int(progress * 100))%)" : "利用可能な写真がありません"
                } else {
                    title = "100% 完全完成"
                    statusMessage = isExecutable ? "残り \(additional) マスすべてを配置して完成させます" : "すでにすべてのマスが埋まっています"
                }
            } else {
                title = level.shortTitle
                statusMessage = isExecutable ? "あと \(additional) マス埋まります (進捗 \(Int(progress * 100))%)" : "この許容度では追加配置できる写真がありません"
            }
            
            simulations.append(AutoFillSimulation(
                level: level,
                title: title,
                detail: level.detailDescription,
                additionalCount: additional,
                newFilledCount: newTotal,
                totalTilesCount: total,
                projectedProgress: progress,
                isFullCompletion: isFull,
                statusMessage: statusMessage,
                isExecutable: isExecutable,
                plan: plan
            ))
        }
        
        return simulations
    }
    
    /// 自動配置（.autoFilled かつ未ロック）されたタイルのみを一括リセット
    public func resetAutoFilledTiles(project: MosaicProject) -> (updatedProject: MosaicProject, resetCount: Int) {
        var updatedTiles = project.tiles
        var resetCount = 0
        
        for i in updatedTiles.indices {
            if updatedTiles[i].origin == .autoFilled && !updatedTiles[i].isLocked {
                updatedTiles[i].placedPhotoIdentifier = nil
                updatedTiles[i].placedLabColor = nil
                updatedTiles[i].placedSignature = nil
                updatedTiles[i].thumbnailData = nil
                updatedTiles[i].placementSequence = nil
                updatedTiles[i].isLocked = false
                updatedTiles[i].origin = .automatic
                resetCount += 1
            }
        }
        
        let newMissions = generateMissions(from: updatedTiles)
        let isNowCompleted = updatedTiles.allSatisfy { $0.isFilled }
        
        var newProject = project
        newProject.tiles = updatedTiles
        newProject.missions = newMissions
        newProject.isCompleted = isNowCompleted
        newProject.updatedAt = Date()
        
        return (newProject, resetCount)
    }
}
