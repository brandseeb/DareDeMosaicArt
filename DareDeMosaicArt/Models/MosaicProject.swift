import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// ゲームモード（全マス撮影 vs 端末写真活用）
public enum GameMode: String, Codable, CaseIterable, Sendable {
    case fullHunt = "全マス撮影 (じっくり)"
    case hybrid = "端末写真＋不足色撮影 (おすすめ)"
    
    public var description: String {
        switch self {
        case .fullHunt:
            return "すべてのマスを現実世界のカメラ撮影で埋めていく、究極のモザイクアート体験。"
        case .hybrid:
            return "スマホ内の写真を自動で当てはめ、足りない色だけを日常からカメラで探して完成させるモード。"
        }
    }
}

/// 写真ソース種別
public enum PhotoSource: Codable, Sendable, Equatable, Hashable {
    case allLocalPhotos
    case album(localIdentifier: String, title: String)
    
    public var displayName: String {
        switch self {
        case .allLocalPhotos:
            return "端末内のすべての写真"
        case .album(_, let title):
            return "アルバム: \(title)"
        }
    }
}

/// アルバム選択用アイテム
public struct PhotoAlbumItem: Identifiable, Sendable, Equatable {
    public let id: String // PHAssetCollection.localIdentifier
    public let title: String
    public let assetCount: Int
    
    public init(id: String, title: String, assetCount: Int) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
    }
}

/// 刻印・サイン設定モデル
public struct WatermarkConfig: Codable, Sendable, Equatable {
    public var text: String
    public var fontDesign: FontDesignOption
    public var position: PositionOption
    public var colorStyle: ColorStyleOption
    
    public init(
        text: String = "",
        fontDesign: FontDesignOption = .standard,
        position: PositionOption = .footerBar,
        colorStyle: ColorStyleOption = .whiteWithShadow
    ) {
        self.text = text
        self.fontDesign = fontDesign
        self.position = position
        self.colorStyle = colorStyle
    }
    
    public enum FontDesignOption: String, Codable, CaseIterable, Sendable {
        case standard = "標準 (ゴシック)"
        case serif = "エレガント (明朝)"
        case monospaced = "モダン (等幅)"
        case rounded = "やわらか (丸ゴシック)"
    }
    
    public enum PositionOption: String, Codable, CaseIterable, Sendable {
        case bottomCenter = "中央下"
        case bottomRight = "右下"
        case bottomLeft = "左下"
        case footerBar = "下部帯 (フレーム内)"
    }
    
    public enum ColorStyleOption: String, Codable, CaseIterable, Sendable {
        case whiteWithShadow = "ホワイト (影付き)"
        case blackWithShadow = "ブラック (影付き)"
        case gold = "プレミアムゴールド"
    }
}

/// 1つのモザイクアート作品プロジェクトデータ
public struct MosaicProject: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    
    // 元となる目標画像
    public var targetImageData: Data
    
    // グリッド設定
    public var gridWidth: Int
    public var gridHeight: Int
    public var mode: GameMode
    public var photoSource: PhotoSource
    
    // タイル一覧
    public var tiles: [MosaicTile]
    
    // 不足色ミッション
    public var missions: [ColorMission]
    
    // 完成フラグ
    public var isCompleted: Bool
    
    // 刻印・透かし設定（Pro）
    public var watermarkConfig: WatermarkConfig?
    
    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        targetImageData: Data = Data(),
        gridWidth: Int,
        gridHeight: Int,
        mode: GameMode = .hybrid,
        photoSource: PhotoSource = .allLocalPhotos,
        tiles: [MosaicTile],
        missions: [ColorMission] = [],
        isCompleted: Bool = false,
        watermarkConfig: WatermarkConfig? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.targetImageData = targetImageData
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.mode = mode
        self.photoSource = photoSource
        self.tiles = tiles
        self.missions = missions
        self.isCompleted = isCompleted
        self.watermarkConfig = watermarkConfig
    }
    
    /// 進捗率 (0.0 〜 1.0)
    public var progress: Float {
        guard !tiles.isEmpty else { return 0.0 }
        let filledCount = tiles.filter { $0.isFilled }.count
        return Float(filledCount) / Float(tiles.count)
    }
    
    /// 進捗率パーセンテージ文字列
    public var progressPercentageString: String {
        return "\(Int(progress * 100))%"
    }
    
    /// 埋まっているタイル数
    public var filledCount: Int {
        tiles.filter { $0.isFilled }.count
    }
    
    /// 総タイル数
    public var totalTilesCount: Int {
        tiles.count
    }
    
    // MARK: - Codable（旧データ後方互換性）
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, targetImageData
        case gridWidth, gridHeight, mode, photoSource, tiles, missions, isCompleted, watermarkConfig
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.targetImageData = try container.decode(Data.self, forKey: .targetImageData)
        self.gridWidth = try container.decode(Int.self, forKey: .gridWidth)
        self.gridHeight = try container.decode(Int.self, forKey: .gridHeight)
        self.mode = try container.decode(GameMode.self, forKey: .mode)
        self.photoSource = try container.decodeIfPresent(PhotoSource.self, forKey: .photoSource) ?? .allLocalPhotos
        self.tiles = try container.decode([MosaicTile].self, forKey: .tiles)
        self.missions = try container.decodeIfPresent([ColorMission].self, forKey: .missions) ?? []
        self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        self.watermarkConfig = try container.decodeIfPresent(WatermarkConfig.self, forKey: .watermarkConfig)
    }
}
