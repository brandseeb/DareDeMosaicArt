import Foundation

/// 教室の各マスの種類
public enum CellType: Equatable, Codable, Sendable {
    case empty              // 何もない床
    case desk               // 机（完全障害物）
    case chair              // 椅子（通過可能・移動速度35%低下）
    case classmate(id: String) // クラスメイト配置マス
    case madonna            // マドンナのいるマス（防衛目標）
    case doorLeft           // 左上入口 (0, 0)
    case doorRight          // 右上入口 (7, 0)
    
    /// 敵が進入可能かどうか（机やクラスメイトは通行不可）
    public var isWalkable: Bool {
        switch self {
        case .empty, .chair, .madonna, .doorLeft, .doorRight:
            return true
        case .desk, .classmate:
            return false
        }
    }
    
    /// 移動コスト（椅子は減速がかかるためコスト高）
    public var movementCost: Double {
        switch self {
        case .chair:
            return 1.6 // 減速（コスト増）
        default:
            return 1.0
        }
    }
}
