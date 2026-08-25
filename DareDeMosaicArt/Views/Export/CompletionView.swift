import SwiftUI
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// 完成セレモニー & 高解像度エクスポート・共有画面
public struct CompletionView: View {
    public let project: MosaicProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeKit = StoreKitManager.shared
    
    @State private var renderedImage: UIImage? = nil
    @State private var isRendering: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var showPaywall: Bool = false
    
    public init(project: MosaicProject) {
        self.project = project
    }
    
    public var body: some View {
        NavigationStack {
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
                
                // レンダリングされたプレビュー画像
                ZStack {
                    if let img = renderedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(storeKit.isProUser ? "4K超高解像度アートを生成中..." : "モザイクアートを生成中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: 320)
                .padding(.horizontal)
                
                // 画質・Pro状態バッジ
                HStack(spacing: 6) {
                    if storeKit.isProUser {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                        Text("4K超高解像度 (4,096px) ＆ 透かしなし")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                    } else {
                        Text("標準画質 (1,080px)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button {
                            showPaywall = true
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "crown.fill")
                                Text("Proで4K保存")
                            }
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // アクションボタン
                VStack(spacing: 12) {
                    if let img = renderedImage {
                        ShareLink(
                            item: Image(uiImage: img),
                            preview: SharePreview(project.title, image: Image(uiImage: img))
                        ) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("SNSや友達にシェアする")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .cornerRadius(12)
                        }
                        
                        Button {
                            saveToPhotosAlbum(image: img)
                        } label: {
                            HStack {
                                Image(systemName: saveSuccess ? "checkmark.circle.fill" : "arrow.down.to.line")
                                Text(saveSuccess ? "カメラロールに保存しました！" : "カメラロールに保存")
                            }
                            .font(.headline)
                            .foregroundColor(saveSuccess ? .green : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .disabled(saveSuccess)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
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
            .onAppear {
                renderFullMosaicImage()
            }
            .onChange(of: storeKit.isProUser) { _, isPro in
                // Pro状態が変化した場合は再レンダリング
                renderedImage = nil
                renderFullMosaicImage()
            }
        }
    }
    
    // MARK: - モザイク画像のレンダリング
    private func renderFullMosaicImage() {
        guard renderedImage == nil else { return }
        isRendering = true
        let isPro = storeKit.isProUser
        
        Task.detached(priority: .userInitiated) {
            let finalImage = await Self.renderMosaicImage(project: project, isPro: isPro)
            
            await MainActor.run {
                self.renderedImage = finalImage
                self.isRendering = false
            }
        }
    }

    /// PHAsset 原画を1枚ずつ取得し、メモリを圧迫せずにビットマップへ直接合成する。
    /// 無料版: 1,080px ＋ 下部余白フッター（作品本体には被せない）
    /// Pro版: 4,096px 4K ＋ 余白なし純粋アート
    private static func renderMosaicImage(project: MosaicProject, isPro: Bool) async -> UIImage? {
        let mosaicPixels = isPro ? 4096 : 1080
        let footerHeight = isPro ? 0 : 54 // 無料版は下部に54pxの控えめなフッター余白
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
        let offsetY = CGFloat(footerHeight) // フッター分上にシフト

        let identifiers = project.tiles.compactMap(\.placedPhotoIdentifier)
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        // 1. 各タイルの描画
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
            if let identifier = tile.placedPhotoIdentifier,
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
                    let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
                    let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                    let drawRect = CGRect(
                        x: rect.midX - drawSize.width / 2,
                        y: rect.midY - drawSize.height / 2,
                        width: drawSize.width,
                        height: drawSize.height
                    )
                    context.saveGState()
                    context.clip(to: rect)
                    context.draw(cgImage, in: drawRect)
                    context.restoreGState()
                }
            }
        }

        // 2. 無料版の場合、下部フッターに控えめな署名を印字（作品本体には被せない）
        if !isPro && footerHeight > 0 {
            autoreleasepool {
                // フッター背景（濃いダークグレー）
                let footerRect = CGRect(x: 0, y: 0, width: mosaicPixels, height: footerHeight)
                context.setFillColor(UIColor(white: 0.12, alpha: 1.0).cgColor)
                context.fill(footerRect)
            }
        }

        guard let finalCGImage = context.makeImage() else { return nil }
        var resultImage = UIImage(cgImage: finalCGImage)
        
        // 無料版の場合、UIKitでフッターテキストを描画
        if !isPro && footerHeight > 0 {
            let renderer = UIGraphicsImageRenderer(size: resultImage.size)
            resultImage = renderer.image { ctx in
                resultImage.draw(at: .zero)
                
                let text = "Made with 誰でモザイクアート"
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
    
    private func saveToPhotosAlbum(image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation {
            self.saveSuccess = true
        }
    }
}

/// PhotoKit が複数回コールバックしても continuation を1回だけ完了させる。
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
