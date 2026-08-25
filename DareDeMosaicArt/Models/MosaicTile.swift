import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// ピースの配置元種別
public enum PlacementOrigin: String, Codable, Sendable {
    case automatic          // ライブラリからの自動マッチング
    case captured           // カメラによるミッション撮影
    case manuallySelected   // 類似色候補からの手動選択（再マッチングで上書きされない）
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
        origin: PlacementOrigin = .automatic
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
    }
    
    public var isFilled: Bool {
        placedPhotoIdentifier != nil || thumbnailData != nil
    }
    
    // MARK: - Codable（旧データ後方互換性）
    enum CodingKeys: String, CodingKey {
        case id, gridX, gridY, targetLabColor, targetSignature
        case placedPhotoIdentifier, placedLabColor, placedSignature
        case thumbnailData, isLocked, origin
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
        
        // 旧データ移行: origin が無ければ isLocked から判定
        if let decodedOrigin = try container.decodeIfPresent(PlacementOrigin.self, forKey: .origin) {
            self.origin = decodedOrigin
        } else {
            self.origin = locked ? .captured : .automatic
        }
    }
}
