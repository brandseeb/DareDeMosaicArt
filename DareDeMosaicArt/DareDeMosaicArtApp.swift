import SwiftUI

/// アプリメインエントリーポイント
@main
struct DareDeMosaicArtApp: App {
    @StateObject private var projectStore = ProjectStore()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            HomeView(
                projects: $projectStore.projects,
                onDeleteProjects: projectStore.deleteProjects(ids:)
            )
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    projectStore.flushPendingSave()
                }
            }
        }
    }
}

/// プロジェクトの永続化管理クラス
@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [MosaicProject] = [] {
        didSet {
            saveRevision += 1
            let snapshot = projects
            let revision = saveRevision
            // Bindingの細かな更新ごとに全作品を書き出さず、短時間の連続変更を1回へまとめる。
            saveTask?.cancel()
            saveTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await persistence.save(snapshot, revision: revision)
            }
        }
    }
    
    private let saveKey = "SavedMosaicProjects_v1"
    private let persistence = ProjectPersistenceActor()
    private var saveRevision = 0
    private var saveTask: Task<Void, Never>?
    
    init() {
        // 起動時に古い一時タイムラプス動画ファイルを自動清掃
        TimelapseExportService.cleanupOldTemporaryFiles()
        
        let diskProjects = ProjectDiskStore.load()
        if !diskProjects.isEmpty {
            projects = diskProjects
        } else if let legacyData = UserDefaults.standard.data(forKey: saveKey),
                  let legacyProjects = try? JSONDecoder().decode([MosaicProject].self, from: legacyData) {
            // 旧 UserDefaults データは消さず、新ファイル形式へ安全にコピーする。
            projects = legacyProjects
            Task { await persistence.save(legacyProjects, revision: 0) }
        }
    }

    /// プロジェクトと撮影画像データを完全に削除
    func deleteProjects(ids: [UUID]) {
        let idsToDelete = Set(ids)
        projects.removeAll { idsToDelete.contains($0.id) }
        Task {
            await persistence.delete(ids: ids)
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveRevision += 1
        let snapshot = projects
        let revision = saveRevision
        saveTask = Task {
            await persistence.save(snapshot, revision: revision)
        }
    }
}

private actor ProjectPersistenceActor {
    private var latestRevision = -1

    func save(_ projects: [MosaicProject], revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        ProjectDiskStore.save(projects)
    }

    func delete(ids: [UUID]) {
        ProjectDiskStore.delete(ids: ids)
    }
}

/// 一覧では読み込まないタイル画像を、選択した1作品だけバックグラウンドで復元する。
actor ProjectAssetLoader {
    static let shared = ProjectAssetLoader()

    func hydrate(_ project: MosaicProject) -> MosaicProject {
        ProjectDiskStore.hydrate(project)
    }
}

/// Documents/Projects に軽量JSONと画像キャッシュを分離保存する。（Swift 6 完全準拠）
private enum ProjectDiskStore {
    private static var fileManager: FileManager {
        FileManager.default
    }

    private static var rootURL: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Projects", isDirectory: true)
    }

    private static var indexURL: URL? {
        rootURL?.appendingPathComponent("index.json")
    }

    static func load() -> [MosaicProject] {
        guard let rootURL, let indexURL,
              let indexData = try? Data(contentsOf: indexURL),
              let orderedIds = try? JSONDecoder().decode([String].self, from: indexData) else {
            return []
        }

        let projects = orderedIds.compactMap { idString -> MosaicProject? in
            guard let id = UUID(uuidString: idString) else { return nil }
            let metadataURL = rootURL.appendingPathComponent("\(id.uuidString).json")
            guard let data = try? Data(contentsOf: metadataURL),
                  var project = try? JSONDecoder().decode(MosaicProject.self, from: data) else { return nil }

            let assetDirectory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let targetURL = assetDirectory.appendingPathComponent("target.jpg")
            if let targetData = try? Data(contentsOf: targetURL) {
                project.targetImageData = targetData
            }

            // タイルJPEGは作品を開くまで読み込まない。起動・一覧表示のメモリとI/Oを抑える。
            return project.targetImageData.isEmpty ? nil : project
        }
        removeOrphanedFiles(validIds: Set(orderedIds))
        return projects
    }

    static func hydrate(_ project: MosaicProject) -> MosaicProject {
        guard let rootURL else { return project }
        var hydrated = project
        let imagesDirectory = rootURL
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)

        for index in hydrated.tiles.indices where hydrated.tiles[index].thumbnailData == nil {
            autoreleasepool {
                let tile = hydrated.tiles[index]
                let imageURL = imagesDirectory.appendingPathComponent("\(tile.id.uuidString).jpg")
                // リセット後に残った古いJPEGを復活させない。写真配置のメタデータがあるタイルだけ読む。
                guard tile.isFilled else {
                    try? fileManager.removeItem(at: imageURL)
                    return
                }
                if let imageData = try? Data(contentsOf: imageURL, options: [.mappedIfSafe]) {
                    hydrated.tiles[index].thumbnailData = imageData
                }
            }
        }
        return hydrated
    }

    static func save(_ projects: [MosaicProject]) {
        guard let rootURL, let indexURL else { return }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            for project in projects {
                let assetDirectory = rootURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
                let imagesDirectory = assetDirectory.appendingPathComponent("images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

                try project.targetImageData.write(
                    to: assetDirectory.appendingPathComponent("target.jpg"),
                    options: .atomic
                )

                var metadata = project
                metadata.targetImageData = Data()
                for index in metadata.tiles.indices {
                    if let imageData = metadata.tiles[index].thumbnailData {
                        let imageURL = imagesDirectory.appendingPathComponent("\(metadata.tiles[index].id.uuidString).jpg")
                        let existingSize = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                        if existingSize != imageData.count {
                            try imageData.write(to: imageURL, options: .atomic)
                        }
                    }
                    metadata.tiles[index].thumbnailData = nil
                }

                let metadataData = try encoder.encode(metadata)
                try metadataData.write(
                    to: rootURL.appendingPathComponent("\(project.id.uuidString).json"),
                    options: .atomic
                )
            }

            let indexData = try encoder.encode(projects.map { $0.id.uuidString })
            try indexData.write(to: indexURL, options: .atomic)
            removeOrphanedFiles(validIds: Set(projects.map { $0.id.uuidString }))
        } catch {
            // 次回の状態更新時に再試行される。中途半端なJSONは .atomic で防ぐ。
        }
    }

    /// 指定されたプロジェクトのディレクトリおよびメタデータを即座に物理消去
    static func delete(ids: [UUID]) {
        guard let rootURL, let indexURL else { return }
        for id in ids {
            let assetDirectory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let metadataURL = rootURL.appendingPathComponent("\(id.uuidString).json")
            try? fileManager.removeItem(at: assetDirectory)
            try? fileManager.removeItem(at: metadataURL)
        }
        
        // index.json を更新
        if let indexData = try? Data(contentsOf: indexURL),
           var orderedIds = try? JSONDecoder().decode([String].self, from: indexData) {
            let deletedIdStrings = Set(ids.map { $0.uuidString })
            orderedIds.removeAll { deletedIdStrings.contains($0) }
            if let updatedIndexData = try? JSONEncoder().encode(orderedIds) {
                try? updatedIndexData.write(to: indexURL, options: .atomic)
            }
        }
    }

    /// index.json 更新後に、このアプリが作った UUID 名のJSONと画像フォルダだけを清掃する。
    private static func removeOrphanedFiles(validIds: Set<String>) {
        guard let rootURL,
              let contents = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for url in contents {
            if url.lastPathComponent == "index.json" { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let candidateId: String
            if values?.isDirectory == true {
                candidateId = url.lastPathComponent
            } else if url.pathExtension.lowercased() == "json" {
                candidateId = url.deletingPathExtension().lastPathComponent
            } else {
                continue
            }

            // 予期しないファイルを消さないよう、UUID名の自前ファイルだけを対象にする。
            guard UUID(uuidString: candidateId) != nil, !validIds.contains(candidateId) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
