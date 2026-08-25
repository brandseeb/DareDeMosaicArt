import Foundation

/// 8x10の配置可能グリッド＋マドンナエリア(row 10)を表す構造体
public struct GridPosition: Hashable, Codable, Sendable {
    public let col: Int // 0...7 (横8列)
    public let row: Int // 0...10 (縦10行の配置マス + 1行のマドンナエリア)
    
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
    
    /// 上下左右の隣接座標を取得
    public func neighbors() -> [GridPosition] {
        let deltas = [
            (0, -1), // 上
            (0, 1),  // 下
            (-1, 0), // 左
            (1, 0)   // 右
        ]
        
        return deltas.compactMap { dCol, dRow in
            let nCol = self.col + dCol
            let nRow = self.row + dRow
            if nCol >= 0 && nCol < 8 && nRow >= 0 && nRow <= 10 {
                return GridPosition(col: nCol, row: nRow)
            }
            return nil
        }
    }
    
    public func manhattanDistance(to other: GridPosition) -> Int {
        return abs(self.col - other.col) + abs(self.row - other.row)
    }
}
