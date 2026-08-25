import Foundation

/// プレイモード
public enum GameMode: String, Codable, CaseIterable, Sendable {
    /// ハイブリッドモード（ライブラリ自動配置 ＋ 不足色のみ撮影）
    case hybrid = "ハイブリッド"
    /// 完全ハントモード（全マスをゼロから撮影）
    case fullHunt = "完全ハント"
    
    public var description: String {
        switch self {
        case .hybrid:
            return "写真ライブラリから自動配置し、どうしても足りない色だけを日常から撮影して集めます。"
        case .fullHunt:
            return "写真ライブラリは使わず、すべてのマスを日常の景色からカメラで撮影して完成させます。"
        }
    }
}

/// モザイクアートプロジェクト
public struct MosaicProject: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    
    /// 元となるターゲット画像データ (JPEG/PNG)
    public var targetImageData: Data
    
    /// グリッド分割数
    public var gridWidth: Int
    public var gridHeight: Int
    
    /// 選択されたゲームモード
    public var mode: GameMode
    
    /// 全マス（タイル）
    public var tiles: [MosaicTile]
    
    /// 現在アクティブな不足色ミッション一覧
    public var missions: [ColorMission]
    
    /// 完成フラグ
    public var isCompleted: Bool
    
    public init(
        id: UUID = UUID(),
        title: String = "新しいモザイクアート",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        targetImageData: Data,
        gridWidth: Int = 15,
        gridHeight: Int = 15,
        mode: GameMode = .hybrid,
        tiles: [MosaicTile] = [],
        missions: [ColorMission] = [],
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.targetImageData = targetImageData
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.mode = mode
        self.tiles = tiles
        self.missions = missions
        self.isCompleted = isCompleted
    }
    
    /// 総タイル数
    public var totalTilesCount: Int {
        return gridWidth * gridHeight
    }
    
    /// 充足済み（はまっている）タイル数
    public var filledTilesCount: Int {
        return tiles.filter { $0.isFilled }.count
    }
    
    /// 進捗率 (0.0 〜 1.0)
    public var progress: Float {
        guard totalTilesCount > 0 else { return 0.0 }
        return Float(filledTilesCount) / Float(totalTilesCount)
    }
    
    /// 進捗パーセンテージ表記 (例: "75%")
    public var progressPercentageString: String {
        return "\(Int(progress * 100))%"
    }
}
