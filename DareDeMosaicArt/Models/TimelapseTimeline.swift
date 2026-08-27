import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

/// タイムラプス動画のタイムライン・物理パラメータ・配置シーケンス計算モデル
public struct TimelapseTimeline: Sendable {
    public static let fps: Int = 30
    public static let totalDurationSeconds: Double = 10.0
    public static let totalFrames: Int = 300 // 30fps * 10.0s
    
    public static let openingFrames: Int = 30 // 0.0s 〜 1.0s (30F)
    public static let buildFrames: Int = 210   // 1.0s 〜 8.0s (210F: 30〜239F)
    public static let finaleFrames: Int = 60  // 8.0s 〜 10.0s (60F: 240〜299F)
    
    public let totalTilesCount: Int
    public let gridWidth: Int
    public let gridHeight: Int
    public let config: AdaptiveAnimationConfig
    
    // MARK: - グリッド規模別 適応型物理演出設定
    public struct AdaptiveAnimationConfig: Sendable, Equatable {
        public let dropDurationFrames: Int
        public let dropDistancePixels: CGFloat
        public let maxRotationDegrees: CGFloat
        public let maxScale: CGFloat
        public let sCurveDriftPixels: CGFloat
        public let shadowComplexity: Int
        public let enableRimFlash: Bool
        
        public static func forTileCount(_ count: Int) -> AdaptiveAnimationConfig {
            if count <= 400 {
                // 小グリッド (10〜20マス): じっくり見せるリッチな物理演出
                return AdaptiveAnimationConfig(
                    dropDurationFrames: 13,
                    dropDistancePixels: 140,
                    maxRotationDegrees: 8.0,
                    maxScale: 1.30,
                    sCurveDriftPixels: 24.0,
                    shadowComplexity: 2,
                    enableRimFlash: true
                )
            } else if count <= 1600 {
                // 中グリッド (25〜40マス): 軽快でリズミカルな演出
                return AdaptiveAnimationConfig(
                    dropDurationFrames: 10,
                    dropDistancePixels: 70,
                    maxRotationDegrees: 4.0,
                    maxScale: 1.15,
                    sCurveDriftPixels: 12.0,
                    shadowComplexity: 1,
                    enableRimFlash: true
                )
            } else {
                // 大グリッド (50〜60マス / 3600マス): 負荷を抑えた上品な波・クラスター演出
                return AdaptiveAnimationConfig(
                    dropDurationFrames: 7,
                    dropDistancePixels: 35,
                    maxRotationDegrees: 1.5,
                    maxScale: 1.06,
                    sCurveDriftPixels: 4.0,
                    shadowComplexity: 0,
                    enableRimFlash: false
                )
            }
        }
    }
    
    public init(totalTilesCount: Int, gridWidth: Int = 0, gridHeight: Int = 0) {
        self.totalTilesCount = max(1, totalTilesCount)
        self.gridWidth = max(1, gridWidth)
        self.gridHeight = max(1, gridHeight)
        self.config = AdaptiveAnimationConfig.forTileCount(totalTilesCount)
    }
    
    // MARK: - ピースごとのアニメーション状態
    public struct TileAnimState: Sendable {
        public let tileIndex: Int
        public let startBuildFrame: Int // 0..<210
        public let durationFrames: Int
        
        /// 指定されたビルドフレームにおける進行度 t (0.0: 上空出現 〜 1.0: 完全着地)
        public func progress(atBuildFrame frame: Int) -> CGFloat {
            if frame < startBuildFrame { return 0.0 }
            if frame >= startBuildFrame + durationFrames - 1 { return 1.0 }
            let elapsed = CGFloat(frame - startBuildFrame)
            let dur = CGFloat(max(1, durationFrames - 1))
            return max(0.0, min(1.0, elapsed / dur))
        }
        
        /// 着地した瞬間（直前1フレーム）かどうか
        public func isLandingFrame(atBuildFrame frame: Int) -> Bool {
            return frame == (startBuildFrame + durationFrames - 1)
        }
        
        /// フレームにおけるアクティブ状態 (出現中〜着地フレームまで)
        public func isActive(atBuildFrame frame: Int) -> Bool {
            return frame >= startBuildFrame && frame <= (startBuildFrame + durationFrames - 1)
        }
        
        /// 完全定着済み（次のフレーム以降でベースレイヤーへ焼き込み可能）
        public func isFullyLandedAndSettled(atBuildFrame frame: Int) -> Bool {
            return frame > (startBuildFrame + durationFrames - 1)
        }
    }
    
    // MARK: - 全タイルのアニメーションスケジュール生成
    public func generateTileSchedules() -> [TileAnimState] {
        var schedules: [TileAnimState] = []
        schedules.reserveCapacity(totalTilesCount)
        
        let dur = config.dropDurationFrames
        // 最後のピースは208Fまでに着地させ、209Fで固定レイヤーへ焼き込む。
        // 着地を209Fにすると、次のフィナーレに最後の1枚が反映されない。
        let lastLandingFrame = Self.buildFrames - 2
        let maxStartFrame = max(0, lastLandingFrame - dur + 1)
        
        for i in 0..<totalTilesCount {
            let ratio = Double(i) / Double(max(1, totalTilesCount - 1))
            let startFrame = min(maxStartFrame, Int(ratio * Double(maxStartFrame)))
            schedules.append(TileAnimState(
                tileIndex: i,
                startBuildFrame: startFrame,
                durationFrames: dur
            ))
        }
        
        return schedules
    }
    
    // MARK: - 物理イージング（Yオフセット・スケール・真のS字Xオフセット・回転・影）
    public struct TileTransform: Sendable {
        public let xOffset: CGFloat
        public let yOffset: CGFloat
        public let scale: CGFloat
        public let rotationRadians: CGFloat
        public let shadowAlpha: CGFloat
        public let shadowBlur: CGFloat
        public let shadowYOffset: CGFloat
        public let isLanding: Bool
    }
    
    public func evaluateTransform(progress t: CGFloat, randomSeed: UInt64, isLanding: Bool) -> TileTransform {
        if t >= 1.0 && !isLanding {
            return TileTransform(
                xOffset: 0,
                yOffset: 0,
                scale: 1.0,
                rotationRadians: 0,
                shadowAlpha: 0,
                shadowBlur: 0,
                shadowYOffset: 0,
                isLanding: false
            )
        }
        
        // 1. 高さ (Y Offset): 上空から枠へ急降下 (easeInQuad)
        let yDist = config.dropDistancePixels * pow(1.0 - t, 2.0)
        
        // 2. 真のS字軌道 (X Offset): sin(2πt) * (1 - t)
        let driftDir: CGFloat = (randomSeed % 2 == 0) ? 1.0 : -1.0
        let xDrift = config.sCurveDriftPixels * driftDir * sin(2.0 * .pi * t) * (1.0 - t)
        
        // 3. スケール (Scale): 初期拡大 -> 着地押し込み (0.92) -> リバウンド (1.04) -> 1.0
        let scale: CGFloat
        if t < 0.7 {
            let localT = t / 0.7
            scale = config.maxScale - (config.maxScale - 1.0) * localT
        } else if t < 0.85 {
            let minScale: CGFloat = (totalTilesCount > 1600) ? 0.98 : 0.92
            let localT = (t - 0.7) / 0.15
            scale = 1.0 - (1.0 - minScale) * sin(.pi * localT)
        } else {
            let maxBounce: CGFloat = (totalTilesCount > 1600) ? 1.01 : 1.04
            let localT = (t - 0.85) / 0.15
            scale = 1.0 + (maxBounce - 1.0) * sin(.pi * localT)
        }
        
        // 4. 回転 (Rotation): 初期傾き -> 0°
        let rotDeg = config.maxRotationDegrees * driftDir * pow(1.0 - t, 1.5)
        let rotRad = rotDeg * .pi / 180.0
        
        // 5. 影 (Shadow): 上空は薄く広く -> 着地直前は濃く小さく
        let shadowAlpha = (0.2 + 0.4 * t) * (1.0 - pow(t, 4.0))
        let shadowBlur = (16.0 - 12.0 * t) * (config.dropDistancePixels / 140.0)
        let shadowY = (24.0 - 20.0 * t) * (config.dropDistancePixels / 140.0)
        
        return TileTransform(
            xOffset: xDrift,
            yOffset: yDist,
            scale: scale,
            rotationRadians: rotRad,
            shadowAlpha: max(0, shadowAlpha),
            shadowBlur: max(1, shadowBlur),
            shadowYOffset: max(1, shadowY),
            isLanding: isLanding && config.enableRimFlash
        )
    }
    
    // MARK: - 制作時系列マクロ分割（8〜12ブロック） ＆ 3幕構成（散布 -> スパイラル・波 -> エッジ密度・重要領域）
    public static func sortTilesInMacroDynamicSequence(
        tiles: [MosaicTile],
        projectID: UUID,
        gridWidth: Int,
        gridHeight: Int
    ) -> [MosaicTile] {
        guard !tiles.isEmpty else { return [] }
        
        let baseSorted = sortTilesInSequence(tiles)
        let total = baseSorted.count
        
        // 8〜12個のマクロブロックに厳密分割
        let macroBlockCount = max(8, min(12, max(8, total / 15)))
        let blockSize = Int(ceil(Double(total) / Double(macroBlockCount)))
        
        var rng = DeterministicPRNG(seed: projectID)
        var resultTiles: [MosaicTile] = []
        resultTiles.reserveCapacity(total)
        
        for blockIdx in 0..<macroBlockCount {
            let start = blockIdx * blockSize
            guard start < total else { break }
            let end = min(start + blockSize, total)
            let chunk = Array(baseSorted[start..<end])
            
            // 3幕構成の進行度 (0.0: 序盤 〜 1.0: 終盤)
            let blockProgress = Double(blockIdx) / Double(max(1, macroBlockCount - 1))
            
            let sortedChunk = orderChunkWithThreeActFlow(
                chunk: chunk,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                blockProgress: blockProgress,
                rng: &rng
            )
            resultTiles.append(contentsOf: sortedChunk)
        }
        
        return resultTiles
    }
    
    /// 3幕構成（序盤：均等散布、中盤：スパイラル・波、終盤：エッジ密度・コントラスト重要度領域）
    private static func orderChunkWithThreeActFlow(
        chunk: [MosaicTile],
        gridWidth: Int,
        gridHeight: Int,
        blockProgress: Double,
        rng: inout DeterministicPRNG
    ) -> [MosaicTile] {
        guard chunk.count > 2 else { return chunk }
        
        let centerX = Float(gridWidth - 1) / 2.0
        let centerY = Float(gridHeight - 1) / 2.0
        let maxRadius = max(1.0, sqrt(centerX * centerX + centerY * centerY))
        
        if blockProgress < 0.30 {
            // 第1幕: 序盤 (0〜30%) - 空間均等散布（直前配置から最大距離の候補を選択）
            var pool = chunk
            var ordered: [MosaicTile] = []
            ordered.reserveCapacity(chunk.count)
            let firstIdx = rng.nextInt(upperBound: pool.count)
            ordered.append(pool.remove(at: firstIdx))
            
            while !pool.isEmpty {
                let last = ordered.last!
                var candidates: [(idx: Int, dist: Float)] = []
                for (i, t) in pool.enumerated() {
                    let dx = Float(t.gridX - last.gridX)
                    let dy = Float(t.gridY - last.gridY)
                    candidates.append((i, sqrt(dx * dx + dy * dy)))
                }
                candidates.sort { $0.dist > $1.dist }
                let topCount = max(1, min(3, candidates.count))
                let pick = rng.nextInt(upperBound: topCount)
                ordered.append(pool.remove(at: candidates[pick].idx))
            }
            return ordered
            
        } else if blockProgress < 0.85 {
            // 第2幕: 中盤 (30〜85%) - スパイラル・波状の角度・半径順フロー
            return chunk.sorted { a, b in
                let daX = Float(a.gridX) - centerX
                let daY = Float(a.gridY) - centerY
                let dbX = Float(b.gridX) - centerX
                let dbY = Float(b.gridY) - centerY
                
                let angleA = atan2(daY, daX)
                let angleB = atan2(dbY, dbX)
                let rA = sqrt(daX * daX + daY * daY)
                let rB = sqrt(dbX * dbX + dbY * dbY)
                
                // スパイラル値 (角度 + 半径の重み)
                let spiralA = angleA + (rA / maxRadius) * Float.pi * 2.0
                let spiralB = angleB + (rB / maxRadius) * Float.pi * 2.0
                return spiralA < spiralB
            }
        } else {
            // 第3幕: 終盤 (85〜100%) - エッジ密度・コントラスト重要度領域を最後に着地
            return chunk.sorted { a, b in
                let scoreA = computeTileImportanceScore(a, centerX: centerX, centerY: centerY, maxRadius: maxRadius)
                let scoreB = computeTileImportanceScore(b, centerX: centerX, centerY: centerY, maxRadius: maxRadius)
                return scoreA < scoreB // スコアが低い（周辺・平坦）タイルが先、高重要度（主役・エッジ・高コントラスト）が最後
            }
        }
    }
    
    /// タイルの3×3空間色分散（コントラスト重要度）・中心性・彩度を統合した重要度スコア計算
    private static func computeTileImportanceScore(
        _ tile: MosaicTile,
        centerX: Float,
        centerY: Float,
        maxRadius: Float
    ) -> Float {
        // 1. 中心からの近さ (0.0: 最外郭 〜 1.0: 中心)
        let dx = Float(tile.gridX) - centerX
        let dy = Float(tile.gridY) - centerY
        let dist = sqrt(dx * dx + dy * dy)
        let centrality: Float = 1.0 - min(1.0, dist / maxRadius)
        
        // 2. 3×3セルの空間色分散（Spatial Color Variance: 各セルの平均色からの二乗偏差平均）
        var spatialColorVariance: Float = 0.0
        if let sig = tile.targetSignature, !sig.cells.isEmpty {
            let avgL = Float(sig.average.l)
            let avgA = Float(sig.average.a)
            let avgB = Float(sig.average.b)
            var sumDev: Float = 0.0
            for cell in sig.cells {
                let dL = Float(cell.l) - avgL
                let da = Float(cell.a) - avgA
                let db = Float(cell.b) - avgB
                sumDev += (dL * dL + da * da + db * db)
            }
            let meanDev = sumDev / Float(sig.cells.count)
            spatialColorVariance = min(1.0, sqrt(meanDev) / 30.0)
        }
        
        // 3. 彩度 (Chroma: a^2 + b^2)
        let aVal = Float(tile.targetLabColor.a)
        let bVal = Float(tile.targetLabColor.b)
        let chroma = sqrt(aVal * aVal + bVal * bVal)
        let chromaScore: Float = min(1.0, chroma / 60.0)
        
        // 総合重要度: 3×3空間色分散・コントラスト(40%) + 中心性(35%) + 彩度(25%)
        return spatialColorVariance * 0.40 + centrality * 0.35 + chromaScore * 0.25
    }
    
    // MARK: - 基本時系列ソート（旧作フォールバック）
    public static func sortTilesInSequence(_ tiles: [MosaicTile]) -> [MosaicTile] {
        return tiles.sorted { a, b in
            if let seqA = a.placementSequence, let seqB = b.placementSequence {
                if seqA != seqB { return seqA < seqB }
            } else if a.placementSequence != nil {
                return true
            } else if b.placementSequence != nil {
                return false
            }
            
            let rankA = originRank(a.origin)
            let rankB = originRank(b.origin)
            if rankA != rankB { return rankA < rankB }
            if a.gridY != b.gridY { return a.gridY < b.gridY }
            return a.gridX < b.gridX
        }
    }
    
    private static func originRank(_ origin: PlacementOrigin) -> Int {
        switch origin {
        case .automatic: return 0
        case .autoFilled: return 1
        case .captured: return 2
        case .manuallySelected: return 3
        }
    }
}

/// プロジェクトUUIDに基づく決定論的疑似乱数生成器 (LCG)
public struct DeterministicPRNG {
    private var state: UInt64
    
    public init(seed: UUID) {
        let uuidBytes = seed.uuid
        var s: UInt64 = 0
        withUnsafeBytes(of: uuidBytes) { ptr in
            let u1 = ptr.load(fromByteOffset: 0, as: UInt64.self)
            let u2 = ptr.load(fromByteOffset: 8, as: UInt64.self)
            s = u1 ^ u2
        }
        self.state = (s == 0) ? 0x853c49e6748fea9b : s
    }
    
    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    
    public mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
