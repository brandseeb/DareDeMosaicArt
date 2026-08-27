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

    /// 画像を正方形アスペクトフィルに正規化し、多段階空間色・48×48 Sobel勾配ヒストグラム・明暗重心・面積比率を抽出する。
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
        
        // 1. アスペクト比を維持した中央正方形フィル（Aspect-Fill）で 48×48 に描画
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let maxSide = max(imgW, imgH)
        let scale = CGFloat(sampleSize) / min(imgW, imgH) // 短辺を sampleSize に合わせる
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawX = (CGFloat(sampleSize) - drawW) / 2.0
        let drawY = (CGFloat(sampleSize) - drawH) / 2.0
        
        context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        
        // 2. 各ピクセル (48×48) の Lab 変換と明度・色彩バッファ
        var lumMap = [Float](repeating: 0, count: sampleSize * sampleSize)
        var labMap = [LabColor](repeating: LabColor(l: 50, a: 0, b: 0), count: sampleSize * sampleSize)
        
        var totalR: Float = 0, totalG: Float = 0, totalB: Float = 0
        let totalPixels = Float(sampleSize * sampleSize)
        
        // 3×3 (16×16 px) 用アキュムレータ
        var cell3x3R = [Float](repeating: 0, count: 9)
        var cell3x3G = [Float](repeating: 0, count: 9)
        var cell3x3B = [Float](repeating: 0, count: 9)
        var cell3x3Count = [Float](repeating: 0, count: 9)
        
        // 6×6 (8×8 px) 用アキュムレータ
        var cell6x6R = [Float](repeating: 0, count: 36)
        var cell6x6G = [Float](repeating: 0, count: 36)
        var cell6x6B = [Float](repeating: 0, count: 36)
        var cell6x6Count = [Float](repeating: 0, count: 36)
        
        // 連続重み明暗重心用アキュムレータ
        var darkWeightSum: Float = 0
        var darkWeightedX: Float = 0
        var darkWeightedY: Float = 0
        
        var brightWeightSum: Float = 0
        var brightWeightedX: Float = 0
        var brightWeightedY: Float = 0
        
        for y in 0..<sampleSize {
            let normY = (Float(y) - 23.5) / 23.5 // [-1.0, 1.0]
            let c3Y = min(2, y / 16)
            let c6Y = min(5, y / 8)
            
            for x in 0..<sampleSize {
                let normX = (Float(x) - 23.5) / 23.5 // [-1.0, 1.0]
                let c3X = min(2, x / 16)
                let c6X = min(5, x / 8)
                
                let idx = y * sampleSize + x
                let offset = idx * 4
                let r = Float(rawData[offset]) / 255.0
                let g = Float(rawData[offset + 1]) / 255.0
                let b = Float(rawData[offset + 2]) / 255.0
                
                totalR += r
                totalG += g
                totalB += b
                
                let c3Idx = c3Y * 3 + c3X
                cell3x3R[c3Idx] += r
                cell3x3G[c3Idx] += g
                cell3x3B[c3Idx] += b
                cell3x3Count[c3Idx] += 1
                
                let c6Idx = c6Y * 6 + c6X
                cell6x6R[c6Idx] += r
                cell6x6G[c6Idx] += g
                cell6x6B[c6Idx] += b
                cell6x6Count[c6Idx] += 1
                
                let lab = LabColor.fromRGB(red: r, green: g, blue: b)
                labMap[idx] = lab
                let lum = lab.l
                lumMap[idx] = lum
                
                // 連続重み重心計算
                let darkW = max(0.0, (50.0 - lum) / 50.0)
                if darkW > 0 {
                    darkWeightSum += darkW
                    darkWeightedX += normX * darkW
                    darkWeightedY += normY * darkW
                }
                
                let brightW = max(0.0, (lum - 50.0) / 50.0)
                if brightW > 0 {
                    brightWeightSum += brightW
                    brightWeightedX += normX * brightW
                    brightWeightedY += normY * brightW
                }
            }
        }
        
        let avgR = totalR / totalPixels
        let avgG = totalG / totalPixels
        let avgB = totalB / totalPixels
        let average = LabColor.fromRGB(red: avgR, green: avgG, blue: avgB)
        
        let cells3x3 = (0..<9).map { index -> LabColor in
            let count = max(1, cell3x3Count[index])
            return LabColor.fromRGB(red: cell3x3R[index] / count, green: cell3x3G[index] / count, blue: cell3x3B[index] / count)
        }
        
        let cells6x6 = (0..<36).map { index -> LabColor in
            let count = max(1, cell6x6Count[index])
            return LabColor.fromRGB(red: cell6x6R[index] / count, green: cell6x6G[index] / count, blue: cell6x6B[index] / count)
        }
        
        // 3. 48×48 輝度への 3×3 Sobel 畳み込み & 6×6 領域への 8方向符号付きヒストグラム集約
        var rawGradientHistograms6x6 = Array(repeating: Array(repeating: Float(0), count: 8), count: 36)
        var rawGradientSum6x6 = [Float](repeating: 0, count: 36)
        
        func getLum(_ px: Int, _ py: Int) -> Float {
            let cx = max(0, min(sampleSize - 1, px))
            let cy = max(0, min(sampleSize - 1, py))
            return lumMap[cy * sampleSize + cx]
        }
        
        for y in 0..<sampleSize {
            let c6Y = min(5, y / 8)
            for x in 0..<sampleSize {
                let c6X = min(5, x / 8)
                let c6Idx = c6Y * 6 + c6X
                
                // Sobel カーネル適用
                let gx = getLum(x + 1, y - 1) + 2.0 * getLum(x + 1, y) + getLum(x + 1, y + 1)
                       - (getLum(x - 1, y - 1) + 2.0 * getLum(x - 1, y) + getLum(x - 1, y + 1))
                let gy = getLum(x - 1, y + 1) + 2.0 * getLum(x, y + 1) + getLum(x + 1, y + 1)
                       - (getLum(x - 1, y - 1) + 2.0 * getLum(x, y - 1) + getLum(x + 1, y - 1))
                
                let mag = sqrt(gx * gx + gy * gy)
                rawGradientSum6x6[c6Idx] += mag
                if mag > 0.001 {
                    var angle = atan2(gy, gx) // [-pi, pi]
                    if angle < 0 { angle += 2.0 * .pi } // [0, 2*pi)
                    let bin = Int(floor((angle / (2.0 * .pi)) * 8.0)) % 8
                    rawGradientHistograms6x6[c6Idx][bin] += mag
                }
            }
        }
        
        // 6×6 各セルの平均勾配強度 ([0.0, 1.0]) & L1正規化ヒストグラム
        var gradientMagnitudes6x6 = [Float](repeating: 0, count: 36)
        var gradientHistograms6x6 = Array(repeating: Array(repeating: Float(0), count: 8), count: 36)
        
        for c in 0..<36 {
            let cellPixelCount: Float = 64.0 // 8x8 px
            let meanMag = rawGradientSum6x6[c] / cellPixelCount
            // 理論最大勾配強度(~565)に対して実用上限を ~80.0 とし、[0, 1] に正規化
            gradientMagnitudes6x6[c] = max(0.0, min(1.0, meanMag / 80.0))
            
            let sum = rawGradientHistograms6x6[c].reduce(0, +)
            if sum > 0.0001 {
                gradientHistograms6x6[c] = rawGradientHistograms6x6[c].map { $0 / sum }
            } else {
                gradientHistograms6x6[c] = Array(repeating: 0.0, count: 8)
            }
        }
        
        // 4. 重心と信頼度
        let darkCoM: (x: Float, y: Float)
        let darkConf: Float
        if darkWeightSum > 0.001 {
            darkCoM = (x: darkWeightedX / darkWeightSum, y: darkWeightedY / darkWeightSum)
            darkConf = min(1.0, darkWeightSum / (totalPixels * 0.20))
        } else {
            darkCoM = (0, 0)
            darkConf = 0
        }
        
        let brightCoM: (x: Float, y: Float)
        let brightConf: Float
        if brightWeightSum > 0.001 {
            brightCoM = (x: brightWeightedX / brightWeightSum, y: brightWeightedY / brightWeightSum)
            brightConf = min(1.0, brightWeightSum / (totalPixels * 0.20))
        } else {
            brightCoM = (0, 0)
            brightConf = 0
        }
        
        let darkRatio = darkWeightSum / totalPixels
        let brightRatio = brightWeightSum / totalPixels
        let midRatio = max(0.0, 1.0 - darkRatio - brightRatio)
        
        return SpatialColorSignature(
            version: 2,
            average: average,
            cells3x3: cells3x3,
            cells6x6: cells6x6,
            gradientHistograms6x6: gradientHistograms6x6,
            gradientMagnitudes6x6: gradientMagnitudes6x6,
            darkCenterOfMass: darkCoM,
            darkConfidence: darkConf,
            brightCenterOfMass: brightCoM,
            brightConfidence: brightConf,
            luminanceRatios: (dark: darkRatio, mid: midRatio, bright: brightRatio)
        )
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
    
    /// ターゲット画像を gridWidth × gridHeight マスに分割し、各マスの目標色（LabColor）と空間シグネチャを抽出
    public func sliceTargetImage(
        cgImage: CGImage,
        gridWidth: Int,
        gridHeight: Int,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [MosaicTile] {
        let imgWidth = cgImage.width
        let imgHeight = cgImage.height
        guard gridWidth > 0, gridHeight > 0 else { return [] }
        
        let totalTiles = gridWidth * gridHeight
        var tiles: [MosaicTile] = []
        tiles.reserveCapacity(totalTiles)
        
        var processedCount = 0
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
                
                processedCount += 1
                if let onProgress, processedCount % max(1, totalTiles / 50) == 0 || processedCount == totalTiles {
                    onProgress(processedCount, totalTiles)
                }
            }
        }
        
        return tiles
    }
}
