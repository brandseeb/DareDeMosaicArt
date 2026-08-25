import Foundation

public struct FriendshipCard: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let iconEmoji: String
    public let category: CardCategory
    
    public enum CardCategory: String, Codable, Sendable {
        case attackBoost = "攻撃強化"
        case speedBoost = "連射強化"
        case rangeBoost = "射程強化"
        case stressDefense = "ストレス対策"
        case special = "特殊効果"
    }
    
    public init(
        id: String,
        title: String,
        description: String,
        iconEmoji: String,
        category: CardCategory
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconEmoji = iconEmoji
        self.category = category
    }
}

public extension FriendshipCard {
    static let allCards: [FriendshipCard] = [
        FriendshipCard(
            id: "unity_power",
            title: "クラスの団結",
            description: "クラスメイト全員の攻撃力（説得力）が +15% 上昇する。",
            iconEmoji: "🤝",
            category: .attackBoost
        ),
        FriendshipCard(
            id: "rapid_study",
            title: "早解きトレーニング",
            description: "全員の攻撃間隔が 12% 短縮される。",
            iconEmoji: "⚡",
            category: .speedBoost
        ),
        FriendshipCard(
            id: "wide_blackboard",
            title: "大きな声の号令",
            description: "全員の攻撃・スキルの射程が +0.8マス 広がる。",
            iconEmoji: "📣",
            category: .rangeBoost
        ),
        FriendshipCard(
            id: "mind_relief",
            title: "心の余裕",
            description: "マドンナの最大ストレス許容量が +3 増加し、ストレスを2回復する。",
            iconEmoji: "☕",
            category: .stressDefense
        ),
        FriendshipCard(
            id: "desk_tactics",
            title: "机の連携バリケード",
            description: "机の隣に配置されたクラスメイトの攻撃速度が +25% 上昇する。",
            iconEmoji: "🪑",
            category: .special
        ),
        FriendshipCard(
            id: "envelope_bounce",
            title: "返送用封筒",
            description: "紙・カード系の攻撃が敵間で1回跳弾するようになる。",
            iconEmoji: "✉️",
            category: .special
        ),
        FriendshipCard(
            id: "cheer_boost",
            title: "応援席の声援",
            description: "控え（応援席）メンバーによるパッシブ効果が 1.5倍 に強化される。",
            iconEmoji: "📣",
            category: .special
        )
    ]
}
