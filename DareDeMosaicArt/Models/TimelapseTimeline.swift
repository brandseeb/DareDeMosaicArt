import Foundation

/// タイムラプス動画のフレーム構成・時間配分・時系列順序計算モデル
public struct TimelapseTimeline: Sendable {
    public static let fps: Int32 = 30
    public static let openingFrames: Int = 30    // 1.0秒
    public static let buildFrames: Int = 210     // 7.0秒
    public static let finaleFrames: Int = 60     // 2.0秒
    public static let totalFrames: Int = 300     // 10.0秒
    
    public let totalTilesCount: Int
    
    public init(totalTilesCount: Int) {
        self.totalTilesCount = max(1, totalTilesCount)
    }
    
    /// プロジェクトのタイルを時系列順に整列（未採番の旧データは決定論的にフォールバック）
    public static func sortTilesInSequence(_ tiles: [MosaicTile]) -> [MosaicTile] {
        let filledTiles = tiles.filter(\.isFilled)
        return filledTiles.sorted { a, b in
            if let seqA = a.placementSequence, let seqB = b.placementSequence {
                return seqA < seqB
            }
            if a.placementSequence != nil && b.placementSequence == nil {
                return true
            }
            if a.placementSequence == nil && b.placementSequence != nil {
                return false
            }
            // フォールバック: origin -> gridY -> gridX
            let originRankA = originRank(a.origin)
            let originRankB = originRank(b.origin)
            if originRankA != originRankB {
                return originRankA < originRankB
            }
            if a.gridY != b.gridY {
                return a.gridY < b.gridY
            }
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
    
    /// ビルドフェーズのフレーム f (0..<210) で追加すべきタイルのインデックス範囲 [start, end)
    public func newTileRange(forBuildFrame frameIndex: Int) -> Range<Int> {
        guard frameIndex >= 0 && frameIndex < Self.buildFrames else {
            return 0..<0
        }
        let prevTarget = targetCumulativeCount(forFrame: frameIndex - 1)
        let currTarget = targetCumulativeCount(forFrame: frameIndex)
        return prevTarget..<currTarget
    }
    
    /// ビルドフェーズのフレーム f (-1..<210) における累計表示目標タイル数
    public func targetCumulativeCount(forFrame frameIndex: Int) -> Int {
        if frameIndex < 0 { return 0 }
        if frameIndex >= Self.buildFrames - 1 { return totalTilesCount }
        let count = Int(floor(Double(frameIndex + 1) / Double(Self.buildFrames) * Double(totalTilesCount)))
        return min(max(0, count), totalTilesCount)
    }
    
    /// 全ビルドフレーム (0..<210) を通して、各タイルがちょうど 1 回だけ追加されるかを検証
    public func validateFullCoverage() -> Bool {
        var covered = 0
        for f in 0..<Self.buildFrames {
            let range = newTileRange(forBuildFrame: f)
            if !range.isEmpty {
                if range.lowerBound != covered { return false }
                covered = range.upperBound
            }
        }
        return covered == totalTilesCount
    }
}
