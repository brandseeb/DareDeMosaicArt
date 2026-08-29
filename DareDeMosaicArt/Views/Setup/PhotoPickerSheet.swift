import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit

/// iCloud写真や大容量写真も100%確実に取得する堅牢なPHPickerViewControllerラッパー
public struct PhotoPickerSheet: UIViewControllerRepresentable {
    public let onImageSelected: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    public init(onImageSelected: @escaping (UIImage) -> Void) {
        self.onImageSelected = onImageSelected
    }
    
    public func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    public func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(onImageSelected: onImageSelected)
    }
    
    public class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImageSelected: (UIImage) -> Void
        private var loadingView: UIView?
        
        init(onImageSelected: @escaping (UIImage) -> Void) {
            self.onImageSelected = onImageSelected
        }
        
        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                picker.dismiss(animated: true)
                return
            }
            
            // ローディング表示（iCloudダウンロード等の待機中に画面が白く固まったように見えないよう表示）
            showLoadingIndicator(in: picker.view)
            
            Task {
                if let image = await self.fetchImage(from: result) {
                    await MainActor.run {
                        let processedImage = ImageUtils.cropSquare(image: image, targetDimension: 800) ?? image
                        self.onImageSelected(processedImage)
                        picker.dismiss(animated: true)
                    }
                } else {
                    await MainActor.run {
                        self.hideLoadingIndicator()
                        picker.dismiss(animated: true)
                    }
                }
            }
        }
        
        /// 多重フォールバックでiCloud・HEIC・RAW等の写真データを確実に取得
        private func fetchImage(from result: PHPickerResult) async -> UIImage? {
            // 経路 1: PHAsset から直接取得（iCloud写真も自動ダウンロード、最も高速かつ確実）
            if let assetID = result.assetIdentifier {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                if let asset = fetchResult.firstObject {
                    if let image = await fetchImageFromPHAsset(asset) {
                        return image
                    }
                }
            }
            
            // 経路 2: NSItemProvider から DataRepresentation 経由で取得
            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let image = await fetchImageFromItemProviderData(provider) {
                    return image
                }
            }
            
            // 経路 3: 従来の loadObject フォールバック
            if provider.canLoadObject(ofClass: UIImage.self) {
                if let image = await fetchImageFromItemProviderObject(provider) {
                    return image
                }
            }
            
            return nil
        }
        
        private func fetchImageFromPHAsset(_ asset: PHAsset) async -> UIImage? {
            await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.isSynchronous = false
                
                // ターゲットサイズ（800px四方のモザイク原画用）
                let targetSize = CGSize(width: 1200, height: 1200)
                
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded {
                        continuation.resume(returning: image)
                    }
                }
            }
        }
        
        private func fetchImageFromItemProviderData(_ provider: NSItemProvider) async -> UIImage? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, let image = UIImage(data: data) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: image)
                }
            }
        }
        
        private func fetchImageFromItemProviderObject(_ provider: NSItemProvider) async -> UIImage? {
            await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
        
        private func showLoadingIndicator(in view: UIView) {
            let container = UIView(frame: view.bounds)
            container.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            
            let box = UIView()
            box.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
            box.layer.cornerRadius = 16
            box.translatesAutoresizingMaskIntoConstraints = false
            
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            
            let label = UILabel()
            label.text = String(localized: "picker.loadingPhoto")
            label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            label.textColor = UIColor.label
            label.translatesAutoresizingMaskIntoConstraints = false
            
            box.addSubview(spinner)
            box.addSubview(label)
            container.addSubview(box)
            view.addSubview(container)
            
            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                box.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
                box.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
                
                spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
                
                label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -20)
            ])
            
            self.loadingView = container
        }
        
        private func hideLoadingIndicator() {
            loadingView?.removeFromSuperview()
            loadingView = nil
        }
    }
}
#endif
