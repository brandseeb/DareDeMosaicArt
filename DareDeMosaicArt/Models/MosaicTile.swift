import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// ピースの配置元種別
public enum PlacementOrigin: String, Codable, Sendable {
    case automatic          // ライブラリからの自動マッチング
    case captured           // カメラによるミッション撮影
    case manuallySelected   // 類似色候補からの手動選択（再マッチングで上書きされない）
    case autoFilled         // 空きマスの段階的近似自動配置（リセット可能）
    
    public var localizedTitle: LocalizedStringResource {
        switch self {
        case .automatic: return LocalizedStringResource("placement.automatic", defaultValue: "ライブラリ自動配置")
        case .captured: return LocalizedStringResource("placement.captured", defaultValue: "カメラ撮影")
        case .manuallySelected: return LocalizedStringResource("placement.manual", defaultValue: "手動選択")
        case .autoFilled: return LocalizedStringResource("placement.autoFilled", defaultValue: "自動配置")
        }
    }
}

/// モザイクアートを構成する1マス（タイル）の情報
public struct MosaicTile: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let gridX: Int
    public let gridY: Int
    public let targetLabColor: LabColor
    public var targetSignature: SpatialColorSignature?
    
    // はめ込まれた写真の情報
    public var placedPhotoIdentifier: String?
    public var placedLabColor: LabColor?
    public var placedSignature: SpatialColorSignature?
    public var thumbnailData: Data?
    public var isLocked: Bool
    public var origin: PlacementOrigin
    public var placementSequence: Int? // タイムラプス用時系列制作順（0から採番）
    
    public init(
        id: UUID = UUID(),
        gridX: Int,
        gridY: Int,
        targetLabColor: LabColor,
        targetSignature: SpatialColorSignature? = nil,
        placedPhotoIdentifier: String? = nil,
        placedLabColor: LabColor? = nil,
        placedSignature: SpatialColorSignature? = nil,
        thumbnailData: Data? = nil,
        isLocked: Bool = false,
        origin: PlacementOrigin = .automatic,
        placementSequence: Int? = nil
    ) {
        self.id = id
        self.gridX = gridX
        self.gridY = gridY
        self.targetLabColor = targetLabColor
        self.targetSignature = targetSignature
        self.placedPhotoIdentifier = placedPhotoIdentifier
        self.placedLabColor = placedLabColor
        self.placedSignature = placedSignature
        self.thumbnailData = thumbnailData
        self.isLocked = isLocked
        self.origin = isLocked ? (origin == .automatic ? .captured : origin) : origin
        self.placementSequence = placementSequence
    }
    
    public var isFilled: Bool {
        // 撮影ピースの画像本体は遅延読み込み時にメタデータから分離されるため、originでも論理状態を保持する。
        placedPhotoIdentifier != nil || thumbnailData != nil || origin == .captured
    }
    
    // MARK: - Codable（旧データ後方互換性）
    enum CodingKeys: String, CodingKey {
        case id, gridX, gridY, targetLabColor, targetSignature
        case placedPhotoIdentifier, placedLabColor, placedSignature
        case thumbnailData, isLocked, origin, placementSequence
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.gridX = try container.decode(Int.self, forKey: .gridX)
        self.gridY = try container.decode(Int.self, forKey: .gridY)
        self.targetLabColor = try container.decode(LabColor.self, forKey: .targetLabColor)
        self.targetSignature = try container.decodeIfPresent(SpatialColorSignature.self, forKey: .targetSignature)
        self.placedPhotoIdentifier = try container.decodeIfPresent(String.self, forKey: .placedPhotoIdentifier)
        self.placedLabColor = try container.decodeIfPresent(LabColor.self, forKey: .placedLabColor)
        self.placedSignature = try container.decodeIfPresent(SpatialColorSignature.self, forKey: .placedSignature)
        self.thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        let locked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        self.isLocked = locked
        self.placementSequence = try container.decodeIfPresent(Int.self, forKey: .placementSequence)
        
        // 旧データ移行: origin が無ければ isLocked から判定
        if let decodedOrigin = try container.decodeIfPresent(PlacementOrigin.self, forKey: .origin) {
            self.origin = decodedOrigin
        } else {
            self.origin = locked ? .captured : .automatic
        }
    }
}
