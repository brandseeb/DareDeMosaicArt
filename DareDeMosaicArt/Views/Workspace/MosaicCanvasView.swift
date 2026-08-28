import SwiftUI

#if canImport(UIKit)
import UIKit

/// 数千枚のタイルを操作中に再描画しないため、モザイクを1枚の表示用画像へ合成する。
private enum MosaicPreviewRenderer {
    static func render(project: MosaicProject, pixels: Int) -> UIImage? {
        let interval = PerformanceDiagnostics.begin(
            .mosaicPreviewRender,
            metadata: "tiles=\(project.tiles.count), pixels=\(pixels)"
        )
        defer {
            PerformanceDiagnostics.end(interval, metadata: "grid=\(project.gridWidth)x\(project.gridHeight)")
        }
        guard pixels > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .medium
        let gridWidth = max(1, project.gridWidth)
        let gridHeight = max(1, project.gridHeight)
        let tileWidth = CGFloat(pixels) / CGFloat(gridWidth)
        let tileHeight = CGFloat(pixels) / CGFloat(gridHeight)

        for tile in project.tiles {
            autoreleasepool {
                let rect = CGRect(
                    x: CGFloat(tile.gridX) * tileWidth,
                    y: CGFloat(gridHeight - tile.gridY - 1) * tileHeight,
                    width: tileWidth,
                    height: tileHeight
                )

                if let data = tile.thumbnailData,
                   let image = UIImage(data: data),
                   let cgImage = image.cgImage {
                    let drawRect = ImageUtils.aspectFillRect(
                        imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                        destinationRect: rect
                    )
                    context.saveGState()
                    context.clip(to: rect)
                    context.draw(cgImage, in: drawRect)
                    context.restoreGState()
                } else {
                    context.setFillColor(tile.targetLabColor.uiColor.cgColor)
                    context.fill(rect)
                    context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
                    context.setLineWidth(0.5)
                    context.stroke(rect)
                }
            }
        }

        guard let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image)
    }
}

/// 同じ作品・同じ更新状態の結合画像を、画面を閉じて開き直した際にも再利用する。
@MainActor
private final class MosaicPreviewImageCache {
    static let shared = MosaicPreviewImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 8
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let pixelCost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        cache.setObject(image, forKey: key as NSString, cost: pixelCost)
    }
}

/// UIImageView 1枚だけをUIScrollViewのネイティブエンジンで拡大・移動する。
private final class NativeMosaicScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private struct NativeZoomMosaicView: UIViewRepresentable {
    let image: UIImage
    let originalImage: UIImage?
    let isShowingOriginal: Bool
    let gridWidth: Int
    let gridHeight: Int
    let selectedTile: MosaicTile?
    let onSelectTile: (Int, Int) -> Void
    @Binding var zoomScale: CGFloat
    @Binding var offset: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = NativeMosaicScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = context.coordinator.imageView
        imageView.image = isShowingOriginal ? (originalImage ?? image) : image
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(singleTap)
        imageView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.layoutContent(in: scrollView)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        
        let targetImg = (isShowingOriginal ? originalImage : image) ?? image
        if context.coordinator.imageView.image !== targetImg {
            context.coordinator.imageView.image = targetImg
        }
        context.coordinator.selectionLayer.isHidden = isShowingOriginal
        
        context.coordinator.layoutContent(in: scrollView)

        if zoomScale <= 1.001, scrollView.zoomScale > 1.001 {
            scrollView.setZoomScale(1, animated: true)
        }
        context.coordinator.updateSelection()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: NativeZoomMosaicView
        weak var scrollView: UIScrollView?
        let imageView = UIImageView()
        let selectionLayer = CAShapeLayer()
        var baseSide: CGFloat = 0

        init(parent: NativeZoomMosaicView) {
            self.parent = parent
            super.init()
            selectionLayer.fillColor = UIColor.clear.cgColor
            selectionLayer.strokeColor = UIColor.systemYellow.cgColor
            selectionLayer.lineWidth = 2.5
            imageView.layer.addSublayer(selectionLayer)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        /// UIViewRepresentable の初回更新時に bounds が 0 でも、UIKit の実レイアウト確定後に必ず再配置する。
        func layoutContent(in scrollView: UIScrollView) {
            let side = min(scrollView.bounds.width, scrollView.bounds.height)
            guard side > 0 else { return }

            let desiredFrame = CGRect(
                x: (scrollView.bounds.width - side) / 2,
                y: (scrollView.bounds.height - side) / 2,
                width: side,
                height: side
            )
            let sizeChanged = abs(baseSide - side) > 0.5
            let frameChanged = abs(imageView.frame.minX - desiredFrame.minX) > 0.5
                || abs(imageView.frame.minY - desiredFrame.minY) > 0.5
                || abs(imageView.frame.width - desiredFrame.width) > 0.5
                || abs(imageView.frame.height - desiredFrame.height) > 0.5

            if sizeChanged || (scrollView.zoomScale <= 1.001 && frameChanged) {
                baseSide = side
                imageView.frame = desiredFrame
                scrollView.contentSize = CGSize(width: side, height: side)
                updateSelection()
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoomScale = scrollView.zoomScale
            updateSelection()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.zoomScale > 1.001 else { return }
            parent.offset = CGSize(width: -scrollView.contentOffset.x, height: -scrollView.contentOffset.y)
        }

        func updateSelection() {
            guard let tile = parent.selectedTile,
                  parent.gridWidth > 0,
                  parent.gridHeight > 0 else {
                selectionLayer.path = nil
                return
            }
            let width = imageView.bounds.width / CGFloat(parent.gridWidth)
            let height = imageView.bounds.height / CGFloat(parent.gridHeight)
            let rect = CGRect(
                x: CGFloat(tile.gridX) * width,
                y: CGFloat(tile.gridY) * height,
                width: width,
                height: height
            )
            selectionLayer.frame = imageView.bounds
            selectionLayer.lineWidth = 2.5 / max(1, scrollView?.zoomScale ?? 1)
            selectionLayer.path = UIBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: imageView)
            guard imageView.bounds.contains(point), parent.gridWidth > 0, parent.gridHeight > 0 else { return }
            let x = min(parent.gridWidth - 1, max(0, Int(point.x / imageView.bounds.width * CGFloat(parent.gridWidth))))
            let y = min(parent.gridHeight - 1, max(0, Int(point.y / imageView.bounds.height * CGFloat(parent.gridHeight))))
            parent.onSelectTile(x, y)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1, animated: true)
                parent.offset = .zero
            } else {
                let point = recognizer.location(in: imageView)
                let targetScale: CGFloat = 2.5
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                scrollView.zoom(
                    to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                    animated: true
                )
            }
        }
    }
}
#endif

/// モザイクアートのキャンバス。操作中は合成済み画像1枚だけをGPUで変形する。
public struct MosaicCanvasView: View {
    public let project: MosaicProject
    public let selectedTileId: UUID?
    public let showGuideImage: Bool
    public let guideOpacity: Double
    public let isShowingOriginalImage: Bool
    public let onSelectTile: (MosaicTile) -> Void

    @Binding public var zoomScale: CGFloat
    @Binding public var offset: CGSize
    @State private var previewImage: UIImage?
    @State private var targetUIImage: UIImage?
    @State private var renderTask: Task<Void, Never>?

    public init(
        project: MosaicProject,
        selectedTileId: UUID? = nil,
        showGuideImage: Bool = false,
        guideOpacity: Double = 0.4,
        isShowingOriginalImage: Bool = false,
        zoomScale: Binding<CGFloat>,
        offset: Binding<CGSize>,
        onSelectTile: @escaping (MosaicTile) -> Void
    ) {
        self.project = project
        self.selectedTileId = selectedTileId
        self.showGuideImage = showGuideImage
        self.guideOpacity = guideOpacity
        self.isShowingOriginalImage = isShowingOriginalImage
        self._zoomScale = zoomScale
        self._offset = offset
        self.onSelectTile = onSelectTile
    }

    private var renderKey: String {
        let loadedImageCount = project.tiles.lazy.filter { $0.thumbnailData != nil }.count
        return "\(project.id.uuidString)-\(project.updatedAt.timeIntervalSinceReferenceDate)-\(project.filledCount)-\(loadedImageCount)"
    }

    private var selectedTile: MosaicTile? {
        guard let selectedTileId else { return nil }
        return project.tiles.first { $0.id == selectedTileId }
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let previewImage {
                    #if canImport(UIKit)
                    NativeZoomMosaicView(
                        image: previewImage,
                        originalImage: targetUIImage,
                        isShowingOriginal: isShowingOriginalImage,
                        gridWidth: max(1, project.gridWidth),
                        gridHeight: max(1, project.gridHeight),
                        selectedTile: selectedTile,
                        onSelectTile: selectTileAt,
                        zoomScale: $zoomScale,
                        offset: $offset
                    )
                    #endif
                } else {
                    ProgressView("モザイクを表示中...")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: project.targetImageData) {
            if !project.targetImageData.isEmpty {
                targetUIImage = UIImage(data: project.targetImageData)
            }
        }
        .task(id: renderKey) {
            renderTask?.cancel()
            let key = renderKey
            if let cached = MosaicPreviewImageCache.shared.image(for: key) {
                previewImage = cached
                return
            }
            let snapshot = project
            let pixels = min(2048, max(1024, max(snapshot.gridWidth, snapshot.gridHeight) * 32))
            renderTask = Task {
                // 作品画像のhydrate直後にキーが更新されるため、短く待って未復元版の無駄な描画を避ける。
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let cached = MosaicPreviewImageCache.shared.image(for: key) {
                    previewImage = cached
                    return
                }
                let rendered = await Task.detached(priority: .userInitiated) {
                    MosaicPreviewRenderer.render(project: snapshot, pixels: pixels)
                }.value
                if let rendered {
                    MosaicPreviewImageCache.shared.insert(rendered, for: key)
                }
                guard !Task.isCancelled else { return }
                previewImage = rendered
            }
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    private func selectTileAt(gridX: Int, gridY: Int) {
        let directIndex = gridY * max(1, project.gridWidth) + gridX
        if project.tiles.indices.contains(directIndex) {
            let tile = project.tiles[directIndex]
            if tile.gridX == gridX && tile.gridY == gridY {
                onSelectTile(tile)
                return
            }
        }
        if let tile = project.tiles.first(where: { $0.gridX == gridX && $0.gridY == gridY }) {
            onSelectTile(tile)
        }
    }
}
