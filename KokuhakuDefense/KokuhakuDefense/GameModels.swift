import CoreGraphics
import Foundation

struct GridPoint: Hashable {
    let column: Int
    let row: Int

    func neighbors(columns: Int, rows: Int) -> [GridPoint] {
        [
            GridPoint(column: column + 1, row: row),
            GridPoint(column: column - 1, row: row),
            GridPoint(column: column, row: row + 1),
            GridPoint(column: column, row: row - 1)
        ].filter { point in
            point.column >= 0 && point.column < columns && point.row >= 0 && point.row < rows
        }
    }
}

enum GamePhase {
    case building
    case fighting
    case victory
    case defeated
}

struct DefenderProfile {
    let name: String
    let role: String
    let symbol: String
    let range: CGFloat
    let damage: CGFloat
    let attackInterval: TimeInterval
    let projectileColor: CGColor
}

enum Pathfinder {
    static func shortestPath(
        from start: GridPoint,
        toAny goals: Set<GridPoint>,
        blocked: Set<GridPoint>,
        columns: Int,
        rows: Int
    ) -> [GridPoint]? {
        let availableGoals = goals.subtracting(blocked)
        guard !blocked.contains(start), !availableGoals.isEmpty else { return nil }

        var queue: [GridPoint] = [start]
        var head = 0
        var visited: Set<GridPoint> = [start]
        var cameFrom: [GridPoint: GridPoint] = [:]

        while head < queue.count {
            let current = queue[head]
            head += 1

            if availableGoals.contains(current) {
                var path = [current]
                var cursor = current
                while let previous = cameFrom[cursor] {
                    path.append(previous)
                    cursor = previous
                }
                return path.reversed()
            }

            for next in current.neighbors(columns: columns, rows: rows) {
                guard !blocked.contains(next), !visited.contains(next) else { continue }
                visited.insert(next)
                cameFrom[next] = current
                queue.append(next)
            }
        }
        return nil
    }
}
