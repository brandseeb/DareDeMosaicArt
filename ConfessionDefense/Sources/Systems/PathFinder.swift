import Foundation

/// 8x11教室の経路探索（ダイクストラ / BFS）と完全封鎖判定
public final class PathFinder: Sendable {
    public static let shared = PathFinder()
    
    public init() {}
    
    /// スタート地点からゴール地点（マドンナ）までの最短経路を計算（コスト考慮）
    public func findPath(
        from start: GridPosition,
        to target: GridPosition,
        grid: [GridPosition: CellType]
    ) -> [GridPosition]? {
        if start == target { return [start] }
        
        var distances: [GridPosition: Double] = [start: 0.0]
        var previous: [GridPosition: GridPosition] = [:]
        var unvisited = Set<GridPosition>()
        
        // 8x11の全マスを初期化
        for c in 0..<8 {
            for r in 0..<11 {
                let pos = GridPosition(col: c, row: r)
                unvisited.insert(pos)
            }
        }
        
        while !unvisited.isEmpty {
            guard let current = unvisited.min(by: { (distances[$0] ?? .infinity) < (distances[$1] ?? .infinity) }),
                  let currentDist = distances[current],
                  currentDist < .infinity else {
                break
            }
            
            if current == target {
                var path: [GridPosition] = [target]
                var curr = target
                while let prev = previous[curr] {
                    path.insert(prev, at: 0)
                    curr = prev
                }
                return path
            }
            
            unvisited.remove(current)
            
            for neighbor in current.neighbors() {
                guard unvisited.contains(neighbor) else { continue }
                
                let cell = grid[neighbor] ?? .empty
                if neighbor != target && !cell.isWalkable {
                    continue
                }
                
                let cost = cell.movementCost
                let newDist = currentDist + cost
                
                if newDist < (distances[neighbor] ?? .infinity) {
                    distances[neighbor] = newDist
                    previous[neighbor] = current
                }
            }
        }
        
        return nil
    }
    
    /// 左ドア(0,0)と右ドア(7,0)の両方からマドンナへの経路が存在するかチェック
    public func validatePaths(
        leftDoor: GridPosition = GridPosition(col: 0, row: 0),
        rightDoor: GridPosition = GridPosition(col: 7, row: 0),
        madonna: GridPosition,
        grid: [GridPosition: CellType]
    ) -> Bool {
        let leftPath = findPath(from: leftDoor, to: madonna, grid: grid)
        let rightPath = findPath(from: rightDoor, to: madonna, grid: grid)
        return leftPath != nil && rightPath != nil
    }
}
