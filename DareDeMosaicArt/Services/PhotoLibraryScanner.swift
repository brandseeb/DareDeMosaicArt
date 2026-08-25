import Foundation
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// 写真ライブラリのスキャン & カラーパレット化サービス（端末ローカル全写真対応・キャッシュ付き）
@MainActor
public final class PhotoLibraryScanner: ObservableObject {
    public static let shared = PhotoLibraryScanner()
    
    @Published public var isScanning: Bool = false
    @Published public var scanProgress: Float = 0.0
    @Published public var totalPhotoCount: Int = 0
    @Published public var processedCount: Int = 0
    @Published public var localAvailableCount: Int = 0
    @Published public var scannedPhotos: [IndexedPhoto] = []
    @Published public var authorizationStatus: PHAuthorizationStatus = .notDetermined
    
    private init() {
        checkPermission()
    }
    
    /// 権限状態を確認
    public func checkPermission() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    /// 権限をリクエスト
    public func requestPermission() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorizationStatus = status
        return status == .authorized || status == .limited
    }
    
    /// 端末ローカルに保存されている写真の「全件」を高速スキャンしてインデックス化
    public func scanAllLocalPhotos() async -> [IndexedPhoto] {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            let granted = await requestPermission()
            guard granted else { return [] }
            return await scanAllLocalPhotos()
        }
        
        isScanning = true
        scanProgress = 0.0
        processedCount = 0
        localAvailableCount = 0
        
        let cachedEntries = PhotoColorIndexCache.load()
        var refreshedCacheEntries: [CachedPhotoIndexEntry] = []
        
        // 1. 写真ライブラリから画像アセットを全件取得（fetchLimitなし）
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        let totalCount = assets.count
        self.totalPhotoCount = totalCount
        
        guard totalCount > 0 else {
            self.isScanning = false
            return []
        }
        
        var results: [IndexedPhoto] = []
        results.reserveCapacity(totalCount)
        refreshedCacheEntries.reserveCapacity(totalCount)
        
        let imageManager = PHCachingImageManager.default()
        let targetSize = CGSize(width: 48, height: 48) // 高速化・省メモリのため48x48の極小サムネイル
        
        // 2. メモリ効率と並列性を両立するため、50件ずつのバッチで処理
        let batchSize = 50
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalCount)
            let batchAssets = (batchStart..<batchEnd).map { assets.object(at: $0) }
            
            let batchResults = await withTaskGroup(of: CachedPhotoIndexEntry?.self) { group in
                for asset in batchAssets {
                    if let cached = cachedEntries[asset.localIdentifier],
                       cached.modificationDate == asset.modificationDate {
                        group.addTask { cached }
                        continue
                    }

                    group.addTask {
                        let requestOptions = PHImageRequestOptions()
                        requestOptions.isSynchronous = false
                        requestOptions.deliveryMode = .fastFormat
                        requestOptions.resizeMode = .fast
                        requestOptions.isNetworkAccessAllowed = false // iCloud通信は行わず、端末ローカル写真のみ対象

                        return await withCheckedContinuation { continuation in
                            let gate = PhotoRequestContinuationGate(continuation)
                            imageManager.requestImage(
                                for: asset,
                                targetSize: targetSize,
                                contentMode: .aspectFill,
                                options: requestOptions
                            ) { image, info in
                                let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                                let isError = info?[PHImageErrorKey] != nil
                                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                                
                                if isCancelled || isError {
                                    gate.resume(returning: nil)
                                } else if let uiImage = image {
                                    let signature = ColorAnalysisService.shared.extractSpatialSignature(from: uiImage)
                                    let thumbData = uiImage.jpegData(compressionQuality: 0.6)
                                    let item = IndexedPhoto(
                                        id: asset.localIdentifier,
                                        labColor: signature.average,
                                        signature: signature,
                                        thumbnailData: thumbData
                                    )
                                    gate.resume(returning: CachedPhotoIndexEntry(
                                        id: asset.localIdentifier,
                                        modificationDate: asset.modificationDate,
                                        photo: item
                                    ))
                                } else if image == nil && !isDegraded {
                                    gate.resume(returning: nil)
                                }
                            }
                        }
                    }
                }
                
                var items: [CachedPhotoIndexEntry] = []
                for await item in group {
                    if let item {
                        items.append(item)
                        self.localAvailableCount += 1
                    }
                    self.processedCount += 1
                    self.scanProgress = Float(self.processedCount) / Float(totalCount)
                }
                return items
            }
            
            refreshedCacheEntries.append(contentsOf: batchResults)
            results.append(contentsOf: batchResults.map(\.photo))
            await Task.yield()
        }
        
        self.scannedPhotos = results
        self.isScanning = false

        let cacheSnapshot = refreshedCacheEntries
        Task {
            PhotoColorIndexCache.save(cacheSnapshot)
        }
        return results
    }
}

private struct CachedPhotoIndexEntry: Codable, Sendable {
    let id: String
    let modificationDate: Date?
    let photo: IndexedPhoto
}

/// PhotoKitの結果ハンドラが複数回呼ばれても、continuationは必ず1回だけ完了させる。
private final class PhotoRequestContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CachedPhotoIndexEntry?, Never>?

    init(_ continuation: CheckedContinuation<CachedPhotoIndexEntry?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: CachedPhotoIndexEntry?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// 前回の色解析結果をCaches領域にバイナリProperty Listとして保存する。（Swift 6 準拠）
private enum PhotoColorIndexCache {
    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DareDeMosaicArt", isDirectory: true)
            .appendingPathComponent("photo-color-index-v1.plist")
    }

    static func load() -> [String: CachedPhotoIndexEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let entries = try? PropertyListDecoder().decode([CachedPhotoIndexEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    static func save(_ entries: [CachedPhotoIndexEntry]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // キャッシュなので、保存失敗時は次回フル解析にフォールバックする。
        }
    }
}
