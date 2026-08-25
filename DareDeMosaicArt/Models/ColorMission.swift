import Foundation

/// 撮影ミッション（不足色の探索クエスト）
public struct ColorMission: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    /// 探すべきターゲット色
    public let targetColor: LabColor
    public let targetSignature: SpatialColorSignature?
    /// タイトル（例: 「濃いブルーを探そう！」）
    public let title: String
    /// ヒント（例: 「空やジーンズ、青い看板などを狙ってみよう」）
    public let hint: String
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
        title: String? = nil,
        hint: String? = nil,
        targetTileIds: [UUID] = [],
        passThreshold: Float = 0.60, // 気持ちよく合格できる親切な閾値
        isCompleted: Bool = false
    ) {
        self.id = id
        self.targetColor = targetColor
        self.targetSignature = targetSignature
        self.title = title ?? "「\(targetColor.localizedName)」を探そう！"
        self.hint = hint ?? Self.generateDefaultHint(for: targetColor)
        self.targetTileIds = targetTileIds
        self.passThreshold = passThreshold
        self.isCompleted = isCompleted
    }
    
    /// 残り必要枚数
    public var remainingCount: Int {
        return targetTileIds.count
    }
    
    /// 色相・明度に応じた探索ヒントの自動生成
    private static func generateDefaultHint(for color: LabColor) -> String {
        let chroma = sqrt(color.a * color.a + color.b * color.b)

        if color.l < 20.0 {
            return "影、黒い服、モニターの枠、夜の景色などを狙ってみよう！"
        } else if color.l > 85.0 && chroma < 10.0 {
            return "白い壁、紙、白いシャツ、雲などを狙ってみよう！"
        } else if color.l > 75.0 && color.a < -15.0 {
            return "若葉、ライム、明るい緑の小物などを探してみよう！"
        }
        
        let name = color.localizedName
        if name.contains("青") || name.contains("水色") {
            return "青空、海、ジーンズ、文房具、青いペットボトルなどを探してみよう！"
        } else if name.contains("緑") {
            return "観葉植物、公園の芝生、街路樹、緑色のパッケージなどを探してみよう！"
        } else if name.contains("赤") || name.contains("ピンク") {
            return "花、看板、服、トマト、赤い小物などを探してみよう！"
        } else if name.contains("黄") || name.contains("オレンジ") {
            return "フルーツ、文具、照明、オレンジ色のパッケージなどを探してみよう！"
        }
        return "身の回りのものをカメラでかざして、色が合う場所を探してみよう！"
    }
}
