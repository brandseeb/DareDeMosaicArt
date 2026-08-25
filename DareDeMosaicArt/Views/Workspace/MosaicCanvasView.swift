import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// モザイクアートのキャンバスビュー（全体フィット & ズーム・パン対応 & 完全クリップ）
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
            let tileSide = canvasSize / CGFloat(max(1, project.gridWidth))
            
            ZStack {
                Color.black
                
                // モザイクアート本体
                ZStack {
                    // グリッド描画
                    VStack(spacing: 0) {
                        ForEach(0..<project.gridHeight, id: \.self) { y in
                            HStack(spacing: 0) {
                                ForEach(0..<project.gridWidth, id: \.self) { x in
                                    let index = y * project.gridWidth + x
                                    if index < project.tiles.count {
                                        let tile = project.tiles[index]
                                        tileCell(for: tile, size: tileSide)
                                            .onTapGesture {
                                                onSelectTile(tile)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    
                    // 下絵（元画像）オーバーレイガイド
                    if showGuideImage, let targetImg = UIImage(data: project.targetImageData) {
                        Image(uiImage: targetImg)
                            .resizable()
                            .aspectRatio(1.0, contentMode: .fit)
                            .opacity(guideOpacity)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: canvasSize, height: canvasSize)
                .scaleEffect(zoomScale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
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
                .onTapGesture(count: 2) {
                    // ダブルタップで全体表示＆中央リセット
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped() // キャンバス領域外へのはみ出しを確実に防止
        }
        .clipped() // 親コンテナ外へのはみ出しも確実に防止
    }
    
    @ViewBuilder
    private func tileCell(for tile: MosaicTile, size: CGFloat) -> some View {
        let isSelected = tile.id == selectedTileId
        
        ZStack {
            if let data = tile.thumbnailData, let img = UIImage(data: data) {
                // はまっている写真
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // 未充足のマス（目標色の背景 ＋ ドット枠）
                ZStack {
                    tile.targetLabColor.swiftUIColor
                    
                    Rectangle()
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    
                    if size >= 18 {
                        Image(systemName: "plus")
                            .font(.system(size: max(6, size * 0.3)))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            
            // 選択時のハイライト枠
            if isSelected {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}
