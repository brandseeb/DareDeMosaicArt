import Foundation

public enum EnemyType: String, Codable, Sendable {
    case normal = "普通の告白者"
    case athletic = "運動部員"
    case shy = "恥ずかしがり屋"
    case fanclub = "ファンクラブ集団"
    case senpai = "上級生"
    case bossSoccer = "サッカー部主将"
}

public struct Enemy: Identifiable, Sendable {
    public let id: UUID
    public let type: EnemyType
    public let name: String
    public let emoji: String
    public let maxPassion: Double     // 告白意欲（HP）
    public var currentPassion: Double
    public let baseSpeed: Double      // 移動速度（マス/秒）
    public var currentSpeed: Double
    public let stressDamage: Int      // マドンナ到達時のストレス増加量
    public var gridPosition: GridPosition
    public var exactX: Double         // グリッド基準の実座標X
    public var exactY: Double         // グリッド基準の実座標Y
    public var path: [GridPosition]   // 残り移動ルート
    public var isDefeated: Bool
    public let dropFriendshipPoints: Int
    
    public init(
        id: UUID = UUID(),
        type: EnemyType,
        startDoor: GridPosition,
        path: [GridPosition] = []
    ) {
        self.id = id
        self.type = type
        self.gridPosition = startDoor
        self.exactX = Double(startDoor.col)
        self.exactY = Double(startDoor.row)
        self.path = path
        self.isDefeated = false
        
        switch type {
        case .normal:
            self.name = "普通の男子生徒"
            self.emoji = "🏃‍♂️"
            self.maxPassion = 30
            self.baseSpeed = 1.2
            self.stressDamage = 1
            self.dropFriendshipPoints = 10
        case .athletic:
            self.name = "俊足の陸上部員"
            self.emoji = "🏃💨"
            self.maxPassion = 45
            self.baseSpeed = 2.0
            self.stressDamage = 1
            self.dropFriendshipPoints = 15
        case .shy:
            self.name = "遠距離ラブレター係"
            self.emoji = "💌"
            self.maxPassion = 25
            self.baseSpeed = 1.0
            self.stressDamage = 1
            self.dropFriendshipPoints = 12
        case .fanclub:
            self.name = "親衛隊メンバー"
            self.emoji = "👥"
            self.maxPassion = 20
            self.baseSpeed = 1.1
            self.stressDamage = 1
            self.dropFriendshipPoints = 8
        case .senpai:
            self.name = "強気な上級生"
            self.emoji = "👔"
            self.maxPassion = 80
            self.baseSpeed = 0.9
            self.stressDamage = 2
            self.dropFriendshipPoints = 25
        case .bossSoccer:
            self.name = "サッカー部キャプテン"
            self.emoji = "⚽"
            self.maxPassion = 350
            self.baseSpeed = 1.0
            self.stressDamage = 3
            self.dropFriendshipPoints = 100
        }
        
        self.currentPassion = self.maxPassion
        self.currentSpeed = self.baseSpeed
    }
}
