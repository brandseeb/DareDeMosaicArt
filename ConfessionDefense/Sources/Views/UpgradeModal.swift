import SwiftUI

public struct UpgradeModal: View {
    @ObservedObject var gameManager: GameManager
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                HStack {
                    Text("🌟 クラスレベルアップ！ (Lv.\(gameManager.classLevel))")
                        .font(.headline)
                        .foregroundColor(.yellow)
                }
                
                Text("友情ポイントが貯まりました！強化カードを1枚選んでください。")
                    .font(.caption)
                    .foregroundColor(.white)
                
                VStack(spacing: 10) {
                    ForEach(gameManager.upgradeCandidates) { card in
                        Button(action: {
                            gameManager.applyUpgradeCard(card)
                        }) {
                            HStack(spacing: 14) {
                                Text(card.iconEmoji)
                                    .font(.system(size: 32))
                                    .frame(width: 44, height: 44)
                                    .background(Color.yellow.opacity(0.2))
                                    .cornerRadius(10)
                                
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(card.title)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Text(card.category.rawValue)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Text(card.description)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(12)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(20)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(20)
            .shadow(radius: 20)
            .padding(20)
        }
    }
}
