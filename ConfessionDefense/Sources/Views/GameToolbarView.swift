import SwiftUI

public struct GameToolbarView: View {
    @ObservedObject var gameManager: GameManager
    
    public var body: some View {
        VStack(spacing: 8) {
            if gameManager.gameState == .preparing {
                VStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // 机ツール（完全な壁）
                            ToolButton(
                                title: "机 (壁)",
                                emoji: "🟫",
                                isSelected: gameManager.selectedTool == .desk
                            ) {
                                gameManager.selectedTool = .desk
                            }
                            
                            // 椅子ツール（通過減速）
                            ToolButton(
                                title: "椅子 (減速)",
                                emoji: "🪑",
                                isSelected: gameManager.selectedTool == .chair
                            ) {
                                gameManager.selectedTool = .chair
                            }
                            
                            // 撤去ツール
                            ToolButton(
                                title: "撤去",
                                emoji: "🧹",
                                isSelected: gameManager.selectedTool == .none
                            ) {
                                gameManager.selectedTool = .none
                            }
                            
                            Divider()
                                .frame(height: 30)
                            
                            // 仲間の配置ボタン
                            ForEach(gameManager.activeMembers) { classmate in
                                let isSelected = gameManager.selectedTool == .classmate(classmate)
                                ToolButton(
                                    title: classmate.name,
                                    emoji: classmate.emoji,
                                    isSelected: isSelected
                                ) {
                                    gameManager.selectedTool = .classmate(classmate)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    
                    // 防衛開始ボタン
                    Button(action: {
                        gameManager.startBattle()
                    }) {
                        HStack {
                            Image(systemName: "shield.fill")
                            Text("授業開始！(防衛スタート)")
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 14)
                }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🛡️ 配置中: \(gameManager.placedClassmates.count)/\(gameManager.maxPlacedCount)人")
                            .font(.system(size: 11, weight: .bold))
                        
                        HStack(spacing: 4) {
                            ForEach(Array(gameManager.placedClassmates.values)) { member in
                                Text(member.emoji)
                                    .font(.system(size: 18))
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if !gameManager.benchMembers.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("📣 応援席 (パッシブ発動中)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 4) {
                                ForEach(gameManager.benchMembers) { member in
                                    Text(member.emoji)
                                        .font(.system(size: 14))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
    }
}

private struct ToolButton: View {
    let title: String
    let emoji: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(emoji)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .blue : .primary)
            }
            .frame(minWidth: 54, minHeight: 46)
            .background(isSelected ? Color.blue.opacity(0.15) : Color(UIColor.systemBackground))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
