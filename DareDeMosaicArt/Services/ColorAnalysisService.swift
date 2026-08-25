import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

/// 画像の色分析サービス
public final class ColorAnalysisService: Sendable {
    public static let shared = ColorAnalysisService()
    
    public init() {}
    
    private let signatureSampleSize = 48

    // MARK: - 平均色・空間色シグネチャ抽出
    
    /// CGImage から代表色（CIELAB）を抽出
    public func extractAverageLabColor(from cgImage: CGImage) -> LabColor {
        extractSpatialSignature(from: cgImage).average
    }

    /// 画像を正方形に正規化し、左上から右下へ 3×3 の代表色を抽出する。
    public func extractSpatialSignature(from cgImage: CGImage) -> SpatialColorSignature {
        let sampleSize = signatureSampleSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        
        guard let context = CGContext(
            data: &rawData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            let fallback = LabColor(l: 50, a: 0, b: 0)
            return SpatialColorSignature(average: fallback, cells: Array(repeating: fallback, count: 9))
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        
        var cellR = [Float](repeating: 0, count: 9)
        var cellG = [Float](repeating: 0, count: 9)
        var cellB = [Float](repeating: 0, count: 9)
        var cellPixelCounts = [Float](repeating: 0, count: 9)
        var totalR: Float = 0, totalG: Float = 0, totalB: Float = 0
        let totalPixels = Float(sampleSize * sampleSize)
        
        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = (y * sampleSize + x) * 4
                let r = Float(rawData[offset]) / 255.0
                let g = Float(rawData[offset + 1]) / 255.0
                let b = Float(rawData[offset + 2]) / 255.0
                let cellX = min(2, x * 3 / sampleSize)
                let cellY = min(2, y * 3 / sampleSize)
                let cellIndex = cellY * 3 + cellX
                cellR[cellIndex] += r
                cellG[cellIndex] += g
                cellB[cellIndex] += b
                cellPixelCounts[cellIndex] += 1
                totalR += r
                totalG += g
                totalB += b
            }
        }
        
        let avgR = totalR / totalPixels
        let avgG = totalG / totalPixels
        let avgB = totalB / totalPixels
        
        let average = LabColor.fromRGB(red: avgR, green: avgG, blue: avgB)
        let cells = (0..<9).map { index -> LabColor in
            let count = max(1, cellPixelCounts[index])
            return LabColor.fromRGB(
                red: cellR[index] / count,
                green: cellG[index] / count,
                blue: cellB[index] / count
            )
        }
        return SpatialColorSignature(average: average, cells: cells)
    }
    
    #if canImport(UIKit)
    /// UIImage から代表色（CIELAB）を抽出（向きを正規化）
    public func extractAverageLabColor(from image: UIImage) -> LabColor {
        let normalized = ImageUtils.normalizeOrientation(image: image)
        guard let cgImage = normalized.cgImage else {
            return LabColor(l: 50, a: 0, b: 0)
        }
        return extractAverageLabColor(from: cgImage)
    }

    public func extractSpatialSignature(from image: UIImage) -> SpatialColorSignature {
        let normalized = ImageUtils.normalizeOrientation(image: image)
        guard let cgImage = normalized.cgImage else {
            let fallback = LabColor(l: 50, a: 0, b: 0)
            return SpatialColorSignature(average: fallback, cells: Array(repeating: fallback, count: 9))
        }
        return extractSpatialSignature(from: cgImage)
    }

    /// 画像中央の正方形 ROI。カメラのプレビューと静止画で共通使用する。
    public func extractCenterROISignature(from image: UIImage, ratio: CGFloat = 0.25) -> SpatialColorSignature? {
        guard let cropped = ImageUtils.cropCenterSquare(image: image, ratio: ratio),
              let cgImage = cropped.cgImage else { return nil }
        return extractSpatialSignature(from: cgImage)
    }
    #endif
    
    // MARK: - ターゲット画像のグリッド分割 & 各セルの代表色抽出
    
    /// ターゲット画像を gridWidth × gridHeight マスに分割し、各マスの目標色（LabColor）を抽出
    public func sliceTargetImage(
        cgImage: CGImage,
        gridWidth: Int,
        gridHeight: Int
    ) -> [MosaicTile] {
        let imgWidth = cgImage.width
        let imgHeight = cgImage.height
        guard gridWidth > 0, gridHeight > 0 else { return [] }
        
        var tiles: [MosaicTile] = []
        tiles.reserveCapacity(gridWidth * gridHeight)
        
        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                // 各境界を元画像に対する比率から求め、端数ピクセルも必ずどこかのマスに含める。
                let minX = x * imgWidth / gridWidth
                let maxX = (x + 1) * imgWidth / gridWidth
                let minY = y * imgHeight / gridHeight
                let maxY = (y + 1) * imgHeight / gridHeight
                let cropRect = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
                
                let signature: SpatialColorSignature
                if let croppedCg = cgImage.cropping(to: cropRect) {
                    signature = extractSpatialSignature(from: croppedCg)
                } else {
                    let fallback = LabColor(l: 50, a: 0, b: 0)
                    signature = SpatialColorSignature(average: fallback, cells: Array(repeating: fallback, count: 9))
                }
                
                let tile = MosaicTile(
                    gridX: x,
                    gridY: y,
                    targetLabColor: signature.average,
                    targetSignature: signature
                )
                tiles.append(tile)
            }
        }
        
        return tiles
    }
}
