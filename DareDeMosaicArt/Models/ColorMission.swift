import Foundation

/// 探索ヒントの種類（意味データのみ保存）
public enum ColorHintKind: String, Codable, Sendable {
    case dark
    case white
    case brightGreen
    case blue
    case green
    case red
    case orangeYellow
    case general
    
    public static func classify(from color: LabColor) -> ColorHintKind {
        let chroma = sqrt(color.a * color.a + color.b * color.b)
        
        if color.l < 20.0 {
            return .dark
        } else if color.l > 85.0 && chroma < 10.0 {
            return .white
        } else if color.l > 75.0 && color.a < -15.0 {
            return .brightGreen
        }
        
        var angle = atan2(color.b, color.a) * 180.0 / Float.pi
        if angle < 0 { angle += 360.0 }
        
        switch angle {
        case 15..<55, 315..<360:
            return .red
        case 55..<115:
            return .orangeYellow
        case 115..<175:
            return .green
        case 175..<315:
            return .blue
        default:
            return .general
        }
    }
    
    public var localizedResource: LocalizedStringResource {
        switch self {
        case .dark:
            return LocalizedStringResource("mission.hint.dark", defaultValue: "影、黒い服、モニターの枠、夜の景色などを狙ってみよう！")
        case .white:
            return LocalizedStringResource("mission.hint.white", defaultValue: "白い壁、紙、白いシャツ、雲などを狙ってみよう！")
        case .brightGreen:
            return LocalizedStringResource("mission.hint.brightGreen", defaultValue: "若葉、ライム、明るい緑の小物などを探してみよう！")
        case .blue:
            return LocalizedStringResource("mission.hint.blue", defaultValue: "青空、海、ジーンズ、文房具、青いペットボトルなどを探してみよう！")
        case .green:
            return LocalizedStringResource("mission.hint.green", defaultValue: "観葉植物、公園の芝生、街路樹、緑色のパッケージなどを探してみよう！")
        case .red:
            return LocalizedStringResource("mission.hint.red", defaultValue: "花、看板、服、トマト、赤い小物などを探してみよう！")
        case .orangeYellow:
            return LocalizedStringResource("mission.hint.orangeYellow", defaultValue: "フルーツ、文具、照明、オレンジ色のパッケージなどを探してみよう！")
        case .general:
            return LocalizedStringResource("mission.hint.general", defaultValue: "身の回りのものをカメラでかざして、色が合う場所を探してみよう！")
        }
    }
}

/// 撮影ミッション（不足色の探索クエスト）
public struct ColorMission: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    /// 探すべきターゲット色
    public let targetColor: LabColor
    public let targetSignature: SpatialColorSignature?
    /// ヒント種別
    public let hintKind: ColorHintKind
    /// カスタムタイトル識別子（撮り直し時など）
    public let isRetake: Bool
    /// この色を必要としているタイルのIDリスト
    public var targetTileIds: [UUID]
    /// 合格とみなす最小一致度 (0.0 〜 1.0)
    public let passThreshold: Float
    /// ミッション完了フラグ
    public var isCompleted: Bool
    
    public init(
        id: UUID = UUID(),
        targetColor: LabColor,
        targetSignature: SpatialColorSignature? = nil,
        hintKind: ColorHintKind? = nil,
        title: String? = nil,
        hint: String? = nil,
        targetTileIds: [UUID] = [],
        passThreshold: Float = 0.60,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.targetColor = targetColor
        self.targetSignature = targetSignature
        self.hintKind = hintKind ?? ColorHintKind.classify(from: targetColor)
        self.isRetake = title?.contains("撮り直し") == true || title?.contains("Retake") == true
        self.targetTileIds = targetTileIds
        self.passThreshold = passThreshold
        self.isCompleted = isCompleted
    }
    
    /// 残り必要枚数
    public var remainingCount: Int {
        return targetTileIds.count
    }
    
    /// ローカライズ対応のミッションタイトル
    public var localizedTitle: LocalizedStringResource {
        let colorName = String(localized: targetColor.localizedResource)
        if isRetake {
            return LocalizedStringResource("mission.retake.format \(colorName)")
        }
        return LocalizedStringResource("mission.findColor.format \(colorName)")
    }
    
    /// ローカライズ対応のヒント
    public var localizedHint: LocalizedStringResource {
        hintKind.localizedResource
    }
    
    /// 既存コード互換用タイトル
    public var title: String {
        String(localized: localizedTitle)
    }
    
    /// 既存コード互換用ヒント
    public var hint: String {
        String(localized: localizedHint)
    }
    
    // MARK: - Codable（旧JSONデータ後方互換性）
    enum CodingKeys: String, CodingKey {
        case id, targetColor, targetSignature, hintKind, isRetake, targetTileIds, passThreshold, isCompleted
        // 旧互換用キー（デコードのみで利用）
        case title, hint
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let color = try container.decode(LabColor.self, forKey: .targetColor)
        self.targetColor = color
        self.targetSignature = try container.decodeIfPresent(SpatialColorSignature.self, forKey: .targetSignature)
        self.targetTileIds = try container.decode(Array<UUID>.self, forKey: .targetTileIds)
        self.passThreshold = try container.decode(Float.self, forKey: .passThreshold)
        self.isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        
        // hintKind は保存値があればデコード、旧JSONなら targetColor から安全に再判定
        if let decodedKind = try container.decodeIfPresent(ColorHintKind.self, forKey: .hintKind) {
            self.hintKind = decodedKind
        } else {
            self.hintKind = ColorHintKind.classify(from: color)
        }
        
        if let decodedRetake = try container.decodeIfPresent(Bool.self, forKey: .isRetake) {
            self.isRetake = decodedRetake
        } else if let oldTitle = try container.decodeIfPresent(String.self, forKey: .title) {
            self.isRetake = oldTitle.contains("撮り直し")
        } else {
            self.isRetake = false
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(targetColor, forKey: .targetColor)
        try container.encodeIfPresent(targetSignature, forKey: .targetSignature)
        try container.encode(hintKind, forKey: .hintKind)
        try container.encode(isRetake, forKey: .isRetake)
        try container.encode(targetTileIds, forKey: .targetTileIds)
        try container.encode(passThreshold, forKey: .passThreshold)
        try container.encode(isCompleted, forKey: .isCompleted)
    }
}
