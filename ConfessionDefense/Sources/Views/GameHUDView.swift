import SwiftUI

public struct GameHUDView: View {
    @ObservedObject var gameManager: GameManager
    
    public var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                // マドンナのストレスゲージ
                HStack(spacing: 4) {
                    Text("👸 ストレス:")
                        .font(.system(size: 11, weight: .bold))
                    
                    HStack(spacing: 2) {
                        ForEach(0..<gameManager.maxStress, id: \.self) { i in
                            Text(i < gameManager.stressLevel ? "💔" : "♡")
                                .font(.system(size: 11))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.pink.opacity(0.15))
                .cornerRadius(8)
                
                Spacer()
                
                // 時刻とWAVE
                HStack(spacing: 8) {
                    Text("⏰ \(gameManager.schoolTimeText)")
                        .font(.system(size: 12, weight: .semibold))
                    
                    Text("WAVE \(gameManager.waveNumber)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                
                Spacer()
                
                // 倍速 & 一時停止
                HStack(spacing: 6) {
                    Button(action: {
                        gameManager.gameSpeed = (gameManager.gameSpeed == 1.0) ? 2.0 : 1.0
                    }) {
                        Text("\(Int(gameManager.gameSpeed))x")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 24)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    }
                    
                    Button(action: {
                        gameManager.isPaused.toggle()
                    }) {
                        Image(systemName: gameManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11))
                            .frame(width: 28, height: 24)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            
            // 友情ポイント & クラスレベルバー
            HStack(spacing: 8) {
                Text("🤝 Lv.\(gameManager.classLevel)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                
                ProgressView(value: Double(gameManager.friendshipPoints), total: Double(gameManager.nextLevelPoints))
                    .tint(.orange)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                
                Text("\(gameManager.friendshipPoints)/\(gameManager.nextLevelPoints)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 4)
        .background(Color(UIColor.systemBackground).opacity(0.95))
    }
}
