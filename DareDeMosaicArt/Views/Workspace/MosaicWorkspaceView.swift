import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// モザイクアート制作ワークスペース画面
public struct MosaicWorkspaceView: View {
    @Binding public var project: MosaicProject
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var storeKit = StoreKitManager.shared
    @State private var selectedTile: MosaicTile? = nil
    @State private var activeMission: ColorMission? = nil
    @State private var showCompletion: Bool = false
    @State private var showPaywall: Bool = false
    @State private var showAutoFillSheet: Bool = false
    @State private var showResetConfirmAlert: Bool = false
    @State private var showAlbumMissingAlert: Bool = false
    @State private var albumMissingMessage: String = ""
    
    // 手動差し替え用の候補リスト
    @State private var replacementCandidates: [PhotoMatchCandidate] = []
    @State private var isLoadingCandidates: Bool = false
    @State private var candidateLoadTask: Task<Void, Never>?
    @State private var allSourcePhotos: [IndexedPhoto] = []
    @State private var isLoadingSourcePhotos: Bool = false
    @State private var hasFullyLoadedSourcePhotos: Bool = false
    @State private var candidateSearchIndex: MultiDimensionalPhotoIndex?
    @State private var candidateSearchIndexPhotoCount: Int = 0
    
    // キャンバス表示スケールと位置
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var isPressingOriginalImage: Bool = false
    
    public init(project: Binding<MosaicProject>) {
        self._project = project
    }
    
    /// 空きマス数
    private var emptyTilesCount: Int {
        project.tiles.filter { !$0.isFilled && !$0.isLocked }.count
    }
    
    /// オートフィル済みマス数
    private var autoFilledTilesCount: Int {
        project.tiles.filter { $0.origin == .autoFilled && !$0.isLocked }.count
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 上部ステータスバー
                statusBar
                
                // メインキャンバス
                ZStack {
                    Color(.systemGroupedBackground).ignoresSafeArea()
                    
                    MosaicCanvasView(
                        project: project,
                        selectedTileId: selectedTile?.id,
                        isShowingOriginalImage: isPressingOriginalImage,
                        zoomScale: $canvasScale,
                        offset: $canvasOffset,
                        onSelectTile: { tile in
                            handleTileSelected(tile)
                        }
                    )
                    .clipped()
                }
                .frame(maxHeight: .infinity)
                
                // 下部ミッションバー
                missionSection
            }
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompletion = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("完成版")
                        }
                        .font(.subheadline.bold())
                    }
                }
            }
            .sheet(item: $selectedTile) { tile in
                tileDetailSheet(for: tile)
                    .presentationDetents([.medium, .large])
                    .onDisappear {
                        candidateLoadTask?.cancel()
                        isLoadingCandidates = false
                    }
            }
            .sheet(isPresented: $showAutoFillSheet) {
                AutoFillSheetView(
                    project: $project,
                    availablePhotos: allSourcePhotos,
                    onApplied: { _ in },
                    onReset: { _ in }
                )
                .presentationDetents([.large])
            }
            .fullScreenCover(item: $activeMission) { mission in
                MissionCameraView(
                    mission: mission
                ) { photo in
                    let result = MosaicEngine.shared.fitCapturedPhoto(
                        project: project,
                        photoData: photo.thumbnailData ?? Data(),
                        photoLabColor: photo.labColor,
                        photoSignature: photo.signature,
                        preferredTileID: mission.targetTileIds.count == 1 ? mission.targetTileIds.first : nil,
                        targetTileIDs: mission.targetTileIds
                    )
                    
                    self.project = result.updatedProject
                    if let matched = result.matchedTile {
                        self.selectedTile = matched
                    }
                }
            }
            .fullScreenCover(isPresented: $showCompletion) {
                CompletionView(project: $project)
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywallView()
            }
            .alert("アルバムが見つかりません", isPresented: $showAlbumMissingAlert) {
                Button("端末内の全写真に切り替える") {
                    project.photoSource = .allLocalPhotos
                    allSourcePhotos = []
                    hasFullyLoadedSourcePhotos = false
                    candidateSearchIndex = nil
                    candidateSearchIndexPhotoCount = 0
                    Task {
                        await loadSourcePhotos()
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(albumMissingMessage)
            }
            .alert("自動配置を取り消しますか？", isPresented: $showResetConfirmAlert) {
                Button("配置前に戻す", role: .destructive) {
                    let (updated, _) = MosaicEngine.shared.resetAutoFilledTiles(project: project)
                    self.project = updated
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("自動配置された \(autoFilledTilesCount) マスを元の空きマスに戻します。撮影したピースや手動で選んだピースはそのまま保護されます。")
            }
            .task(id: project.photoSource) {
                await prewarmCachedSourcePhotos()
            }
        }
    }

    /// 作品を開いた直後に永続キャッシュだけを先読みし、ピース初回タップの待ち時間を隠す。
    private func prewarmCachedSourcePhotos() async {
        guard allSourcePhotos.isEmpty else { return }
        let source = project.photoSource
        let cached = await PhotoLibraryScanner.shared.cachedPhotos(for: source)
        guard !Task.isCancelled, project.photoSource == source, allSourcePhotos.isEmpty else { return }
        allSourcePhotos = cached
        if !cached.isEmpty {
            _ = await preparedCandidateIndex(for: cached)
        }
    }

    /// 同じライブラリ集合では多次元検索インデックスを使い回す。
    private func preparedCandidateIndex(
        for photos: [IndexedPhoto],
        forceRebuild: Bool = false
    ) async -> MultiDimensionalPhotoIndex {
        if !forceRebuild,
           let candidateSearchIndex,
           candidateSearchIndexPhotoCount == photos.count {
            return candidateSearchIndex
        }

        let interval = PerformanceDiagnostics.begin(
            .candidateIndexBuild,
            metadata: "photos=\(photos.count)"
        )
        let built = await Task.detached(priority: .userInitiated) {
            MultiDimensionalPhotoIndex(photos: photos)
        }.value
        PerformanceDiagnostics.end(interval, metadata: "photos=\(photos.count)")
        candidateSearchIndex = built
        candidateSearchIndexPhotoCount = photos.count
        return built
    }
    
    // MARK: - ソース写真の事前ロード（バックグラウンド実行）
    private func loadSourcePhotos() async {
        if hasFullyLoadedSourcePhotos { return }
        if isLoadingSourcePhotos {
            while isLoadingSourcePhotos && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        isLoadingSourcePhotos = true
        defer { isLoadingSourcePhotos = false }
        do {
            let loaded = try await PhotoLibraryScanner.shared.photos(for: project.photoSource)
            await MainActor.run {
                self.allSourcePhotos = loaded
                self.hasFullyLoadedSourcePhotos = true
            }
        } catch let error as PhotoLibraryScannerError {
            if case .albumNotFound = error {
                await MainActor.run {
                    self.albumMissingMessage = error.localizedDescription
                    self.showAlbumMissingAlert = true
                    if self.allSourcePhotos.isEmpty {
                        self.allSourcePhotos = []
                    }
                    self.hasFullyLoadedSourcePhotos = false
                }
            }
        } catch {
            await MainActor.run {
                if self.allSourcePhotos.isEmpty {
                    self.allSourcePhotos = []
                }
                self.hasFullyLoadedSourcePhotos = false
            }
        }
    }

    /// 写真全件の解析は作品閲覧時には行わず、必要な機能を開く直前にだけ実行する。
    private func openAutoFill() {
        guard !isLoadingSourcePhotos else { return }
        Task {
            await loadSourcePhotos()
            guard !Task.isCancelled, !allSourcePhotos.isEmpty else { return }
            showAutoFillSheet = true
        }
    }
    
    private func handleTileSelected(_ tile: MosaicTile) {
        selectedTile = tile
        replacementCandidates = []
        loadCandidates(for: tile)
    }
    
    private func loadCandidates(for tile: MosaicTile) {
        candidateLoadTask?.cancel()
        isLoadingCandidates = true
        replacementCandidates = []

        candidateLoadTask = Task {
            // 1. 前回の解析キャッシュを使い、候補を先に表示する。
            if allSourcePhotos.isEmpty {
                let cached = await PhotoLibraryScanner.shared.cachedPhotos(for: project.photoSource)
                guard !Task.isCancelled, selectedTile?.id == tile.id else { return }
                allSourcePhotos = cached
            }
            guard !Task.isCancelled, selectedTile?.id == tile.id else { return }

            // 選択中タイル自身の現在の写真も含め、プロジェクト内で配置済みの全写真IDを除外
            var usedIDs = Set(project.tiles.compactMap(\.placedPhotoIdentifier))
            if let currentPhotoID = tile.placedPhotoIdentifier {
                usedIDs.insert(currentPhotoID)
            }

            if !allSourcePhotos.isEmpty {
                let cachedPhotos = allSourcePhotos
                let cachedIndex = await preparedCandidateIndex(for: cachedPhotos)
                let cachedCandidates = await Task.detached(priority: .userInitiated) {
                    MosaicEngine.shared.findBestMatchCandidates(
                        for: tile,
                        using: cachedIndex,
                        excluding: usedIDs,
                        topK: 8
                    )
                }.value
                guard !Task.isCancelled, selectedTile?.id == tile.id else { return }
                self.replacementCandidates = cachedCandidates
            }

            // 2. 候補を表示したまま、裏側で新規・更新・削除写真との差分を照合する。
            let neededLibraryRefresh = !hasFullyLoadedSourcePhotos
            await loadSourcePhotos()
            guard !Task.isCancelled, selectedTile?.id == tile.id else { return }

            let refreshedPhotos = allSourcePhotos
            let refreshedIndex = await preparedCandidateIndex(
                for: refreshedPhotos,
                forceRebuild: neededLibraryRefresh
            )
            let refreshedCandidates = await Task.detached(priority: .userInitiated) {
                MosaicEngine.shared.findBestMatchCandidates(
                    for: tile,
                    using: refreshedIndex,
                    excluding: usedIDs,
                    topK: 8
                )
            }.value
            guard !Task.isCancelled, selectedTile?.id == tile.id else { return }
            self.replacementCandidates = refreshedCandidates
            self.isLoadingCandidates = false
        }
    }
    
    // MARK: - ステータスバー
    private var statusBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("進捗: \(Double(project.progress).formatted(.percent.precision(.fractionLength(0))))")
                        .font(.headline)
                    Text("(\(project.filledCount)/\(project.totalTilesCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                ProgressView(value: Double(project.progress))
                    .frame(width: 130)
            }
            
            Spacer()
            
            if autoFilledTilesCount > 0 && project.isCompleted {
                Button {
                    showResetConfirmAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("自動配置前に戻す")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else if !project.isCompleted && emptyTilesCount > 0 {
                Button {
                    openAutoFill()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("残り\(emptyTilesCount)マス自動配置")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            if canvasScale > 1.05 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        canvasScale = 1.0
                        canvasOffset = .zero
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                        Text("全体")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .zIndex(10) // 拡大されたキャンバスより確実に前面に配置
    }
    
    // MARK: - ミッションセクション
    private var missionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "camera.badge.ellipsis")
                    .foregroundColor(.accentColor)
                Text(project.missions.isEmpty ? "全ミッション完了！🎉" : "探す色ミッション")
                    .font(.headline)
                
                Spacer()
                
                // 元画像表示ボタン（長押ししている間だけ元画像を表示）
                HStack(spacing: 4) {
                    Image(systemName: isPressingOriginalImage ? "eye.fill" : "eye")
                    Text("元画像を表示")
                        .font(.caption.bold())
                }
                .foregroundColor(isPressingOriginalImage ? .white : .accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isPressingOriginalImage ? Color.accentColor : Color.accentColor.opacity(0.12))
                .cornerRadius(8)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressingOriginalImage {
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                isPressingOriginalImage = true
                            }
                        }
                        .onEnded { _ in
                            if isPressingOriginalImage {
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                isPressingOriginalImage = false
                            }
                        }
                )
            }
            .padding(.horizontal)
            
            if project.missions.isEmpty {
                VStack(spacing: 8) {
                    Text("すべてのピースが集まりました！")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button {
                        showCompletion = true
                    } label: {
                        Text("完成した作品を見る・保存する")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(project.missions) { mission in
                            missionCard(for: mission)
                                .onTapGesture {
                                    activeMission = mission
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
        }
    }
    
    // MARK: - ミッションカード
    private func missionCard(for mission: ColorMission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(mission.targetColor.swiftUIColor)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                
                Text(mission.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }
            
            Text("残り \(mission.remainingCount) マス")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Button {
                activeMission = mission
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                    Text("撮影する")
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
        }
        .padding(12)
        .frame(width: 170)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
    
    // MARK: - タイル詳細 & 差し替えシート
    private func tileDetailSheet(for tile: MosaicTile) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // タイル基本情報
                    HStack(spacing: 16) {
                        if let data = tile.thumbnailData, let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .cornerRadius(10)
                        } else {
                            tile.targetLabColor.swiftUIColor
                                .frame(width: 72, height: 72)
                                .cornerRadius(10)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("マス (\(tile.gridX + 1), \(tile.gridY + 1))")
                                .font(.headline)
                            Text("目標色: \(tile.targetLabColor.localizedName)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            if tile.isFilled {
                                Text("配置元: \(tile.origin == .captured ? "カメラ撮影 📸" : (tile.origin == .manuallySelected ? "手動選択 👑" : "自動配置 ⚡️"))")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            } else {
                                Text("状態: 未発見（撮影が必要です）")
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // アクション1: カメラ撮影
                    Button {
                        let mission = ColorMission(
                            targetColor: tile.targetLabColor,
                            targetSignature: tile.targetSignature,
                            title: tile.isFilled ? "ピース撮り直し: \(tile.targetLabColor.localizedName)" : nil,
                            targetTileIds: [tile.id]
                        )
                        selectedTile = nil
                        activeMission = mission
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tile.isFilled ? "arrow.triangle.2.circlepath.camera.fill" : "camera.fill")
                            Text(tile.isFilled ? "カメラで撮り直す" : "この色をカメラで撮影する")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(tile.isFilled ? Color.orange : Color.accentColor)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    
                    Divider()
                        .padding(.horizontal)
                    
                    // アクション2: 類似色写真から手動で選び直す
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundColor(.accentColor)
                            Text("ライブラリから選び直す")
                                .font(.headline)
                            if isLoadingCandidates {
                                Text("解析中…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        if replacementCandidates.isEmpty && !isLoadingCandidates {
                            Text("利用可能な類似写真が見つかりませんでした")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(replacementCandidates) { candidate in
                                        candidateCard(for: candidate, tileID: tile.id)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("ピースの確認・変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        selectedTile = nil
                    }
                }
            }
        }
    }
    
    // MARK: - 候補写真カード
    private func candidateCard(for candidate: PhotoMatchCandidate, tileID: UUID) -> some View {
        Button {
            let success = MosaicEngine.shared.replacePhoto(
                in: &project,
                tileID: tileID,
                with: candidate.photo
            )
            if success {
                selectedTile = nil
            }
        } label: {
            VStack(spacing: 6) {
                if let data = candidate.photo.thumbnailData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 84)
                        .cornerRadius(8)
                        .clipped()
                } else {
                    candidate.photo.labColor.swiftUIColor
                        .frame(width: 84, height: 84)
                        .cornerRadius(8)
                }
                
                Text("一致度 \(Int(candidate.matchRatio * 100))%")
                    .font(.caption2.bold())
                    .foregroundColor(.primary)
            }
            .padding(6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }
}
