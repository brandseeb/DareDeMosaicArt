import Foundation
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// 写真スキャナーのエラー
public enum PhotoLibraryScannerError: LocalizedError, Sendable {
    case permissionDenied
    case albumNotFound(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "写真ライブラリへのアクセスが許可されていません。設定アプリで許可してください。"
        case .albumNotFound(let title):
            return "指定されたアルバム「\(title)」が見つかりません。削除された可能性があります。"
        case .cancelled:
            return "写真のスキャンが中断されました。"
        }
    }
}

/// 写真ライブラリのスキャン & カラーパレット化サービス（アルバム指定・差分キャッシュ対応）
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
    
    // MARK: - ユーザーアルバム一覧の取得
    public func fetchUserAlbums() -> [PhotoAlbumItem] {
        guard authorizationStatus == .authorized else { return [] }
        
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        
        var items: [PhotoAlbumItem] = []
        userAlbums.enumerateObjects { collection, _, _ in
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            if assets.count > 0 {
                items.append(PhotoAlbumItem(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "無題のアルバム",
                    assetCount: assets.count
                ))
            }
        }
        return items
    }
    
    // MARK: - 写真ソースからのスキャン
    public func scanPhotos(source: PhotoSource = .allLocalPhotos) async throws -> [IndexedPhoto] {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            let granted = await requestPermission()
            guard granted else { throw PhotoLibraryScannerError.permissionDenied }
            return try await scanPhotos(source: source)
        }
        
        isScanning = true
        scanProgress = 0.0
        processedCount = 0
        localAvailableCount = 0
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        
        let assets: PHFetchResult<PHAsset>
        switch source {
        case .allLocalPhotos:
            assets = PHAsset.fetchAssets(with: fetchOptions)
            
        case .album(let localIdentifier, let title):
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [localIdentifier],
                options: nil
            )
            guard let collection = collections.firstObject else {
                self.isScanning = false
                throw PhotoLibraryScannerError.albumNotFound(title)
            }
            assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        }
        
        let totalCount = assets.count
        self.totalPhotoCount = totalCount
        
        guard totalCount > 0 else {
            self.isScanning = false
            return []
        }
        
        // 既存キャッシュを読み込み
        let cachedEntries = PhotoColorIndexCache.load()
        var newlyProcessedEntries: [CachedPhotoIndexEntry] = []
        var results: [IndexedPhoto] = []
        results.reserveCapacity(totalCount)
        newlyProcessedEntries.reserveCapacity(totalCount)
        
        let imageManager = PHCachingImageManager.default()
        let targetSize = CGSize(width: 48, height: 48)
        
        let batchSize = 50
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalCount)
            let batchAssets = (batchStart..<batchEnd).map { assets.object(at: $0) }
            
            let batchResults = await withTaskGroup(of: CachedPhotoIndexEntry?.self) { group in
                for asset in batchAssets {
                    // キャッシュがあっても端末ローカルに写真が存在するか確認するためリクエストを実行
                    group.addTask {
                        let requestOptions = PHImageRequestOptions()
                        requestOptions.isSynchronous = false
                        requestOptions.deliveryMode = .fastFormat
                        requestOptions.resizeMode = .fast
                        requestOptions.isNetworkAccessAllowed = false // 端末ローカル写真のみ対象

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
                                    // 端末内に画像が存在する場合
                                    if let cached = cachedEntries[asset.localIdentifier],
                                       cached.modificationDate == asset.modificationDate {
                                        // キャッシュ利用
                                        gate.resume(returning: cached)
                                    } else {
                                        // 新規色解析
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
                                    }
                                } else if image == nil && !isDegraded {
                                    // iCloudのみに存在しローカルにない
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
            
            newlyProcessedEntries.append(contentsOf: batchResults)
            results.append(contentsOf: batchResults.map(\.photo))
            await Task.yield()
        }
        
        self.scannedPhotos = results
        self.isScanning = false

        // キャッシュに差分マージ
        let newEntries = newlyProcessedEntries
        Task {
            PhotoColorIndexCache.merge(newEntries)
        }
        return results
    }
    
    /// ソースに該当する写真群を取得
    public func photos(for source: PhotoSource) async throws -> [IndexedPhoto] {
        return try await scanPhotos(source: source)
    }
}

public struct CachedPhotoIndexEntry: Codable, Sendable {
    public let id: String
    public let modificationDate: Date?
    public let photo: IndexedPhoto
    
    public init(id: String, modificationDate: Date?, photo: IndexedPhoto) {
        self.id = id
        self.modificationDate = modificationDate
        self.photo = photo
    }
}

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

/// 前回の色解析結果をCaches領域にバイナリProperty Listとして保存・マージする。
public enum PhotoColorIndexCache {
    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DareDeMosaicArt", isDirectory: true)
            .appendingPathComponent("photo-color-index-v1.plist")
    }

    public static func load() -> [String: CachedPhotoIndexEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let entries = try? PropertyListDecoder().decode([CachedPhotoIndexEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    public static func save(_ entries: [CachedPhotoIndexEntry]) {
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
            // キャッシュ保存失敗時は次回フル解析にフォールバック
        }
    }

    /// 差分マージ（既存の全写真キャッシュを消さずに追記更新）
    public static func merge(_ newEntries: [CachedPhotoIndexEntry]) {
        var current = load()
        for entry in newEntries {
            current[entry.id] = entry
        }
        save(Array(current.values))
    }

    /// 端末ライブラリから削除された写真のエントリを除去
    public static func removeUnavailableEntries(validIDs: Set<String>) {
        let current = load()
        let filtered = current.values.filter { validIDs.contains($0.id) }
        if filtered.count != current.count {
            save(Array(filtered))
        }
    }
}
