import Foundation

/// モザイクアートを構成する1つのマス（タイル）
public struct MosaicTile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let gridX: Int
    public let gridY: Int
    
    /// このマスが求めている目標色
    public let targetLabColor: LabColor

    /// 目標マス内の 3×3 空間色特徴。旧データとの互換性のため optional。
    public let targetSignature: SpatialColorSignature?
    
    /// 配置された写真の識別子 (PHAsset localIdentifier または 保存ファイルパス)
    public var placedPhotoIdentifier: String?
    
    /// 配置された写真の実測代表色
    public var placedLabColor: LabColor?

    /// 配置された写真の 3×3 空間色特徴。
    public var placedSignature: SpatialColorSignature?
    
    /// 写真のサムネイルデータ (軽量キャッシュ用)
    public var thumbnailData: Data?
    
    /// 写真が撮影または確定されてロックされた状態か
    public var isLocked: Bool
    
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
        isLocked: Bool = false
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
    }
    
    /// 写真がすでに配置されているか
    public var isFilled: Bool {
        return placedPhotoIdentifier != nil
    }
    
    /// 配置された写真と目標色の一致度 (0.0 〜 1.0)
    public var currentMatchRatio: Float {
        if let targetSignature, let placedSignature {
            return targetSignature.matchRatio(to: placedSignature)
        }
        guard let placed = placedLabColor else { return 0.0 }
        return targetLabColor.matchRatio(to: placed)
    }
    
    /// 許容誤差範囲（ΔE <= 15.0）に収まっているか
    public var isSufficient: Bool {
        if let targetSignature, let placedSignature {
            return targetSignature.distance(to: placedSignature) <= 18.0
        }
        guard let placed = placedLabColor else { return false }
        return targetLabColor.distance(to: placed) <= 15.0
    }
}
