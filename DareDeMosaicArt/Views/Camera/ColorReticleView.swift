import SwiftUI

/// カメラファインダー中央のターゲット色照合レティクル
public struct ColorReticleView: View {
    public let targetColor: LabColor
    public let currentColor: LabColor
    public let matchRatio: Float
    public let isPass: Bool
    
    public init(
        targetColor: LabColor,
        currentColor: LabColor,
        matchRatio: Float,
        isPass: Bool
    ) {
        self.targetColor = targetColor
        self.currentColor = currentColor
        self.matchRatio = matchRatio
        self.isPass = isPass
    }
    
    public var body: some View {
        ZStack {
            // 外枠リング（一致度に応じて色が変化）
            Circle()
                .stroke(
                    isPass ? Color.green : Color.white.opacity(0.6),
                    style: StrokeStyle(lineWidth: isPass ? 6 : 3, dash: isPass ? [] : [6, 6])
                )
                .frame(width: 140, height: 140)
                .scaleEffect(isPass ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPass)
            
            // 中央色比較サークル
            HStack(spacing: 0) {
                // 左半分: 探している目標色
                targetColor.swiftUIColor
                    .frame(width: 45, height: 90)
                
                // 右半分: いまカメラに映っている色
                currentColor.swiftUIColor
                    .frame(width: 45, height: 90)
            }
            .clipShape(Circle())
            .overlay(
                Circle().stroke(Color.white, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            
            // ラベル
            VStack {
                Spacer()
                Text(isPass ? "✨ OK! シャッターを切ろう！" : "色を近づけてね")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isPass ? .green : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                    .offset(y: 90)
            }
        }
        .frame(width: 180, height: 180)
    }
}
