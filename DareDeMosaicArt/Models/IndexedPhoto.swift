import Foundation

/// 解析済みの写真素材アイテム
public struct IndexedPhoto: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let labColor: LabColor
    public var signature: SpatialColorSignature?
    public var thumbnailData: Data?
    
    public init(
        id: String,
        labColor: LabColor,
        signature: SpatialColorSignature? = nil,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.labColor = labColor
        self.signature = signature
        self.thumbnailData = thumbnailData
    }
}
