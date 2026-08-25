import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

/// 画像操作ユーティリティ（メモリ安全 & オリエンテーション正規化）
public enum ImageUtils {
    
    #if canImport(UIKit)
    /// EXIFオリエンテーションを実際のピクセル配列として.upに焼き直す（正規化）
    public static func normalizeOrientation(image: UIImage) -> UIImage {
        return normalizeOrientationAndFit(image: image, maxDimension: 1024)
    }
    
    /// オリエンテーションを正規化し、メモリ節約のため最大解像度（maxDimension）に制限して安全に描画
    public static func normalizeOrientationAndFit(image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return image }
        
        let maxSide = max(originalSize.width, originalSize.height)
        let scale = maxSide > maxDimension ? (maxDimension / maxSide) : 1.0
        let targetSize = CGSize(
            width: max(1, originalSize.width * scale),
            height: max(1, originalSize.height * scale)
        )
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 1xスケールで無駄なメモリ消費を防止
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    /// 正方形に中央クロップ（最大800x800pxでメモリ安全に生成）
    public static func cropSquare(image: UIImage, targetDimension: CGFloat = 800) -> UIImage? {
        let normalized = normalizeOrientationAndFit(image: image, maxDimension: 1200)
        let size = normalized.size
        let minDimension = min(size.width, size.height)
        guard minDimension > 0 else { return nil }
        
        let cropRect = CGRect(
            x: (size.width - minDimension) / 2.0,
            y: (size.height - minDimension) / 2.0,
            width: minDimension,
            height: minDimension
        )
        
        let outputSize = CGSize(width: min(targetDimension, minDimension), height: min(targetDimension, minDimension))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        
        return renderer.image { _ in
            let scaleFactor = outputSize.width / minDimension
            let drawRect = CGRect(
                x: -cropRect.origin.x * scaleFactor,
                y: -cropRect.origin.y * scaleFactor,
                width: size.width * scaleFactor,
                height: size.height * scaleFactor
            )
            normalized.draw(in: drawRect)
        }
    }
    
    /// UIImageをリサイズしてサムネイルを生成
    public static func resize(image: UIImage, targetSize: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    /// 画像の中央領域（ROI）をクロップ
    public static func cropCenter(image: UIImage, ratio: CGFloat = 0.5) -> UIImage? {
        let normalized = normalizeOrientationAndFit(image: image, maxDimension: 800)
        let size = normalized.size
        let cropW = size.width * ratio
        let cropH = size.height * ratio
        let originX = (size.width - cropW) / 2.0
        let originY = (size.height - cropH) / 2.0
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cropW, height: cropH), format: format)
        return renderer.image { _ in
            normalized.draw(at: CGPoint(x: -originX, y: -originY))
        }
    }

    /// 中央レティクルと同じ正方形領域をクロップする。
    public static func cropCenterSquare(image: UIImage, ratio: CGFloat = 0.25, maxDimension: CGFloat = 512) -> UIImage? {
        let normalized = normalizeOrientationAndFit(image: image, maxDimension: max(1024, maxDimension * 4))
        let size = normalized.size
        let side = min(size.width, size.height) * max(0.05, min(1, ratio))
        guard side > 0 else { return nil }

        let outputSide = min(maxDimension, side)
        let scaleFactor = outputSide / side
        let originX = (size.width - side) / 2
        let originY = (size.height - side) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        return renderer.image { _ in
            normalized.draw(in: CGRect(
                x: -originX * scaleFactor,
                y: -originY * scaleFactor,
                width: size.width * scaleFactor,
                height: size.height * scaleFactor
            ))
        }
    }
    #endif
}
