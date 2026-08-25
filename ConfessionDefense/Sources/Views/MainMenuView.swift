import SwiftUI

public struct MainMenuView: View {
    @State private var isPlaying: Bool = false
    
    public init() {}
    
    public var body: some View {
        if isPlaying {
            GameView()
        } else {
            ZStack {
                // 背景グラデーション（教室・黒板風）
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.35, blue: 0.22),
                        Color(red: 0.08, green: 0.25, blue: 0.16)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    Spacer()
                    
                    // タイトルロゴ
                    VStack(spacing: 8) {
                        Text("🏫 2年B組 防衛戦")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.yellow)
                            .tracking(2)
                        
                        Text("告白お断りします！")
                            .font(.system(size: 32, weight: .black))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
                        
                        Text("〜 朝は二人だった。放課後には、全員が彼女の味方だった 〜")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.85))
                            .padding(.top, 4)
                    }
                    
                    // キャラクターイメージプレビュー
                    HStack(spacing: 12) {
                        Text("🏃‍♂️💨")
                            .font(.system(size: 36))
                        Text("➡️")
                            .font(.system(size: 20))
                            .foregroundColor(.yellow)
                        Text("🪑")
                            .font(.system(size: 36))
                        Text("👓")
                            .font(.system(size: 36))
                        Text("👸")
                            .font(.system(size: 42))
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 24)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(16)
                    
                    Spacer()
                    
                    // ゲーム開始ボタン
                    VStack(spacing: 14) {
                        Button(action: {
                            isPlaying = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("登校して守る！ (START)")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.yellow)
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                        }
                        
                        Text("iPhone 縦持ち専用 / タワーディフェンス × 迷路作成")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.7))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
                }
            }
        }
    }
}
