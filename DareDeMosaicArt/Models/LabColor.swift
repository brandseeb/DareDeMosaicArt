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

/// 画像内の色の「場所・グラデーション・明暗重心・8方向エッジ配向」まで表現する多段階空間色特徴。
public struct SpatialColorSignature: Codable, Equatable, Hashable, Sendable {
    public static let cellCountV1 = 9
    public static let cellCountV2 = 36
    public static let gradientBinCount = 8

    public let version: Int
    public let average: LabColor
    public let cells3x3: [LabColor]
    public let cells6x6: [LabColor]
    /// 6×6 各セルの 8方向 (0°〜360°, 45°刻み) L1正規化勾配ヒストグラム（各セル合計 1.0 または 0.0）
    public let gradientHistograms6x6: [[Float]]
    /// 6×6 各セルの正規化平均勾配強度 ([0.0, 1.0])
    public let gradientMagnitudes6x6: [Float]
    /// 暗部重心 ([-1.0, 1.0]) & 信頼度 (0.0〜1.0)
    public let darkCenterOfMassX: Float
    public let darkCenterOfMassY: Float
    public let darkConfidence: Float
    /// 明部重心 ([-1.0, 1.0]) & 信頼度 (0.0〜1.0)
    public let brightCenterOfMassX: Float
    public let brightCenterOfMassY: Float
    public let brightConfidence: Float
    /// 明暗比率 (dark, mid, bright: 合計 1.0)
    public let darkRatio: Float
    public let midRatio: Float
    public let brightRatio: Float
    /// L* の標準偏差
    public let contrast: Float

    /// 既存コード互換用プロパティ（version 2 の場合は 6×6、version 1 の場合は 3×3 を返す）
    public var cells: [LabColor] {
        return (version >= 2 && cells6x6.count == Self.cellCountV2) ? cells6x6 : cells3x3
    }

    public init(
        version: Int = 2,
        average: LabColor,
        cells3x3: [LabColor],
        cells6x6: [LabColor] = [],
        gradientHistograms6x6: [[Float]] = [],
        gradientMagnitudes6x6: [Float] = [],
        darkCenterOfMass: (x: Float, y: Float) = (0, 0),
        darkConfidence: Float = 0,
        brightCenterOfMass: (x: Float, y: Float) = (0, 0),
        brightConfidence: Float = 0,
        luminanceRatios: (dark: Float, mid: Float, bright: Float) = (0.33, 0.34, 0.33),
        contrast: Float? = nil
    ) {
        // 3×3 セルの安全な初期化
        let safe3x3: [LabColor]
        if cells3x3.count == Self.cellCountV1 {
            safe3x3 = cells3x3
        } else {
            safe3x3 = Array(cells3x3.prefix(Self.cellCountV1))
                + Array(repeating: average, count: max(0, Self.cellCountV1 - cells3x3.count))
        }
        self.cells3x3 = safe3x3
        self.average = average
        
        // 6×6 / 勾配データが完全か判定（各セルのヒストグラムが8要素揃っていない場合も偽の補間を行わず v1 へ降格）
        let isCompleteV2 = (version >= 2)
            && (cells6x6.count == Self.cellCountV2)
            && (gradientHistograms6x6.count == Self.cellCountV2)
            && (gradientMagnitudes6x6.count == Self.cellCountV2)
            && gradientHistograms6x6.allSatisfy { $0.count == Self.gradientBinCount }
        
        if isCompleteV2 {
            self.version = 2
            self.cells6x6 = cells6x6
            self.gradientMagnitudes6x6 = gradientMagnitudes6x6.map { max(0.0, min(1.0, $0)) }
            
            // 8方向ヒストグラムを L1 正規化（合計 1.0 または 0.0）
            self.gradientHistograms6x6 = gradientHistograms6x6.map { hist in
                let sum = hist.reduce(0, +)
                if sum > 0.0001 {
                    return hist.map { $0 / sum }
                } else {
                    return Array(repeating: 0.0, count: Self.gradientBinCount)
                }
            }
        } else {
            // 不完全なデータまたは旧データは v1 として扱う
            self.version = 1
            self.cells6x6 = []
            self.gradientHistograms6x6 = []
            self.gradientMagnitudes6x6 = []
        }
        
        self.darkCenterOfMassX = max(-1.0, min(1.0, darkCenterOfMass.x))
        self.darkCenterOfMassY = max(-1.0, min(1.0, darkCenterOfMass.y))
        self.darkConfidence = max(0.0, min(1.0, darkConfidence))
        
        self.brightCenterOfMassX = max(-1.0, min(1.0, brightCenterOfMass.x))
        self.brightCenterOfMassY = max(-1.0, min(1.0, brightCenterOfMass.y))
        self.brightConfidence = max(0.0, min(1.0, brightConfidence))
        
        self.darkRatio = max(0.0, min(1.0, luminanceRatios.dark))
        self.midRatio = max(0.0, min(1.0, luminanceRatios.mid))
        self.brightRatio = max(0.0, min(1.0, luminanceRatios.bright))
        
        if let contrast {
            self.contrast = max(0, contrast)
        } else {
            let activeCells = (self.version >= 2 && !self.cells6x6.isEmpty) ? self.cells6x6 : self.cells3x3
            let mean = activeCells.map(\.l).reduce(0, +) / Float(max(1, activeCells.count))
            let variance = activeCells.reduce(Float.zero) { partial, color in
                let delta = color.l - mean
                return partial + delta * delta
            } / Float(max(1, activeCells.count))
            self.contrast = sqrt(variance)
        }
    }
    
    // v1 互換イニシャライザ
    public init(average: LabColor, cells: [LabColor], contrast: Float? = nil) {
        self.init(
            version: 1,
            average: average,
            cells3x3: cells,
            cells6x6: [],
            gradientHistograms6x6: [],
            gradientMagnitudes6x6: [],
            contrast: contrast
        )
    }

    // MARK: - Codable (後方互換性明示デコード & 不完全v2の安全降格)
    
    private enum CodingKeys: String, CodingKey {
        case version
        case average
        case cells // v1 互換
        case cells3x3
        case cells6x6
        case gradientHistograms6x6
        case gradientMagnitudes6x6
        case darkCenterOfMassX
        case darkCenterOfMassY
        case darkConfidence
        case brightCenterOfMassX
        case brightCenterOfMassY
        case brightConfidence
        case darkRatio
        case midRatio
        case brightRatio
        case contrast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ver = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.average = try container.decode(LabColor.self, forKey: .average)
        
        let c3 = try container.decodeIfPresent([LabColor].self, forKey: .cells3x3)
            ?? container.decodeIfPresent([LabColor].self, forKey: .cells)
            ?? Array(repeating: self.average, count: Self.cellCountV1)
        if c3.count == Self.cellCountV1 {
            self.cells3x3 = c3
        } else {
            self.cells3x3 = Array(c3.prefix(Self.cellCountV1)) + Array(repeating: self.average, count: max(0, Self.cellCountV1 - c3.count))
        }
        
        let c6 = try container.decodeIfPresent([LabColor].self, forKey: .cells6x6) ?? []
        let gh = try container.decodeIfPresent([[Float]].self, forKey: .gradientHistograms6x6) ?? []
        let gm = try container.decodeIfPresent([Float].self, forKey: .gradientMagnitudes6x6) ?? []
        
        // 完全な 36 セル（かつ各ヒストグラムが厳密に 8 要素）ある場合のみ v2 として承認
        let isDecodedCompleteV2 = (ver >= 2)
            && (c6.count == Self.cellCountV2)
            && (gh.count == Self.cellCountV2)
            && (gm.count == Self.cellCountV2)
            && gh.allSatisfy { $0.count == Self.gradientBinCount }
        
        if isDecodedCompleteV2 {
            self.version = 2
            self.cells6x6 = c6
            self.gradientMagnitudes6x6 = gm.map { max(0.0, min(1.0, $0)) }
            self.gradientHistograms6x6 = gh.map { hist in
                let sum = hist.reduce(0, +)
                if sum > 0.0001 {
                    return hist.map { $0 / sum }
                } else {
                    return Array(repeating: 0.0, count: Self.gradientBinCount)
                }
            }
        } else {
            // 不完全な場合は v1 に降格
            self.version = 1
            self.cells6x6 = []
            self.gradientHistograms6x6 = []
            self.gradientMagnitudes6x6 = []
        }
        
        self.darkCenterOfMassX = try container.decodeIfPresent(Float.self, forKey: .darkCenterOfMassX) ?? 0.0
        self.darkCenterOfMassY = try container.decodeIfPresent(Float.self, forKey: .darkCenterOfMassY) ?? 0.0
        self.darkConfidence = try container.decodeIfPresent(Float.self, forKey: .darkConfidence) ?? 0.0
        
        self.brightCenterOfMassX = try container.decodeIfPresent(Float.self, forKey: .brightCenterOfMassX) ?? 0.0
        self.brightCenterOfMassY = try container.decodeIfPresent(Float.self, forKey: .brightCenterOfMassY) ?? 0.0
        self.brightConfidence = try container.decodeIfPresent(Float.self, forKey: .brightConfidence) ?? 0.0
        
        self.darkRatio = try container.decodeIfPresent(Float.self, forKey: .darkRatio) ?? 0.33
        self.midRatio = try container.decodeIfPresent(Float.self, forKey: .midRatio) ?? 0.34
        self.brightRatio = try container.decodeIfPresent(Float.self, forKey: .brightRatio) ?? 0.33
        
        let cnt = try container.decodeIfPresent(Float.self, forKey: .contrast)
        if let cnt {
            self.contrast = cnt
        } else {
            let mean = self.cells3x3.map(\.l).reduce(0, +) / Float(Self.cellCountV1)
            let variance = self.cells3x3.reduce(Float.zero) { partial, color in
                let delta = color.l - mean
                return partial + delta * delta
            } / Float(Self.cellCountV1)
            self.contrast = sqrt(variance)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(average, forKey: .average)
        try container.encode(cells3x3, forKey: .cells3x3)
        try container.encode(cells3x3, forKey: .cells) // v1 互換用
        try container.encode(cells6x6, forKey: .cells6x6)
        try container.encode(gradientHistograms6x6, forKey: .gradientHistograms6x6)
        try container.encode(gradientMagnitudes6x6, forKey: .gradientMagnitudes6x6)
        try container.encode(darkCenterOfMassX, forKey: .darkCenterOfMassX)
        try container.encode(darkCenterOfMassY, forKey: .darkCenterOfMassY)
        try container.encode(darkConfidence, forKey: .darkConfidence)
        try container.encode(brightCenterOfMassX, forKey: .brightCenterOfMassX)
        try container.encode(brightCenterOfMassY, forKey: .brightCenterOfMassY)
        try container.encode(brightConfidence, forKey: .brightConfidence)
        try container.encode(darkRatio, forKey: .darkRatio)
        try container.encode(midRatio, forKey: .midRatio)
        try container.encode(brightRatio, forKey: .brightRatio)
        try container.encode(contrast, forKey: .contrast)
    }

    // MARK: - [0, 1] 正規化距離計算

    /// 全体平均色、3×3/6×6空間色、8方向Sobel勾配、明暗面積比率、明暗重心を統合した [0, 1] 正規化距離。
    public func distance(to other: SpatialColorSignature) -> Float {
        // v1 同士 または 片方が v1 の場合は v1 距離を [0, 1] 正規化して返す
        if self.version < 2 || other.version < 2 || self.cells6x6.count != Self.cellCountV2 || other.cells6x6.count != Self.cellCountV2 {
            let avgDist = average.distance(to: other.average)
            let sCount = min(self.cells3x3.count, other.cells3x3.count)
            let spatialDist: Float
            if sCount > 0 {
                spatialDist = (0..<sCount).reduce(Float.zero) { $0 + self.cells3x3[$1].distance(to: other.cells3x3[$1]) } / Float(sCount)
            } else {
                spatialDist = avgDist
            }
            let contrastDist = abs(contrast - other.contrast)
            let rawV1 = avgDist * 0.25 + spatialDist * 0.65 + contrastDist * 0.10
            return max(0.0, min(1.0, rawV1 / 40.0))
        }

        // 1. 全体平均 Lab 色距離 (0〜1)
        let dAvg = max(0.0, min(1.0, average.distance(to: other.average) / 40.0))

        // 2. 多段階空間色距離 (3×3: 35%, 6×6: 65%) (0〜1)
        let d3x3Raw = (0..<Self.cellCountV1).reduce(Float.zero) { $0 + cells3x3[$1].distance(to: other.cells3x3[$1]) } / Float(Self.cellCountV1)
        let d6x6Raw = (0..<Self.cellCountV2).reduce(Float.zero) { $0 + cells6x6[$1].distance(to: other.cells6x6[$1]) } / Float(Self.cellCountV2)
        let dSpatial = max(0.0, min(1.0, (d3x3Raw * 0.35 + d6x6Raw * 0.65) / 40.0))

        // 3. 8方向 Sobel 勾配ヒストグラム & 強度距離 (0〜1)
        var gradientDistSum: Float = 0.0
        for c in 0..<Self.cellCountV2 {
            let magA = gradientMagnitudes6x6[c]
            let magB = other.gradientMagnitudes6x6[c]
            let magDiff = abs(magA - magB) // [0, 1]
            
            let hA = gradientHistograms6x6[c]
            let hB = other.gradientHistograms6x6[c]
            
            // 低勾配ゲート: 両方の強度が一定以上ある場合のみ方向差を評価
            let gate = min(1.0, min(magA, magB) / 0.15)
            var dirDiff: Float = 0.0
            if gate > 0.01 {
                // L1 正規化ヒストグラムのマンハッタン距離 / 2.0 -> [0, 1]
                var l1: Float = 0.0
                for b in 0..<Self.gradientBinCount {
                    l1 += abs(hA[b] - hB[b])
                }
                dirDiff = l1 * 0.5
            }
            
            let cellGradDist = magDiff * 0.4 + (dirDiff * gate + magDiff * (1.0 - gate)) * 0.6
            gradientDistSum += cellGradDist
        }
        let dGradient = max(0.0, min(1.0, gradientDistSum / Float(Self.cellCountV2)))

        // 4. 明暗面積比率距離 (0〜1)
        let dRatio = max(0.0, min(1.0, (abs(darkRatio - other.darkRatio) + abs(midRatio - other.midRatio) + abs(brightRatio - other.brightRatio)) / 2.0))

        // 5. 明暗重心距離 (0〜1)
        let darkDx = darkCenterOfMassX - other.darkCenterOfMassX
        let darkDy = darkCenterOfMassY - other.darkCenterOfMassY
        let darkDist = sqrt(darkDx * darkDx + darkDy * darkDy) / 2.8284 // 最大距離 2*sqrt(2) で正規化
        let darkGate = min(darkConfidence, other.darkConfidence)

        let brightDx = brightCenterOfMassX - other.brightCenterOfMassX
        let brightDy = brightCenterOfMassY - other.brightCenterOfMassY
        let brightDist = sqrt(brightDx * brightDx + brightDy * brightDy) / 2.8284
        let brightGate = min(brightConfidence, other.brightConfidence)

        let contrastDiff = max(0.0, min(1.0, abs(contrast - other.contrast) / 35.0))
        let comDistance = (darkDist * darkGate + brightDist * brightGate) / max(0.001, (darkGate + brightGate))
        let dCoM = max(0.0, min(1.0, comDistance * 0.7 + contrastDiff * 0.3))

        // 総合加重スコア: 全体平均色15% + 空間色45% + 勾配20% + 面積比率10% + 重心コントラスト10%
        let total = dAvg * 0.15 + dSpatial * 0.45 + dGradient * 0.20 + dRatio * 0.10 + dCoM * 0.10
        return max(0.0, min(1.0, total))
    }

    public func matchRatio(to other: SpatialColorSignature, maxDistance: Float = 0.38) -> Float {
        let value = 1.0 - distance(to: other) / maxDistance
        return max(0.0, min(1.0, value))
    }
}
