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
            .alert(String(localized: "paywall.alert.restore.title"), isPresented: $showRestoreSuccessAlert) {
                Button(String(localized: "common.ok")) {
                    dismiss()
                }
            } message: {
                Text(storeKit.isProUser ? LocalizedStringResource("paywall.alert.restore.success") : LocalizedStringResource("paywall.alert.restore.notFound"))
            }
            .alert(String(localized: "paywall.alert.purchase.title"), isPresented: $showPurchaseSuccessAlert) {
                Button(String(localized: "common.ok")) {
                    dismiss()
                }
            } message: {
                Text(LocalizedStringResource("paywall.alert.purchase.message"))
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
                    Text(LocalizedStringResource("app.name"))
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
                
                Text(LocalizedStringResource("paywall.header.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // リリース記念バッジ
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(LocalizedStringResource("paywall.badge.launchSpecial"))
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
                title: LocalizedStringResource("paywall.feature.grid.title"),
                subtitle: LocalizedStringResource("paywall.feature.grid.desc")
            )
            
            featureRow(
                icon: "sparkles.tv.fill",
                color: .blue,
                title: LocalizedStringResource("paywall.feature.4k.title"),
                subtitle: LocalizedStringResource("paywall.feature.4k.desc")
            )
            
            featureRow(
                icon: "infinity",
                color: .purple,
                title: LocalizedStringResource("paywall.feature.unlimited.title"),
                subtitle: LocalizedStringResource("paywall.feature.unlimited.desc")
            )
            
            featureRow(
                icon: "tag.slash.fill",
                color: .green,
                title: LocalizedStringResource("paywall.feature.watermark.title"),
                subtitle: LocalizedStringResource("paywall.feature.watermark.desc")
            )
            
            featureRow(
                icon: "gift.fill",
                color: .pink,
                title: LocalizedStringResource("paywall.feature.future.title"),
                subtitle: LocalizedStringResource("paywall.feature.future.desc")
            )
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }
    
    private func featureRow(icon: String, color: Color, title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
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
                            Text(LocalizedStringResource("paywall.button.unlockPrice.format \(product.displayPrice)"))
                                .font(.headline)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text(LocalizedStringResource("paywall.loadingPrice"))
                                    .font(.subheadline)
                            }
                        }
                        Text(LocalizedStringResource("paywall.oneTimeNotice"))
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
                    Text(LocalizedStringResource("paywall.restorePurchases"))
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .disabled(storeKit.isPurchasing || storeKit.isRestoring)
            
            // 利用規約 ＆ プライバシーポリシー ＆ お問い合わせリンク
            HStack(spacing: 14) {
                Link(String(localized: "paywall.termsOfService"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("・")
                    .foregroundColor(.secondary)
                Link(String(localized: "paywall.privacyPolicy"), destination: URL(string: "https://brandseeb.github.io/DareDeMosaicArt/privacy.html")!)
                Text("・")
                    .foregroundColor(.secondary)
                Link(String(localized: "paywall.support"), destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdlxMpCz5wvirp-X8LBdrJuT58UtP3eO8mkJsfrzm396mSUEQ/viewform?pli=1")!)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            
            Text(LocalizedStringResource("paywall.appleIdNotice"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
}
