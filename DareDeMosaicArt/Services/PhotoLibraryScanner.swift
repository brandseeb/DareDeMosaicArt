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

    /// 同じ写真ソースを画面ごとに再スキャンしないためのセッションキャッシュ。
    private var lastScannedSource: PhotoSource?
    private var hasCompletedScan = false
    
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
            self.scannedPhotos = []
            self.lastScannedSource = source
            self.hasCompletedScan = true
            self.isScanning = false
            return []
        }
        
        // 既存キャッシュを読み込み
        let cachedEntries = await Task.detached(priority: .utility) {
            PhotoColorIndexCache.load()
        }.value
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
                    // 完全な v2 特徴量がキャッシュ済みなら Photos への画像要求と再解析を省略する。
                    if let cached = cachedEntries[asset.localIdentifier],
                       cached.modificationDate == asset.modificationDate,
                       (cached.photo.signature?.version ?? 1) >= 2 {
                        group.addTask { cached }
                        continue
                    }

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
                                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                                
                                if isCancelled || isError || isInCloud {
                                    // iCloudのみに存在、キャンセル、またはエラーの場合は端末ローカル対象外
                                    gate.resume(returning: nil)
                                } else if let uiImage = image {
                                    if isDegraded {
                                        // 劣化版画像（プレビュー段階）は確定解析として採用せず、本番コールバックを待つ
                                        return
                                    }
                                    
                                    // 未解析または更新された写真だけを解析する。
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
                                } else {
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
        self.lastScannedSource = source
        self.hasCompletedScan = true
        self.isScanning = false

        // キャッシュに差分マージ
        let newEntries = newlyProcessedEntries
        Task.detached(priority: .utility) {
            PhotoColorIndexCache.merge(newEntries)
        }
        return results
    }

    /// 永続キャッシュを先に返す。Photosとの最新状態照合は行わないため、UIの先行表示専用。
    public func cachedPhotos(for source: PhotoSource) async -> [IndexedPhoto] {
        if lastScannedSource == source, !scannedPhotos.isEmpty {
            return scannedPhotos
        }

        let cachedEntries = await Task.detached(priority: .userInitiated) {
            PhotoColorIndexCache.load()
        }.value
        guard !cachedEntries.isEmpty else { return [] }

        let photos: [IndexedPhoto]
        switch source {
        case .allLocalPhotos:
            photos = cachedEntries.values.map(\.photo).sorted { $0.id < $1.id }

        case .album(let localIdentifier, _):
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [localIdentifier],
                options: nil
            )
            guard let collection = collections.firstObject else { return [] }

            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            var assetIDs = Set<String>()
            assetIDs.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                assetIDs.insert(asset.localIdentifier)
            }
            photos = cachedEntries.values
                .filter { assetIDs.contains($0.id) }
                .map(\.photo)
                .sorted { $0.id < $1.id }
        }

        scannedPhotos = photos
        lastScannedSource = source
        // 先行キャッシュは最新照合済みではないため、photos(for:) では引き続き差分更新する。
        hasCompletedScan = false
        return photos
    }
    
    /// ソースに該当する写真群を取得
    public func photos(for source: PhotoSource) async throws -> [IndexedPhoto] {
        if hasCompletedScan, lastScannedSource == source {
            return scannedPhotos
        }
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

/// 前回の色解析結果をCaches領域にバイナリProperty Listとして保存・マージする（v2優先・v1段階移行対応）。
public enum PhotoColorIndexCache {
    private static var fileURLV2: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DareDeMosaicArt", isDirectory: true)
            .appendingPathComponent("photo-color-index-v2.plist")
    }

    private static var fileURLV1: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DareDeMosaicArt", isDirectory: true)
            .appendingPathComponent("photo-color-index-v1.plist")
    }

    public static func load() -> [String: CachedPhotoIndexEntry] {
        let decoder = PropertyListDecoder()
        
        // 1. v2 キャッシュが存在すれば優先ロード
        if let fileURLV2,
           let data = try? Data(contentsOf: fileURLV2),
           let entries = try? decoder.decode([CachedPhotoIndexEntry].self, from: data) {
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        }
        
        // 2. v2 がなければ v1 キャッシュをロード（後方互換）
        if let fileURLV1,
           let data = try? Data(contentsOf: fileURLV1),
           let entries = try? decoder.decode([CachedPhotoIndexEntry].self, from: data) {
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        }
        
        return [:]
    }

    public static func save(_ entries: [CachedPhotoIndexEntry]) {
        guard let fileURL = fileURLV2 else { return }
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
