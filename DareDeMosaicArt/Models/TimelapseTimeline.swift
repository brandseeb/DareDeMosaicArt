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
        public let shadowComplexity: Int // 0: 簡略 (大グリッド), 1: 標準 (中グリッド), 2: 高品質 (小グリッド)
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
                    enableRimFlash: false // 大グリッドはチカチカ防止のためOFF
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
        
        /// 指定されたビルドフレーム（0..<210）における進行度 t (0.0: 上空出現 〜 1.0: 完全着地)
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
        
        /// フレームにおけるアクティブ状態 (0 <= t < 1.0 または 着地フレーム)
        public func isActive(atBuildFrame frame: Int) -> Bool {
            return frame >= startBuildFrame && frame <= (startBuildFrame + durationFrames - 1)
        }
    }
    
    // MARK: - 全タイルのアニメーションスケジュール生成 (startFrame + duration - 1 <= 209 厳密保証)
    public func generateTileSchedules() -> [TileAnimState] {
        var schedules: [TileAnimState] = []
        schedules.reserveCapacity(totalTilesCount)
        
        let dur = config.dropDurationFrames
        // ビルドフェーズは 0..<210 フレーム。最終ピースの着地フレームは 209 (8.0秒直前)。
        // startFrame + dur - 1 <= 209 より、startFrame の最大許容値は 210 - dur
        let maxStartFrame = max(0, 210 - dur)
        
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
    
    // MARK: - 物理イージング（Yオフセット・スケール・S字Xオフセット・回転・影）
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
        if t >= 1.0 {
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
        
        // 1. 高さ (Y Offset): 上空から枠へ急降下
        // easeInQuad 加速落下 (1 - t)^2
        let yDist = config.dropDistancePixels * pow(1.0 - t, 2.0)
        
        // 2. S字軌道 (X Offset): sin(2πt) * (1 - t)
        // 乱数で左右の初期振れ幅を決定 (+ or -)
        let driftDir: CGFloat = (randomSeed % 2 == 0) ? 1.0 : -1.0
        let xDrift = config.sCurveDriftPixels * driftDir * sin(2.0 * .pi * t) * (1.0 - t)
        
        // 3. スケール (Scale): 初期拡大 -> 着地押し込み (0.92) -> リバウンド (1.04) -> 1.0
        let scale: CGFloat
        if t < 0.7 {
            let localT = t / 0.7
            scale = config.maxScale - (config.maxScale - 1.0) * localT
        } else if t < 0.85 {
            // 着地押し込み 1.0 -> 0.92 (大グリッドはマイルドに 0.98)
            let minScale: CGFloat = (totalTilesCount > 1600) ? 0.98 : 0.92
            let localT = (t - 0.7) / 0.15
            scale = 1.0 - (1.0 - minScale) * sin(.pi * localT)
        } else {
            // リバウンド 1.04 -> 1.0
            let maxBounce: CGFloat = (totalTilesCount > 1600) ? 1.01 : 1.04
            let localT = (t - 0.85) / 0.15
            scale = 1.0 + (maxBounce - 1.0) * sin(.pi * localT)
        }
        
        // 4. 回転 (Rotation): 初期傾き -> 0°
        let rotDeg = config.maxRotationDegrees * driftDir * pow(1.0 - t, 1.5)
        let rotRad = rotDeg * .pi / 180.0
        
        // 5. 影 (Shadow): 上空は薄く・広く・下方に大きく落ちる -> 着地直前は濃く小さく
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
    
    // MARK: - 制作時系列マクロ分割 ＆ 制御された3幕構成ソート
    public static func sortTilesInMacroDynamicSequence(
        tiles: [MosaicTile],
        projectID: UUID,
        gridWidth: Int,
        gridHeight: Int
    ) -> [MosaicTile] {
        guard !tiles.isEmpty else { return [] }
        
        // 1. まず基本的な時系列（placementSequence / origin / 座標）で安定ソート
        let baseSorted = sortTilesInSequence(tiles)
        let total = baseSorted.count
        
        // 2. 8〜12個のマクロブロックに分割（制作時系列の文脈を維持）
        let macroBlockCount = max(4, min(12, total / 20))
        let blockSize = Int(ceil(Double(total) / Double(macroBlockCount)))
        
        var rng = DeterministicPRNG(seed: projectID)
        var resultTiles: [MosaicTile] = []
        resultTiles.reserveCapacity(total)
        
        for blockIdx in 0..<macroBlockCount {
            let start = blockIdx * blockSize
            guard start < total else { break }
            let end = min(start + blockSize, total)
            let chunk = Array(baseSorted[start..<end])
            
            // 各マクロブロック内で「制御されたランダム（近接回避・分散）」を適用
            let sortedChunk = orderChunkWithSpatialDispersion(
                chunk: chunk,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                rng: &rng
            )
            resultTiles.append(contentsOf: sortedChunk)
        }
        
        return resultTiles
    }
    
    /// チャンク内のタイルを空間的に分散させて隣接連続を防止する
    private static func orderChunkWithSpatialDispersion(
        chunk: [MosaicTile],
        gridWidth: Int,
        gridHeight: Int,
        rng: inout DeterministicPRNG
    ) -> [MosaicTile] {
        guard chunk.count > 2 else { return chunk }
        
        var pool = chunk
        var ordered: [MosaicTile] = []
        ordered.reserveCapacity(chunk.count)
        
        // 最初の1枚をランダム選択
        let firstIdx = rng.nextInt(upperBound: pool.count)
        ordered.append(pool.remove(at: firstIdx))
        
        while !pool.isEmpty {
            let last = ordered.last!
            // 直前のタイルから最も遠い上位候補（複数）の中からランダムに選択（近接回避）
            var candidatesWithDist: [(index: Int, dist: Float)] = []
            for (idx, tile) in pool.enumerated() {
                let dx = Float(tile.gridX - last.gridX)
                let dy = Float(tile.gridY - last.gridY)
                let dist = sqrt(dx * dx + dy * dy)
                candidatesWithDist.append((index: idx, dist: dist))
            }
            
            // 距離が大きい順にソート
            candidatesWithDist.sort { $0.dist > $1.dist }
            let topCandidateCount = max(1, min(4, candidatesWithDist.count))
            let pickChoice = rng.nextInt(upperBound: topCandidateCount)
            let pickedOriginalIdx = candidatesWithDist[pickChoice].index
            
            ordered.append(pool.remove(at: pickedOriginalIdx))
        }
        
        return ordered
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
        case .captured: return 1
        case .manuallySelected: return 2
        }
    }
}

/// プロジェクトUUIDに基づく決定論的疑似乱数生成器 (LCG / PCG 互換)
public struct DeterministicPRNG {
    private var state: UInt64
    
    public init(seed: UUID) {
        // UUID の 16 バイトから 64bit シードを合成
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
        // 64-bit LCG
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    
    public mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
