import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 人間の視覚知覚に近い CIELAB (L*, a*, b*) 色空間を表す構造体
public struct LabColor: Codable, Equatable, Hashable, Sendable {
    /// 明度 (Lightness): 0.0 (黒) 〜 100.0 (白)
    public let l: Float
    /// 緑〜赤の色相/彩度: -128.0 (緑) 〜 +127.0 (赤)
    public let a: Float
    /// 青〜黄の色相/彩度: -128.0 (青) 〜 +127.0 (黄)
    public let b: Float
    
    public init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }
    
    // MARK: - 色差計算 (Color Difference)
    
    /// CIELAB 色差 (ΔE76)
    /// 2.3以下: 人間の目で判別困難なほど近似
    /// 5.0以下: 近似色
    /// 10.0〜15.0: 同系統だが違いがわかる
    /// 20.0以上: まったく異なる色
    public func distance(to other: LabColor) -> Float {
        let dl = self.l - other.l
        let da = self.a - other.a
        let db = self.b - other.b
        return sqrt(dl * dl + da * da + db * db)
    }
    
    /// 色の一致度 (0.0 〜 1.0)
    /// maxDistance (通常 35.0 程度) で正規化
    public func matchRatio(to other: LabColor, maxDistance: Float = 35.0) -> Float {
        let dist = distance(to: other)
        if dist >= maxDistance { return 0.0 }
        return max(0.0, min(1.0, 1.0 - (dist / maxDistance)))
    }
    
    // MARK: - RGB / SwiftUI Color 変換
    
    /// RGB (0.0 〜 1.0) から CIELAB へ変換 (D65 標準光源)
    public static func fromRGB(red: Float, green: Float, blue: Float) -> LabColor {
        // 1. sRGB -> Linear RGB (ガンマ補正解除)
        func sRGBtoLinear(_ val: Float) -> Float {
            let clamped = max(0.0, min(1.0, val))
            return clamped > 0.04045 ? pow((clamped + 0.055) / 1.055, 2.4) : (clamped / 12.92)
        }
        
        let r = sRGBtoLinear(red)
        let g = sRGBtoLinear(green)
        let b = sRGBtoLinear(blue)
        
        // 2. Linear RGB -> CIE XYZ (D65)
        var x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        var y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        var z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
        
        // D65 standard reference white
        x /= 0.95047
        y /= 1.00000
        z /= 1.08883
        
        // 3. XYZ -> CIELAB
        func f(_ t: Float) -> Float {
            return t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)
        
        let l = (116.0 * fy) - 16.0
        let a = 500.0 * (fx - fy)
        let bVal = 200.0 * (fy - fz)
        
        return LabColor(l: l, a: a, b: bVal)
    }
    
    /// CIELAB から sRGB (0.0 〜 1.0) へ変換
    public func toRGB() -> (red: Float, green: Float, blue: Float) {
        // 1. Lab -> XYZ
        let fy = (l + 16.0) / 116.0
        let fx = (a / 500.0) + fy
        let fz = fy - (b / 200.0)
        
        func finv(_ t: Float) -> Float {
            let t3 = t * t * t
            return t3 > 0.008856 ? t3 : ((t - 16.0 / 116.0) / 7.787)
        }
        
        let x = finv(fx) * 0.95047
        let y = finv(fy) * 1.00000
        let z = finv(fz) * 1.08883
        
        // 2. XYZ -> Linear RGB
        let rLinear =  x * 3.2404542 - y * 1.5371385 - z * 0.4985314
        let gLinear = -x * 0.9692660 + y * 1.8760108 + z * 0.0415560
        let bLinear =  x * 0.0556434 - y * 0.2040259 + z * 1.0572252
        
        // 3. Linear RGB -> sRGB (ガンマ適用)
        func linearToSRGB(_ val: Float) -> Float {
            let clamped = max(0.0, min(1.0, val))
            return clamped > 0.0031308 ? (1.055 * pow(clamped, 1.0 / 2.4) - 0.055) : (12.92 * clamped)
        }
        
        return (
            red: linearToSRGB(rLinear),
            green: linearToSRGB(gLinear),
            blue: linearToSRGB(bLinear)
        )
    }
    
    /// SwiftUIのColor表現
    public var swiftUIColor: Color {
        let rgb = toRGB()
        return Color(red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue))
    }
    
    #if canImport(UIKit)
    /// UIKitのUIColor表現
    public var uiColor: UIColor {
        let rgb = toRGB()
        return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1.0)
    }
    #endif
    
    // MARK: - 人間向けの色名推定
    
    /// ユーザーフレンドリーな日本語の色名
    public var localizedName: String {
        // 明度極端
        if l < 15.0 { return "漆黒・ブラック" }
        if l > 90.0 && abs(a) < 8.0 && abs(b) < 8.0 { return "純白・ホワイト" }
        
        // 低彩度（グレー系）
        let chroma = sqrt(a * a + b * b)
        if chroma < 10.0 {
            if l < 40.0 { return "ダークグレー" }
            if l < 70.0 { return "グレー" }
            return "ライトグレー"
        }
        
        // 色相角度 (atan2(b, a))
        var angle = atan2(b, a) * 180.0 / Float.pi
        if angle < 0 { angle += 360.0 }
        
        let brightnessPrefix = l > 75.0 ? "明るい" : (l < 35.0 ? "濃い" : "")
        
        let baseName: String
        switch angle {
        // CIELAB の色相角は sRGB の色相と同じ境界にはならない。
        // 代表的な sRGB 原色が自然な日本語名に入るよう調整している。
        case 15..<55:
            baseName = "レッド・赤"
        case 55..<85:
            baseName = "オレンジ・橙"
        case 85..<115:
            baseName = "イエロー・黄"
        case 115..<175:
            baseName = "グリーン・緑"
        case 175..<235:
            baseName = "シアン・水色"
        case 235..<315:
            baseName = "ブルー・青"
        case 315..<345:
            baseName = "パープル・紫"
        default:
            baseName = "マゼンタ・ピンク"
        }
        
        return brightnessPrefix.isEmpty ? baseName : "\(brightnessPrefix)\(baseName)"
    }
}

/// 画像内の色の「場所」まで表現する 3×3 空間色特徴。
public struct SpatialColorSignature: Codable, Equatable, Hashable, Sendable {
    public static let cellCount = 9

    public let average: LabColor
    /// 左上から右下への行優先順で並ぶ9色。
    public let cells: [LabColor]
    /// 9セルの L* の標準偏差。
    public let contrast: Float

    public init(average: LabColor, cells: [LabColor], contrast: Float? = nil) {
        self.average = average
        if cells.count == Self.cellCount {
            self.cells = cells
        } else {
            self.cells = Array(cells.prefix(Self.cellCount))
                + Array(repeating: average, count: max(0, Self.cellCount - cells.count))
        }

        if let contrast {
            self.contrast = max(0, contrast)
        } else {
            let mean = self.cells.map(\.l).reduce(0, +) / Float(Self.cellCount)
            let variance = self.cells.reduce(Float.zero) { partial, color in
                let delta = color.l - mean
                return partial + delta * delta
            } / Float(Self.cellCount)
            self.contrast = sqrt(variance)
        }
    }

    /// 平均色、同じ位置の9色、コントラストを統合した距離。
    public func distance(to other: SpatialColorSignature) -> Float {
        let averageDistance = average.distance(to: other.average)
        let spatialDistance = zip(cells, other.cells)
            .reduce(Float.zero) { $0 + $1.0.distance(to: $1.1) }
            / Float(Self.cellCount)
        let contrastDistance = abs(contrast - other.contrast)
        return averageDistance * 0.25 + spatialDistance * 0.65 + contrastDistance * 0.10
    }

    public func matchRatio(to other: SpatialColorSignature, maxDistance: Float = 35) -> Float {
        let value = 1 - distance(to: other) / maxDistance
        return max(0, min(1, value))
    }
}
