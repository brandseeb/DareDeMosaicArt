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
            return String(localized: "error.photoScanner.permissionDenied", defaultValue: "写真ライブラリへのアクセスが許可されていません。設定アプリで許可してください。")
        case .albumNotFound(let title):
            return String(localized: "error.photoScanner.albumNotFound.format \(title)")
        case .cancelled:
            return String(localized: "error.photoScanner.cancelled", defaultValue: "写真のスキャンが中断されました。")
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
                    title: collection.localizedTitle ?? String(localized: "album.untitled", defaultValue: "無題のアルバム"),
                    assetCount: assets.count
                ))
            }
        }
        return items
    }
    
    // MARK: - 写真ソースからのスキャン
    public func scanPhotos(source: PhotoSource = .allLocalPhotos) async throws -> [IndexedPhoto] {
        let interval = PerformanceDiagnostics.begin(.photoLibraryScan, metadata: "source=\(source)")
        defer {
            PerformanceDiagnostics.end(
                interval,
                metadata: "processed=\(processedCount), local=\(localAvailableCount), total=\(totalPhotoCount)"
            )
        }
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
        let cachedEntries = await PhotoColorIndexCache.load()
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
            var cachedBatchEntries: [CachedPhotoIndexEntry] = []
            var assetsNeedingAnalysis: [PHAsset] = []
            cachedBatchEntries.reserveCapacity(batchAssets.count)
            assetsNeedingAnalysis.reserveCapacity(batchAssets.count)

            for asset in batchAssets {
                // キャッシュヒットのたびにTaskを作ると、数万枚でスケジューラ負荷が大きくなる。
                // 完全なv2データは同期的に取り込み、未解析・更新分だけを並列タスクに渡す。
                if let cached = cachedEntries[asset.localIdentifier],
                   cached.modificationDate == asset.modificationDate,
                   (cached.photo.signature?.version ?? 1) >= 2 {
                    cachedBatchEntries.append(cached)
                } else {
                    assetsNeedingAnalysis.append(asset)
                }
            }

            self.localAvailableCount += cachedBatchEntries.count
            self.processedCount += cachedBatchEntries.count
            self.scanProgress = Float(self.processedCount) / Float(totalCount)

            let analyzedEntries = await withTaskGroup(of: CachedPhotoIndexEntry?.self) { group in
                for asset in assetsNeedingAnalysis {

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

            let batchResults = cachedBatchEntries + analyzedEntries
            
            // 完全一致キャッシュを再び全件保存しない。新規・更新・v1再解析分だけを差分保存する。
            newlyProcessedEntries.append(contentsOf: batchResults.filter { entry in
                guard let previous = cachedEntries[entry.id] else { return true }
                return previous.modificationDate != entry.modificationDate
                    || (previous.photo.signature?.version ?? 1) < 2
            })
            results.append(contentsOf: batchResults.map(\.photo))
            await Task.yield()
        }
        
        self.scannedPhotos = results
        self.lastScannedSource = source
        self.hasCompletedScan = true
        self.isScanning = false

        // キャッシュに差分マージ
        let newEntries = newlyProcessedEntries
        if !newEntries.isEmpty {
            Task.detached(priority: .utility) {
                await PhotoColorIndexCache.merge(newEntries)
            }
        }
        return results
    }

    /// 永続キャッシュを先に返す。Photosとの最新状態照合は行わないため、UIの先行表示専用。
    public func cachedPhotos(for source: PhotoSource) async -> [IndexedPhoto] {
        if lastScannedSource == source, !scannedPhotos.isEmpty {
            return scannedPhotos
        }

        let cachedEntries = await PhotoColorIndexCache.load()
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
    private static let memoryStore = PhotoColorIndexMemoryStore()

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

    /// 最初の1回だけディスクをデコードし、以後はプロセス内の同じ辞書を共有する。
    /// 同時呼び出し時も PhotoColorIndexMemoryStore が同一ロードTaskへ合流させる。
    public static func load() async -> [String: CachedPhotoIndexEntry] {
        await memoryStore.load()
    }

    public static func prewarm() async {
        _ = await load()
    }

    fileprivate static func loadFromDisk() -> [String: CachedPhotoIndexEntry] {
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

    fileprivate static func writeToDisk(_ entries: [CachedPhotoIndexEntry]) {
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

    public static func save(_ entries: [CachedPhotoIndexEntry]) async {
        await memoryStore.replace(with: entries)
    }

    /// 差分マージ（既存の全写真キャッシュを消さずに追記更新）
    public static func merge(_ newEntries: [CachedPhotoIndexEntry]) async {
        await memoryStore.merge(newEntries)
    }

    /// 端末ライブラリから削除された写真のエントリを除去
    public static func removeUnavailableEntries(validIDs: Set<String>) async {
        await memoryStore.removeUnavailableEntries(validIDs: validIDs)
    }
}

/// 巨大plistの重複デコードを防ぎ、差分更新後のディスク書き込みも順序どおり直列化する。
private actor PhotoColorIndexMemoryStore {
    typealias Entries = [String: CachedPhotoIndexEntry]

    private var cachedEntries: Entries?
    private var inFlightLoad: Task<Entries, Never>?
    private var pendingWrite: Task<Void, Never>?

    func load() async -> Entries {
        let interval = PerformanceDiagnostics.begin(.photoCacheLoad)

        if let cachedEntries {
            PerformanceDiagnostics.end(interval, metadata: "source=memory, entries=\(cachedEntries.count)")
            return cachedEntries
        }

        let loadTask: Task<Entries, Never>
        let source: String
        if let inFlightLoad {
            loadTask = inFlightLoad
            source = "shared"
        } else {
            let created = Task.detached(priority: .utility) {
                PhotoColorIndexCache.loadFromDisk()
            }
            inFlightLoad = created
            loadTask = created
            source = "disk"
        }

        let loaded = await loadTask.value
        if cachedEntries == nil {
            cachedEntries = loaded
        }
        inFlightLoad = nil
        let result = cachedEntries ?? loaded
        PerformanceDiagnostics.end(interval, metadata: "source=\(source), entries=\(result.count)")
        return result
    }

    func replace(with entries: [CachedPhotoIndexEntry]) {
        let dictionary = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        cachedEntries = dictionary
        scheduleWrite(dictionary)
    }

    func merge(_ newEntries: [CachedPhotoIndexEntry]) async {
        guard !newEntries.isEmpty else { return }
        var current = await load()
        for entry in newEntries {
            current[entry.id] = entry
        }
        cachedEntries = current
        scheduleWrite(current)
    }

    func removeUnavailableEntries(validIDs: Set<String>) async {
        let current = await load()
        let filtered = current.filter { validIDs.contains($0.key) }
        guard filtered.count != current.count else { return }
        cachedEntries = filtered
        scheduleWrite(filtered)
    }

    private func scheduleWrite(_ entries: Entries) {
        let snapshot = entries.values.sorted { $0.id < $1.id }
        let previousWrite = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            _ = await previousWrite?.value
            PhotoColorIndexCache.writeToDisk(snapshot)
        }
    }
}
