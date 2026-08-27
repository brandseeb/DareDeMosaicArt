import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// タイル画像のインメモリキャッシュ（デコード重複とメインスレッドブロックを完全排除）
@MainActor
public final class TileImageCache {
    public static let shared = TileImageCache()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 4000
    }
    
    public func image(for tileId: UUID, data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = tileId.uuidString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
    
    public func clear() {
        cache.removeAllObjects()
    }
}

/// モザイクアートのキャンバスビュー（GPU Canvas による超高速60fps描画 & ズーム・パン & タップ判定）
public struct MosaicCanvasView: View {
    public let project: MosaicProject
    public let selectedTileId: UUID?
    public let showGuideImage: Bool
    public let guideOpacity: Double
    public let onSelectTile: (MosaicTile) -> Void
    
    @Binding public var zoomScale: CGFloat
    @Binding public var offset: CGSize
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    public init(
        project: MosaicProject,
        selectedTileId: UUID? = nil,
        showGuideImage: Bool = false,
        guideOpacity: Double = 0.4,
        zoomScale: Binding<CGFloat>,
        offset: Binding<CGSize>,
        onSelectTile: @escaping (MosaicTile) -> Void
    ) {
        self.project = project
        self.selectedTileId = selectedTileId
        self.showGuideImage = showGuideImage
        self.guideOpacity = guideOpacity
        self._zoomScale = zoomScale
        self._offset = offset
        self.onSelectTile = onSelectTile
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let canvasSize = min(geometry.size.width, geometry.size.height)
            let gridW = max(1, project.gridWidth)
            let gridH = max(1, project.gridHeight)
            let tileWidth = canvasSize / CGFloat(gridW)
            let tileHeight = canvasSize / CGFloat(gridH)
            
            ZStack {
                Color.black
                
                // メインの超高速 Canvas 描画
                Canvas { context, size in
                    let tiles = project.tiles
                    
                    // 1. 各タイルの高速一括描画
                    for tile in tiles {
                        let x = CGFloat(tile.gridX) * tileWidth
                        let y = CGFloat(tile.gridY) * tileHeight
                        let tileRect = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)
                        
                        if let img = TileImageCache.shared.image(for: tile.id, data: tile.thumbnailData) {
                            // 配置済み写真の描画
                            context.draw(Image(uiImage: img), in: tileRect)
                        } else {
                            // 未配置マス: 目標Lab色で塗りつぶし
                            let color = tile.targetLabColor.swiftUIColor
                            context.fill(Path(tileRect), with: .color(color))
                            
                            // グリッド線
                            context.stroke(Path(tileRect), with: .color(Color.white.opacity(0.3)), lineWidth: 0.5)
                        }
                        
                        // 選択中タイルのハイライト
                        if tile.id == selectedTileId {
                            context.stroke(Path(tileRect), with: .color(Color.yellow), lineWidth: 2.5)
                        }
                    }
                }
                .frame(width: canvasSize, height: canvasSize)
                // 下絵オーバーレイ（ガイド）
                .overlay {
                    if showGuideImage, let targetImg = UIImage(data: project.targetImageData) {
                        Image(uiImage: targetImg)
                            .resizable()
                            .aspectRatio(1.0, contentMode: .fit)
                            .opacity(guideOpacity)
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(zoomScale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        // ピンチズーム
                        MagnificationGesture()
                            .onChanged { val in
                                let delta = val / lastScale
                                lastScale = val
                                zoomScale = min(max(zoomScale * delta, 1.0), 6.0)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                                if zoomScale <= 1.0 {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        zoomScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            },
                        // パン（ドラッグ）移動
                        DragGesture()
                            .onChanged { val in
                                if zoomScale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + val.translation.width,
                                        height: lastOffset.height + val.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                if zoomScale <= 1.0 {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                } else {
                                    lastOffset = offset
                                }
                            }
                    )
                )
                .simultaneousGesture(
                    // シングルタップ: タップ位置から該当タイルを計算して選択
                    SpatialTapGesture(count: 1)
                        .onEnded { value in
                            handleTap(at: value.location, canvasSize: canvasSize, gridW: gridW, gridH: gridH)
                        }
                )
                .simultaneousGesture(
                    // ダブルタップ: ズームリセット
                    SpatialTapGesture(count: 2)
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                zoomScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .clipped()
        }
        .contentShape(Rectangle())
        .clipped()
    }
    
    // MARK: - タップ座標からタイルを判定
    private func handleTap(at location: CGPoint, canvasSize: CGFloat, gridW: Int, gridH: Int) {
        guard canvasSize > 0, gridW > 0, gridH > 0 else { return }
        
        let tileWidth = canvasSize / CGFloat(gridW)
        let tileHeight = canvasSize / CGFloat(gridH)
        
        let gridX = Int(location.x / tileWidth)
        let gridY = Int(location.y / tileHeight)
        
        guard gridX >= 0, gridX < gridW, gridY >= 0, gridY < gridH else { return }
        
        let index = gridY * gridW + gridX
        if index < project.tiles.count {
            let tile = project.tiles[index]
            onSelectTile(tile)
        } else if let found = project.tiles.first(where: { $0.gridX == gridX && $0.gridY == gridY }) {
            onSelectTile(found)
        }
    }
}
