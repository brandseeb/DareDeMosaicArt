import SwiftUI
import PhotosUI

#if canImport(UIKit)
import UIKit

/// クラッシュ知らずの安全なPHPickerViewControllerラッパー
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
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    public func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerSheet
        
        init(_ parent: PhotoPickerSheet) {
            self.parent = parent
        }
        
        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                return
            }
            
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                guard let self = self, let rawImage = object as? UIImage else { return }
                
                // メインスレッドで安全にクロップ & コールバック
                DispatchQueue.main.async {
                    if let square = ImageUtils.cropSquare(image: rawImage, targetDimension: 800) {
                        self.parent.onImageSelected(square)
                    } else {
                        self.parent.onImageSelected(rawImage)
                    }
                }
            }
        }
    }
}
#endif
