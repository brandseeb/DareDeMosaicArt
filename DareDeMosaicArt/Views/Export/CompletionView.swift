import SwiftUI
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// 完成セレモニー & 高解像度エクスポート・共有・刻印カスタマイズ画面
public struct CompletionView: View {
    @Binding public var project: MosaicProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeKit = StoreKitManager.shared
    
    @State private var baseRenderedImage: UIImage? = nil
    @State private var isRendering: Bool = false
    @State private var isExporting: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var showPaywall: Bool = false
    @State private var showWatermarkEditor: Bool = false
    @State private var showTimelapseSheet: Bool = false
    @State private var imageShareItem: MosaicImageShareItem? = nil
    
    // 一時編集用 WatermarkConfig
    @State private var draftWatermark: WatermarkConfig = WatermarkConfig()
    
    public init(project: Binding<MosaicProject>) {
        self._project = project
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // セレモニーヘッダー
                    VStack(spacing: 6) {
                        Text(project.isCompleted ? "🎉 完成おめでとうございます！ 🎉" : "現在のモザイクアート")
                            .font(.title2.bold())
                        Text("集めた写真がつながり、世界で1つのアートになりました")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                    
                    // プレビュー画像（オーバーレイプレビュー）
                    ZStack {
                        if let img = baseRenderedImage {
                            ZStack {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                
                                // 編集中のテキストオーバーレイ（即時反映）
                                if storeKit.isProUser && !draftWatermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    watermarkOverlayView
                                }
                            }
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                        } else {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("表示用プレビューを生成中...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(height: 280)
                        }
                    }
                    .frame(maxHeight: 320)
                    .padding(.horizontal)
                    
                    // 画質・Pro・刻印ステータス
                    HStack(spacing: 8) {
                        if storeKit.isProUser {
                            HStack(spacing: 4) {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.yellow)
                                Text("4K (4,096px)")
                                    .font(.caption.bold())
                            }
                            
                            Spacer()
                            
                            Button {
                                showWatermarkEditor = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil.and.outline")
                                    Text(draftWatermark.text.isEmpty ? "サイン・記念日を刻印する" : "刻印を編集")
                                }
                                .font(.caption.bold())
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(12)
                            }
                        } else {
                            Text("標準画質 (1,080px)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button {
                                showPaywall = true
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "crown.fill")
                                    Text("Proで4K・サイン刻印")
                                }
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // アクションボタン
                    VStack(spacing: 12) {
                        if baseRenderedImage != nil {
                            // 🎬 制作タイムラプス動画作成ボタン (Pro機能)
                            Button {
                                if !project.isCompleted {
                                    // 未完成時は案内のみ
                                } else if !storeKit.isProUser {
                                    showPaywall = true
                                } else {
                                    showTimelapseSheet = true
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "film.stack.fill")
                                        .foregroundColor(.yellow)
                                    Text(project.isCompleted ? "🎬 制作タイムラプス動画を作成" : "ピースがすべて埋まると動画を作成できます")
                                    if !storeKit.isProUser && project.isCompleted {
                                        Text("PRO")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.yellow.opacity(0.3))
                                            .cornerRadius(4)
                                    }
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(project.isCompleted ? Color.purple : Color.gray.opacity(0.5))
                                .cornerRadius(12)
                            }
                            .disabled(!project.isCompleted || isExporting || storeKit.proStatus == .loading)
                            
                            Button {
                                exportAndShare()
                            } label: {
                                HStack {
                                    if isExporting {
                                        ProgressView().tint(.white).padding(.trailing, 4)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    Text("SNSや友達にシェアする")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor)
                                .cornerRadius(12)
                            }
                            .disabled(isExporting)
                            
                            Button {
                                exportAndSaveToPhotos()
                            } label: {
                                HStack {
                                    if isExporting {
                                        ProgressView().padding(.trailing, 4)
                                    } else {
                                        Image(systemName: saveSuccess ? "checkmark.circle.fill" : "arrow.down.to.line")
                                    }
                                    Text(saveSuccess ? "カメラロールに保存しました！" : "カメラロールに保存")
                                }
                                .font(.headline)
                                .foregroundColor(saveSuccess ? .green : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                            .disabled(saveSuccess || isExporting)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywallView()
            }
            .sheet(isPresented: $showWatermarkEditor) {
                watermarkEditorSheet
            }
            .sheet(isPresented: $showTimelapseSheet) {
                TimelapseExportView(project: project) {
                    showTimelapseSheet = false
                }
            }
            .sheet(item: $imageShareItem) { item in
                MosaicImageActivityShareSheet(activityItems: [item.image])
                    .ignoresSafeArea()
            }
            .onAppear {
                if let saved = project.watermarkConfig {
                    self.draftWatermark = saved
                }
                renderBaseImage()
            }
            .onChange(of: storeKit.isProUser) { _, _ in
                baseRenderedImage = nil
                renderBaseImage()
            }
        }
    }
    
    // MARK: - プレビュー用テキストオーバーレイ
    private var watermarkOverlayView: some View {
        GeometryReader { _ in
            let text = sanitizeWatermarkText(draftWatermark.text)
            
            switch draftWatermark.position {
            case .footerBar:
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(text)
                            .font(fontForDesign(draftWatermark.fontDesign, size: 12))
                            .foregroundColor(textColorForStyle(draftWatermark.colorStyle))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                }
                
            case .bottomRight:
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(text)
                            .font(fontForDesign(draftWatermark.fontDesign, size: 12))
                            .foregroundColor(textColorForStyle(draftWatermark.colorStyle))
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .padding([.trailing, .bottom], 12)
                    }
                }
                
            case .bottomLeft:
                VStack {
                    Spacer()
                    HStack {
                        Text(text)
                            .font(fontForDesign(draftWatermark.fontDesign, size: 12))
                            .foregroundColor(textColorForStyle(draftWatermark.colorStyle))
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding([.leading, .bottom], 12)
                        Spacer()
                    }
                }
                
            case .bottomCenter:
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(text)
                            .font(fontForDesign(draftWatermark.fontDesign, size: 12))
                            .foregroundColor(textColorForStyle(draftWatermark.colorStyle))
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 12)
                        Spacer()
                    }
                }
            }
        }
    }
    
    // MARK: - 刻印設定エディタシート
    private var watermarkEditorSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("刻印テキスト (最大60文字・2行まで)")) {
                    TextField("例: 2026.08.26 Happy Wedding\nKen & Yui", text: $draftWatermark.text, axis: .vertical)
                        .lineLimit(2)
                        .onChange(of: draftWatermark.text) { _, newText in
                            draftWatermark.text = sanitizeWatermarkText(newText)
                        }
                    
                    Text("\(draftWatermark.text.count) / 60文字 (最大2行)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("フォントスタイル")) {
                    Picker("フォント", selection: $draftWatermark.fontDesign) {
                        ForEach(WatermarkConfig.FontDesignOption.allCases, id: \.self) { opt in
                            Text(opt.localizedResource).tag(opt)
                        }
                    }
                }
                
                Section(header: Text("配置位置")) {
                    Picker("位置", selection: $draftWatermark.position) {
                        ForEach(WatermarkConfig.PositionOption.allCases, id: \.self) { opt in
                            Text(opt.localizedResource).tag(opt)
                        }
                    }
                }
                
                Section(header: Text("文字カラー・スタイル")) {
                    Picker("カラー", selection: $draftWatermark.colorStyle) {
                        ForEach(WatermarkConfig.ColorStyleOption.allCases, id: \.self) { opt in
                            Text(opt.localizedResource).tag(opt)
                        }
                    }
                }
            }
            .navigationTitle("サイン・刻印の設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if let original = project.watermarkConfig {
                            draftWatermark = original
                        } else {
                            draftWatermark = WatermarkConfig()
                        }
                        showWatermarkEditor = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") {
                        project.watermarkConfig = draftWatermark
                        showWatermarkEditor = false
                    }
                }
            }
        }
    }
    
    // MARK: - ベースレンダリング
    private func renderBaseImage() {
        guard baseRenderedImage == nil else { return }
        isRendering = true
        let isPro = storeKit.isProUser
        
        Task.detached(priority: .userInitiated) {
            // 画面表示だけで4KやPHAsset原画を読み込まない。正式画像は保存・共有時に生成する。
            let finalImage = await Self.renderRawMosaic(
                project: project,
                isPro: isPro,
                outputPixels: 1024,
                useHighQualityAssets: false
            )
            
            await MainActor.run {
                self.baseRenderedImage = finalImage
                self.isRendering = false
            }
        }
    }
    
    // MARK: - 4K正式レンダリング & 保存/共有
    private func generateFinalExportImage() async -> UIImage? {
        let isPro = storeKit.isProUser
        guard let base = await Self.renderRawMosaic(
            project: project,
            isPro: isPro,
            outputPixels: nil,
            useHighQualityAssets: true
        ) else { return nil }
        
        if isPro, let watermark = project.watermarkConfig, !watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await Self.renderWatermarkOnImage(baseImage: base, config: watermark)
        }
        return base
    }
    
    private func exportAndSaveToPhotos() {
        guard !isExporting else { return }
        isExporting = true
        
        Task {
            if let finalImage = await generateFinalExportImage() {
                await MainActor.run {
                    UIImageWriteToSavedPhotosAlbum(finalImage, nil, nil, nil)
                    self.saveSuccess = true
                    self.isExporting = false
                }
            } else {
                await MainActor.run { self.isExporting = false }
            }
        }
    }
    
    private func exportAndShare() {
        guard !isExporting else { return }
        isExporting = true
        
        Task {
            if let finalImage = await generateFinalExportImage() {
                await MainActor.run {
                    self.isExporting = false
                    self.imageShareItem = MosaicImageShareItem(image: finalImage)
                }
            } else {
                await MainActor.run { self.isExporting = false }
            }
        }
    }

    // MARK: - モザイクビットマップ合成
    private static func renderRawMosaic(
        project: MosaicProject,
        isPro: Bool,
        outputPixels: Int? = nil,
        useHighQualityAssets: Bool = true
    ) async -> UIImage? {
        let mosaicPixels = outputPixels ?? (isPro ? 4096 : 1080)
        let footerHeight = isPro ? 0 : max(32, Int((54.0 / 1080.0) * Double(mosaicPixels)))
        let totalHeight = mosaicPixels + footerHeight
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: mosaicPixels,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        let tileWidth = CGFloat(mosaicPixels) / CGFloat(max(1, project.gridWidth))
        let tileHeight = CGFloat(mosaicPixels) / CGFloat(max(1, project.gridHeight))
        let offsetY = CGFloat(footerHeight)

        var assetsByIdentifier: [String: PHAsset] = [:]
        if useHighQualityAssets {
            let identifiers = project.tiles.compactMap(\.placedPhotoIdentifier)
            let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            fetchedAssets.enumerateObjects { asset, _, _ in
                assetsByIdentifier[asset.localIdentifier] = asset
            }
        }

        for tile in project.tiles {
            autoreleasepool {
                let rect = CGRect(
                    x: CGFloat(tile.gridX) * tileWidth,
                    y: offsetY + CGFloat(project.gridHeight - tile.gridY - 1) * tileHeight,
                    width: tileWidth,
                    height: tileHeight
                )
                context.setFillColor(tile.targetLabColor.uiColor.cgColor)
                context.fill(rect)
            }

            let tileImage: UIImage?
            if useHighQualityAssets,
               let identifier = tile.placedPhotoIdentifier,
               let asset = assetsByIdentifier[identifier] {
                tileImage = await requestHighQualityImage(for: asset, targetPixels: isPro ? 256 : 128)
            } else if let data = tile.thumbnailData {
                tileImage = UIImage(data: data)
            } else {
                tileImage = nil
            }

            if let tileImage {
                autoreleasepool {
                    let normalized = ImageUtils.normalizeOrientationAndFit(image: tileImage, maxDimension: isPro ? 512 : 256)
                    guard let cgImage = normalized.cgImage else { return }
                    let rect = CGRect(
                        x: CGFloat(tile.gridX) * tileWidth,
                        y: offsetY + CGFloat(project.gridHeight - tile.gridY - 1) * tileHeight,
                        width: tileWidth,
                        height: tileHeight
                    )
                    let drawRect = ImageUtils.aspectFillRect(
                        imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                        destinationRect: rect
                    )
                    context.saveGState()
                    context.clip(to: rect)
                    context.draw(cgImage, in: drawRect)
                    context.restoreGState()
                }
            }
        }

        if !isPro && footerHeight > 0 {
            autoreleasepool {
                let footerRect = CGRect(x: 0, y: 0, width: mosaicPixels, height: footerHeight)
                context.setFillColor(UIColor(white: 0.12, alpha: 1.0).cgColor)
                context.fill(footerRect)
            }
        }

        guard let finalCGImage = context.makeImage() else { return nil }
        var resultImage = UIImage(cgImage: finalCGImage)
        
        if !isPro && footerHeight > 0 {
            let renderer = UIGraphicsImageRenderer(size: resultImage.size)
            resultImage = renderer.image { _ in
                resultImage.draw(at: .zero)
                let text = String(localized: "export.watermark.madeWith", defaultValue: "Made with 誰でモザイクアート")
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 18, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85)
                ]
                let textSize = (text as NSString).size(withAttributes: attributes)
                let textRect = CGRect(
                    x: (CGFloat(mosaicPixels) - textSize.width) / 2.0,
                    y: CGFloat(mosaicPixels) + (CGFloat(footerHeight) - textSize.height) / 2.0,
                    width: textSize.width,
                    height: textSize.height
                )
                (text as NSString).draw(in: textRect, withAttributes: attributes)
            }
        }

        return resultImage
    }

    // MARK: - 4K高解像度テキスト刻印描画 (最大2行の確実な保証)
    private static func renderWatermarkOnImage(baseImage: UIImage, config: WatermarkConfig) async -> UIImage {
        return await Task.detached(priority: .userInitiated) {
            let renderer = UIGraphicsImageRenderer(size: baseImage.size)
            return renderer.image { ctx in
                baseImage.draw(at: .zero)
                
                let width = baseImage.size.width
                let height = baseImage.size.height
                let text = sanitizeWatermarkText(config.text)
                
                let fontSize: CGFloat = width * 0.024 // 4096pxに対して約98ptの高精細文字
                let font: UIFont
                switch config.fontDesign {
                case .standard:
                    font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
                case .serif:
                    if let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .medium).fontDescriptor.withDesign(.serif) {
                        font = UIFont(descriptor: descriptor, size: fontSize)
                    } else {
                        font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
                    }
                case .monospaced:
                    if let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .medium).fontDescriptor.withDesign(.monospaced) {
                        font = UIFont(descriptor: descriptor, size: fontSize)
                    } else {
                        font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
                    }
                case .rounded:
                    if let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .medium).fontDescriptor.withDesign(.rounded) {
                        font = UIFont(descriptor: descriptor, size: fontSize)
                    } else {
                        font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
                    }
                }
                
                let textColor: UIColor
                switch config.colorStyle {
                case .whiteWithShadow:
                    textColor = UIColor.white
                case .blackWithShadow:
                    textColor = UIColor.black
                case .gold:
                    textColor = UIColor(red: 0.95, green: 0.80, blue: 0.40, alpha: 1.0)
                }
                
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
                shadow.shadowOffset = CGSize(width: 2, height: 2)
                shadow.shadowBlurRadius = 4
                
                let paragraphStyle = NSMutableParagraphStyle()
                switch config.position {
                case .bottomRight:
                    paragraphStyle.alignment = .right
                case .bottomLeft:
                    paragraphStyle.alignment = .left
                case .bottomCenter, .footerBar:
                    paragraphStyle.alignment = .center
                }
                paragraphStyle.lineBreakMode = .byTruncatingTail
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                    .shadow: shadow,
                    .paragraphStyle: paragraphStyle
                ]
                
                let margin: CGFloat = width * 0.03 // 端から約120px
                let maxTextWidth = width - (margin * 2)
                let textRectBounding = (text as NSString).boundingRect(
                    with: CGSize(width: maxTextWidth, height: fontSize * 2.6), // 最大2行分の高さに制限
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
                
                let textRect: CGRect
                switch config.position {
                case .footerBar:
                    let barHeight: CGFloat = textRectBounding.height + margin * 1.5
                    let barRect = CGRect(x: 0, y: height - barHeight, width: width, height: barHeight)
                    ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
                    ctx.cgContext.fill(barRect)
                    
                    textRect = CGRect(
                        x: (width - textRectBounding.width) / 2,
                        y: height - barHeight + (barHeight - textRectBounding.height) / 2,
                        width: textRectBounding.width,
                        height: textRectBounding.height
                    )
                    
                case .bottomRight:
                    textRect = CGRect(
                        x: width - margin - textRectBounding.width,
                        y: height - margin - textRectBounding.height,
                        width: textRectBounding.width,
                        height: textRectBounding.height
                    )
                    
                case .bottomLeft:
                    textRect = CGRect(
                        x: margin,
                        y: height - margin - textRectBounding.height,
                        width: textRectBounding.width,
                        height: textRectBounding.height
                    )
                    
                case .bottomCenter:
                    textRect = CGRect(
                        x: (width - textRectBounding.width) / 2,
                        y: height - margin - textRectBounding.height,
                        width: textRectBounding.width,
                        height: textRectBounding.height
                    )
                }
                
                (text as NSString).draw(in: textRect, withAttributes: attributes)
            }
        }.value
    }

    private static func requestHighQualityImage(for asset: PHAsset, targetPixels: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            let gate = ImageRequestContinuationGate(continuation)

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetPixels, height: targetPixels),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    gate.resume(with: nil)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                gate.resume(with: image)
            }
        }
    }
    
    // MARK: - フォント＆カラースタイル補助
    private func fontForDesign(_ design: WatermarkConfig.FontDesignOption, size: CGFloat) -> Font {
        switch design {
        case .standard: return .system(size: size, weight: .medium)
        case .serif: return .system(size: size, weight: .medium, design: .serif)
        case .monospaced: return .system(size: size, weight: .medium, design: .monospaced)
        case .rounded: return .system(size: size, weight: .medium, design: .rounded)
        }
    }
    
    private func textColorForStyle(_ style: WatermarkConfig.ColorStyleOption) -> Color {
        switch style {
        case .whiteWithShadow: return .white
        case .blackWithShadow: return .black
        case .gold: return Color(red: 0.95, green: 0.80, blue: 0.40)
        }
    }
}

private struct MosaicImageShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

#if canImport(UIKit)
private struct MosaicImageActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

/// 刻印テキストの文字数（最大60文字）および行数（最大2行）制限
private func sanitizeWatermarkText(_ rawText: String) -> String {
    let lines = rawText.components(separatedBy: "\n")
    let limitedLines = lines.prefix(2) // 最大2行
    let joined = limitedLines.joined(separator: "\n")
    if joined.count > 60 {
        return String(joined.prefix(60))
    }
    return joined
}

private final class ImageRequestContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(returning: image)
    }
}
