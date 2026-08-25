import SwiftUI

public struct ClassmateSelectionModal: View {
    @ObservedObject var gameManager: GameManager
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 18) {
                Text("🏫 新しい仲間が登校してきました！")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("誰を防衛メンバーに加えますか？\n（選ばなかった生徒は応援席からパッシブ効果を発揮します）")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.white.opacity(0.8))
                
                HStack(spacing: 12) {
                    ForEach(gameManager.arrivalCandidates) { classmate in
                        Button(action: {
                            gameManager.selectClassmateFromArrival(classmate)
                        }) {
                            VStack(spacing: 10) {
                                Text(classmate.emoji)
                                    .font(.system(size: 44))
                                
                                Text(classmate.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.primary)
                                
                                Text(classmate.role.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(6)
                                    .foregroundColor(.blue)
                                
                                Text(classmate.skillDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(height: 48)
                                
                                Divider()
                                
                                Text("📣 応援席効果:\n\(classmate.passiveBonusDescription)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(24)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(20)
            .shadow(radius: 20)
            .padding(16)
        }
    }
}
