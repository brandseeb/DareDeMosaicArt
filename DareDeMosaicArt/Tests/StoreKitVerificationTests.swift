import Foundation
import StoreKit

/// StoreKit 課金ヘルパー・VerificationResult 振り分け・Pro状態の単体テスト
func runStoreKitVerification() {
    print("\n👑 --- 「誰でモザイクアート」StoreKit 2 ヘルパー & 状態分岐テスト開始 ---")
    
    // 1. プロダクトID定義の検証
    assert(StoreKitManager.proProductID == "com.daredemosaic.app.pro", "プロダクトIDが仕様と一致している必要があります")
    print("✅ プロダクトID定数検証: 正常 (\(StoreKitManager.proProductID))")
    
    // 2. ProStatus 3状態遷移とプロパティの検証
    let loadingStatus = ProStatus.loading
    let freeStatus = ProStatus.free
    let proStatus = ProStatus.pro
    
    assert(loadingStatus != freeStatus, "loading と free は明確に区別される必要があります")
    assert(freeStatus != proStatus, "free と pro は明確に区別される必要があります")
    assert(loadingStatus != proStatus, "loading と pro は明確に区別される必要があります")
    print("✅ ProStatus (loading / free / pro) 3状態判定: 正常")
    
    // 3. VerificationResult 分岐ヘルパー (checkVerified) の動作検証
    struct MockPayload: Equatable {
        let id: String
    }
    let verifiedMock = VerificationResult<MockPayload>.verified(MockPayload(id: "pro_test"))
    do {
        let extracted = try StoreKitManager.checkVerified(verifiedMock)
        assert(extracted.id == "pro_test", "verified な取引結果から正しくペイロードを取り出せる必要があります")
        print("✅ VerificationResult.verified 分岐テスト: 正常")
    } catch {
        fatalError("checkVerified は verified な取引で例外を投げてはなりません")
    }
    
    let unverifiedMock = VerificationResult<MockPayload>.unverified(MockPayload(id: "fake_pro"), VerificationResult<MockPayload>.VerificationError.invalidSignature)
    do {
        _ = try StoreKitManager.checkVerified(unverifiedMock)
        fatalError("checkVerified は unverified な取引で例外を投げる必要があります")
    } catch {
        print("✅ VerificationResult.unverified 例外捕捉テスト: 正常")
    }
    
    print("🎉 --- StoreKit ヘルパー & 状態分岐テストが正常に完了しました！ ---")
}
