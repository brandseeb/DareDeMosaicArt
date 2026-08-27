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
        let candidates = index.candidates(for: tile.targetLabColor, signature: tile.targetSignature, maxCandidates: 100)
        
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
        passDistanceThreshold: Float = 0.38
    ) -> (updatedProject: MosaicProject, matchedTile: MosaicTile?, message: String) {
        var updatedProject = project
        let nextSeq = (updatedProject.tiles.compactMap(\.placementSequence).max() ?? -1) + 1
        
        // 1. ユーザーが特定マスを選択して撮り直した場合はそのマスに最優先で当てはめる
        if let targetID = preferredTileID,
           let index = updatedProject.tiles.firstIndex(where: { $0.id == targetID }) {
            let tile = updatedProject.tiles[index]
            let score = matchScore(targetColor: tile.targetLabColor, targetSignature: tile.targetSignature, photo: IndexedPhoto(id: "camera", labColor: photoLabColor, signature: photoSignature))
            
            if score <= passDistanceThreshold * 1.35 {
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
    
    public func candidates(for targetColor: LabColor, signature: SpatialColorSignature?, maxCandidates: Int = 200) -> [IndexedPhoto] {
        var candidateIndices = Set<Int>()
        
        // 1. Lab 近傍バケット探索 (±1)
        var labCandidateIndices = Set<Int>()
        var comCandidateIndices = Set<Int>()
        var gradCandidateIndices = Set<Int>()
        
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
        
        // フォールバック（候補が少なすぎる場合は全体から補充）
        let allUniqueCount = labCandidateIndices.union(comCandidateIndices).union(gradCandidateIndices).count
        if allUniqueCount < min(30, allPhotos.count) {
            for i in 0..<allPhotos.count {
                labCandidateIndices.insert(i)
                if labCandidateIndices.count >= maxCandidates { break }
            }
        }
        
        // 予約枠の割り振りと各ソースごとの上位抽出（Lab 40%, CoM 30%, 勾配 30%）
        let labQuota = Int(Float(maxCandidates) * 0.40)  // 例: 80枚
        let comQuota = Int(Float(maxCandidates) * 0.30)  // 例: 60枚
        let gradQuota = Int(Float(maxCandidates) * 0.30) // 例: 60枚
        
        let topLab = Array(labCandidateIndices.map { (idx: $0, dist: targetColor.distance(to: allPhotos[$0].labColor)) }
            .sorted { $0.dist < $1.dist }
            .prefix(labQuota)
            .map(\.idx))
            
        let topCom = Array(comCandidateIndices.map { idx -> (idx: Int, dist: Float) in
            guard let tSig = signature, let pSig = allPhotos[idx].signature else {
                return (idx, targetColor.distance(to: allPhotos[idx].labColor))
            }
            let dx = tSig.darkCenterOfMassX - pSig.darkCenterOfMassX
            let dy = tSig.darkCenterOfMassY - pSig.darkCenterOfMassY
            let dCoM = sqrt(dx * dx + dy * dy)
            return (idx, dCoM + abs(tSig.darkRatio - pSig.darkRatio))
        }.sorted { $0.dist < $1.dist }
        .prefix(comQuota)
        .map(\.idx))
        
        let topGrad = Array(gradCandidateIndices.map { idx -> (idx: Int, dist: Float) in
            guard let tSig = signature, let pSig = allPhotos[idx].signature else {
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
        
        // もし 200 枚に達していなければ、全プールから簡易複合スコア順で補充
        if finalCandidateIndices.count < maxCandidates {
            let remainingPool = labCandidateIndices.union(comCandidateIndices).union(gradCandidateIndices)
                .subtracting(finalCandidateIndices)
            let sortedRemaining = remainingPool.map { idx -> (idx: Int, score: Float) in
                (idx, quickCoarseScore(targetColor: targetColor, targetSig: signature, photo: allPhotos[idx]))
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
