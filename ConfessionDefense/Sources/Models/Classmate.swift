import Foundation

public enum ClassmateRole: String, Codable, CaseIterable, Sendable {
    case attacker = "アタッカー"
    case range = "レンジ"
    case tank = "タンク"
    case control = "コントロール"
    case healer = "ヒーラー"
    case support = "サポート"
}

public struct Classmate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let role: ClassmateRole
    public let emoji: String
    public let skillName: String
    public let skillDescription: String
    public var attackPower: Double
    public var attackInterval: Double // 攻撃間隔（秒）
    public var range: Double         // 射程（マス単位）
    public let projectileEmoji: String // 弾の見た目
    public let passiveBonusDescription: String // 応援席でのパッシブ効果
    
    public init(
        id: String,
        name: String,
        role: ClassmateRole,
        emoji: String,
        skillName: String,
        skillDescription: String,
        attackPower: Double,
        attackInterval: Double,
        range: Double,
        projectileEmoji: String,
        passiveBonusDescription: String
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.emoji = emoji
        self.skillName = skillName
        self.skillDescription = skillDescription
        self.attackPower = attackPower
        self.attackInterval = attackInterval
        self.range = range
        self.projectileEmoji = projectileEmoji
        self.passiveBonusDescription = passiveBonusDescription
    }
}

// MARK: - 初期プリセットキャラクター（MVP 8人+α）
public extension Classmate {
    static let allPresets: [Classmate] = [
        Classmate(
            id: "class_rep",
            name: "学級委員長",
            role: .support,
            emoji: "👓",
            skillName: "校則カード",
            skillDescription: "校則カードを発射し、隣接する味方の攻撃速度を上昇させる。",
            attackPower: 12,
            attackInterval: 1.0,
            range: 2.5,
            projectileEmoji: "📜",
            passiveBonusDescription: "全味方の攻撃力 +5%"
        ),
        Classmate(
            id: "judo",
            name: "柔道部員",
            role: .tank,
            emoji: "🥋",
            skillName: "一本背負い",
            skillDescription: "近距離の告白者を大きく押し返し、ダメージを与える。",
            attackPower: 25,
            attackInterval: 1.6,
            range: 1.5,
            projectileEmoji: "💥",
            passiveBonusDescription: "全味方のノックバック力 +15%"
        ),
        Classmate(
            id: "baseball",
            name: "野球部投手",
            role: .range,
            emoji: "⚾",
            skillName: "ストレート直球",
            skillDescription: "直線上の敵を貫通する超高速の投球。",
            attackPower: 18,
            attackInterval: 0.9,
            range: 4.0,
            projectileEmoji: "⚾",
            passiveBonusDescription: "遠距離攻撃の弾速 +20%"
        ),
        Classmate(
            id: "broadcasting",
            name: "放送委員",
            role: .control,
            emoji: "📻",
            skillName: "校内放送波",
            skillDescription: "音波を放ち、周囲の告白者の移動速度を大きく下げる。",
            attackPower: 8,
            attackInterval: 1.4,
            range: 3.0,
            projectileEmoji: "📢",
            passiveBonusDescription: "敵全体の移動速度 -5%"
        ),
        Classmate(
            id: "nurse",
            name: "保健委員",
            role: .healer,
            emoji: "🩹",
            skillName: "応急処置",
            skillDescription: "マドンナのストレスを定期的に回復し、癒やしの風を送る。",
            attackPower: 0,
            attackInterval: 3.5,
            range: 3.0,
            projectileEmoji: "💊",
            passiveBonusDescription: "マドンナの初期ストレス耐性 +1"
        ),
        Classmate(
            id: "librarian",
            name: "図書委員",
            role: .control,
            emoji: "📖",
            skillName: "お静かに！",
            skillDescription: "文字弾を浴びせ、敵の特殊能力を一時的に封じる。",
            attackPower: 14,
            attackInterval: 1.2,
            range: 3.0,
            projectileEmoji: "🤫",
            passiveBonusDescription: "敵のスキル発生頻度 -10%"
        ),
        Classmate(
            id: "gal",
            name: "ギャル",
            role: .control,
            emoji: "💅",
            skillName: "噂話ネットワーク",
            skillDescription: "噂話の文字を拡散し、敵同士を衝突させて混乱させる。",
            attackPower: 15,
            attackInterval: 1.1,
            range: 2.8,
            projectileEmoji: "💬",
            passiveBonusDescription: "敵撃破時の友情ポイント +10%"
        ),
        Classmate(
            id: "delinquent",
            name: "不良",
            role: .tank,
            emoji: "🕶️",
            skillName: "メンチビーム",
            skillDescription: "鋭い眼光で立っているだけで前方の敵を威圧し足止めする。",
            attackPower: 20,
            attackInterval: 1.5,
            range: 1.8,
            projectileEmoji: "⚡",
            passiveBonusDescription: "家具（机）の耐久度 +20%"
        )
    ]
}
