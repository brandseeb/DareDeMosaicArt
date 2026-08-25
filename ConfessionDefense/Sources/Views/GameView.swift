import SwiftUI
import SpriteKit

public struct GameView: View {
    @StateObject private var gameManager = GameManager()
    @State private var scene: GameScene = {
        let sc = GameScene(size: CGSize(width: 390, height: 600))
        sc.scaleMode = .resizeFill
        return sc
    }()
    
    public init() {}
    
    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 上部 HUD
                GameHUDView(gameManager: gameManager)
                
                // ゲーム盤面 (SpriteKit)
                SpriteView(scene: scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        scene.gameManager = gameManager
                        scene.updateGridDisplay()
                    }
                    .onChange(of: gameManager.gameState) { _ in
                        scene.updateGridDisplay()
                    }
                
                // 下部 ツールバー
                GameToolbarView(gameManager: gameManager)
            }
            .edgesIgnoringSafeArea(.bottom)
            
            // 警告トースト（「先生に怒られるので、通路は残してください。」など）
            if let warning = gameManager.warningMessage {
                VStack {
                    Spacer()
                    Text("⚠️ \(warning)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(20)
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeInOut, value: gameManager.warningMessage)
            }
            
            // 登校イベントモーダル (3人から1人選択)
            if gameManager.gameState == .classmateArrival {
                ClassmateSelectionModal(gameManager: gameManager)
            }
            
            // レベルアップ3択強化モーダル
            if gameManager.gameState == .levelUpUpgrade {
                UpgradeModal(gameManager: gameManager)
            }
            
            // ゲームオーバー画面
            if gameManager.gameState == .gameOver {
                ZStack {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("💔 GAME OVER")
                            .font(.system(size: 28, weight: .black))
                            .foregroundColor(.pink)
                        
                        Text("マドンナが告白の嵐に耐えきれず、\n教室から逃げ出してしまいました…！")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                        
                        Button(action: {
                            gameManager.resetGame()
                        }) {
                            Text("もう一度やり直す")
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                    }
                    .padding(24)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(20)
                }
            }
        }
    }
}
