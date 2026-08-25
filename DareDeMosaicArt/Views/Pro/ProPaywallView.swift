import SwiftUI
import StoreKit

/// 「誰でモザイクアート Pro」課金案内モーダル（Paywall）
public struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeKit = StoreKitManager.shared
    @State private var showRestoreSuccessAlert = false
    @State private var showPurchaseSuccessAlert = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 1. プレミアムヘッダー
                    headerView
                    
                    // 2. Pro 特典一覧
                    featuresListView
                    
                    // 3. 買い切りボタン & 価格表示
                    purchaseSection
                    
                    // 4. フッター（復元 & 規約リンク）
                    footerSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .task {
                if storeKit.proProduct == nil {
                    await storeKit.fetchProduct()
                }
            }
            .alert("購入の復元が完了しました", isPresented: $showRestoreSuccessAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text(storeKit.isProUser ? "Pro機能が正常に復元されました！" : "有効な購入履歴が見つかりませんでした。")
            }
            .alert("Proへのアップグレード完了！🎉", isPresented: $showPurchaseSuccessAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("すべてのPro機能が永久に解放されました。超大作モザイクアートをお楽しみください！")
            }
        }
    }
    
    // MARK: - ヘッダー
    private var headerView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: Color.orange.opacity(0.35), radius: 12, x: 0, y: 6)
                
                Image(systemName: "crown.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("誰でモザイクアート")
                        .font(.title2.bold())
                    Text("PRO")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            LinearGradient(
                                colors: [Color.orange, Color.red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(6)
                }
                
                Text("制限をすべて解除して、極限のモザイクアートを作ろう")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // リリース記念バッジ
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("リリース記念特別価格・買い切り")
                Image(systemName: "sparkles")
            }
            .font(.caption.bold())
            .foregroundColor(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(12)
        }
    }
    
    // MARK: - 特典一覧
    private var featuresListView: some View {
        VStack(spacing: 14) {
            featureRow(
                icon: "square.grid.3x3.square.fill",
                color: .orange,
                title: "超大作グリッド解放 (25×25 〜 60×60)",
                subtitle: "最大3,600マス！圧倒的な解像度と表現力で巨大モザイクを作成できます。"
            )
            
            featureRow(
                icon: "sparkles.tv.fill",
                color: .blue,
                title: "4K 超高画質エクスポート (4,096px)",
                subtitle: "A3/A2ポスター印刷や記念写真にも耐えうる最高峰クオリティで保存。"
            )
            
            featureRow(
                icon: "infinity",
                color: .purple,
                title: "作品の同時作成数・無制限",
                subtitle: "無料版の3作品制限を解除。好きなだけ作品を並行作成・ストック可能。"
            )
            
            featureRow(
                icon: "tag.slash.fill",
                color: .green,
                title: "透かしロゴ完全非表示",
                subtitle: "下部の署名余白なしで、完全な正方形の純粋アートとして保存・シェア。"
            )
            
            featureRow(
                icon: "gift.fill",
                color: .pink,
                title: "今後のPro機能も永久に使い放題",
                subtitle: "今後のアップデートで追加される新機能も、追加料金なしでそのまま利用可能。"
            )
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }
    
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 28, height: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            
            Spacer()
        }
    }
    
    // MARK: - 購入ボタン
    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if let error = storeKit.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                Task {
                    let success = await storeKit.purchasePro()
                    if success {
                        showPurchaseSuccessAlert = true
                    }
                }
            } label: {
                HStack {
                    if storeKit.isPurchasing {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 8)
                    }
                    
                    VStack(spacing: 2) {
                        if let product = storeKit.proProduct {
                            Text("\(product.displayPrice) で永久解除")
                                .font(.headline)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text("価格情報を読み込み中...")
                                    .font(.subheadline)
                            }
                        }
                        Text("1回の買い切りでずっと使えます（月額課金なし）")
                            .font(.caption2)
                            .opacity(0.85)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    storeKit.proProduct == nil
                    ? LinearGradient(colors: [Color.gray, Color.gray], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.orange, Color.red], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(14)
                .shadow(color: storeKit.proProduct == nil ? Color.clear : Color.orange.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .disabled(storeKit.proProduct == nil || storeKit.isPurchasing || storeKit.isRestoring)
        }
    }
    
    // MARK: - フッター（復元 & 規約リンク）
    private var footerSection: some View {
        VStack(spacing: 14) {
            Button {
                Task {
                    _ = await storeKit.restorePurchases()
                    showRestoreSuccessAlert = true
                }
            } label: {
                if storeKit.isRestoring {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("購入を復元する")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .disabled(storeKit.isPurchasing || storeKit.isRestoring)
            
            // 利用規約 ＆ プライバシーポリシー ＆ お問い合わせリンク
            HStack(spacing: 14) {
                Link("利用規約", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("・")
                    .foregroundColor(.secondary)
                Link("プライバシー", destination: URL(string: "https://brandseeb.github.io/DareDeMosaicArt/privacy.html")!)
                Text("・")
                    .foregroundColor(.secondary)
                Link("サポート", destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdlxMpCz5wvirp-X8LBdrJuT58UtP3eO8mkJsfrzm396mSUEQ/viewform?pli=1")!)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            
            Text("購入はお使いの Apple ID に請求されます。買い切りアイテムのため自動更新や継続課金は一切ありません。")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
}
