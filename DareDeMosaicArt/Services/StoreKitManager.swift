import Foundation
import StoreKit

/// Pro 状態（初回確認待ちの誤爆を防ぐ3状態）
public enum ProStatus: Equatable, Sendable {
    case loading  // 起動時の権利確認中（Paywallの誤表示を防ぐ）
    case free     // 無料ユーザー
    case pro      // Pro購入済みユーザー
}

/// アプリ内課金（StoreKit 2）および Pro 権限マネージャー（Swift 6 完全準拠）
@MainActor
public final class StoreKitManager: ObservableObject {
    public static let shared = StoreKitManager()
    
    /// Pro 買い切り商品のプロダクトID
    nonisolated public static let proProductID = "com.daredemosaic.app.pro"
    
    @Published public private(set) var proStatus: ProStatus = .loading
    @Published public private(set) var proProduct: Product? = nil
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var isRestoring: Bool = false
    @Published public var errorMessage: String? = nil
    
    #if DEBUG
    @Published public var debugIsProOverride: Bool? = nil
    #endif
    
    /// 便宜プロパティ（Pro判定）
    public var isProUser: Bool {
        #if DEBUG
        if let override = debugIsProOverride {
            return override
        }
        #endif
        return proStatus == .pro
    }
    
    #if DEBUG
    /// デバッグ用：ワンタップで Pro / Free を切り替える
    public func toggleDebugPro() {
        if isProUser {
            debugIsProOverride = false
            proStatus = .free
        } else {
            debugIsProOverride = true
            proStatus = .pro
        }
    }
    #endif
    
    /// 初回権利確認が完了したかどうか
    public var isInitialCheckCompleted: Bool {
        proStatus != .loading
    }
    
    private var transactionListenerTask: Task<Void, Never>? = nil
    
    private init() {
        // 1. MainActor 管理下の Task で取引のバックグラウンド更新を常時監視（Swift 6 警告ゼロ）
        self.transactionListenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { break }
                do {
                    let transaction = try Self.checkVerified(result)
                    if transaction.productID == Self.proProductID {
                        if transaction.revocationDate != nil {
                            // 返金・取り消し時の Pro 解除
                            self.proStatus = .free
                        } else {
                            self.proStatus = .pro
                        }
                    }
                    await transaction.finish()
                } catch {
                    // 未検証取引
                }
            }
        }
        
        // 2. 起動時に既存の権利を検証し、完了後に proStatus を更新
        Task {
            await updatePurchasedStatus()
            await fetchProduct()
        }
    }
    
    deinit {
        transactionListenerTask?.cancel()
    }
    
    // MARK: - 商品情報の取得
    public func fetchProduct() async {
        do {
            let products = try await Product.products(for: [Self.proProductID])
            if let product = products.first {
                self.proProduct = product
            }
        } catch {
            self.errorMessage = "商品情報を取得できませんでした: \(error.localizedDescription)"
        }
    }
    
    // MARK: - 購入処理
    public func purchasePro() async -> Bool {
        guard let product = proProduct else {
            await fetchProduct()
            guard let product = proProduct else {
                self.errorMessage = "商品情報が読み込まれていません。通信環境をご確認ください。"
                return false
            }
            return await purchase(product: product)
        }
        return await purchase(product: product)
    }
    
    private func purchase(product: Product) async -> Bool {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        
        do {
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                self.proStatus = .pro
                await transaction.finish()
                return true
                
            case .userCancelled:
                return false
                
            case .pending:
                self.errorMessage = "購入処理が保留中（承認待ち等）です。"
                return false
                
            @unknown default:
                return false
            }
        } catch {
            self.errorMessage = "購入処理中にエラーが発生しました: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - 購入履歴の復元（ユーザー明示操作時のみ実行）
    public func restorePurchases() async -> Bool {
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }
        
        do {
            try await AppStore.sync()
            await updatePurchasedStatus()
            return isProUser
        } catch {
            self.errorMessage = "購入の復元に失敗しました: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - 権利状態の更新（currentEntitlements）
    public func updatePurchasedStatus() async {
        var hasActivePro = false
        
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try Self.checkVerified(result)
                if transaction.productID == Self.proProductID {
                    if transaction.revocationDate == nil {
                        hasActivePro = true
                    }
                }
            } catch {
                // 未検証の取引はスキップ
            }
        }
        
        self.proStatus = hasActivePro ? .pro : .free
    }
    
    // MARK: - JWS 署名の検証（nonisolated / static）
    nonisolated public static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
