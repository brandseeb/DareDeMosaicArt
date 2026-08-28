import SwiftUI
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// 新規モザイクアート作成設定画面
public struct ProjectSetupView: View {
    public let onCreated: (MosaicProject) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var scanner = PhotoLibraryScanner.shared
    @StateObject private var storeKit = StoreKitManager.shared
    
    @State private var showPickerSheet: Bool = false
    @State private var showPaywall: Bool = false
    @State private var showAlbumPickerSheet: Bool = false
    @State private var showLimitedAccessAlert: Bool = false
    @State private var showPermissionDeniedAlert: Bool = false
    @State private var showAlbumNotFoundAlert: Bool = false
    @State private var showGeneralErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var albumNotFoundMessage: String = ""
    
    @State private var selectedImage: UIImage? = nil
    @State private var title: String = "マイモザイクアート"
    @State private var gridSize: Int = 20
    @State private var mode: GameMode = .hybrid
    @State private var selectedPhotoSource: PhotoSource = .allLocalPhotos
    @State private var userAlbums: [PhotoAlbumItem] = []
    
    @State private var isCreating: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var creationStage: MosaicCreationStage = .slicing(current: 0, total: 100)
    
    public init(onCreated: @escaping (MosaicProject) -> Void) {
        self.onCreated = onCreated
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                // 1. 元画像選択
                Section(header: Text("1. 元になる画像を選ぶ")) {
                    if let img = selectedImage {
                        VStack {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(1.0, contentMode: .fit)
                                .frame(maxHeight: 220)
                                .cornerRadius(12)
                            
                            Button {
                                showPickerSheet = true
                            } label: {
                                Text("画像を変更する")
                                    .font(.subheadline)
                            }
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else {
                        Button {
                            showPickerSheet = true
                        } label: {
                            HStack {
                                Spacer()
                                VStack(spacing: 12) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 40))
                                        .foregroundColor(.accentColor)
                                    Text("写真ライブラリから画像を選択")
                                        .font(.headline)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 24)
                        }
                    }
                }
                
                // 2. 基本設定
                Section(header: Text("2. 設定")) {
                    TextField("作品のタイトル", text: $title)
                    
                    Picker("マスの細かさ", selection: $gridSize) {
                        Text("10 × 10 (100マス・かんたん)").tag(10)
                        Text("15 × 15 (225マス・標準)").tag(15)
                        Text("20 × 20 (400マス・本格派)").tag(20)
                        
                        // 25x25以上はPro限定
                        Text("25 × 25 (625マス・細密 👑Pro)").tag(25)
                        Text("30 × 30 (900マス・高精細 👑Pro)").tag(30)
                        Text("40 × 40 (1,600マス・大作 👑Pro)").tag(40)
                        Text("50 × 50 (2,500マス・超大作 👑Pro)").tag(50)
                        Text("60 × 60 (3,600マス・究極 👑Pro)").tag(60)
                    }
                    .onChange(of: gridSize) { _, newSize in
                        if newSize > 20 && !storeKit.isProUser && storeKit.proStatus != .loading {
                            showPaywall = true
                        }
                    }
                    
                    Picker("プレイスタイル", selection: $mode) {
                        ForEach(GameMode.allCases, id: \.self) { m in
                            Text(m.localizedTitle).tag(m)
                        }
                    }
                    
                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // 3. 写真ソース選択（ハイブリッドモード時のみ）
                if mode == .hybrid {
                    Section(header: Text("3. 使用する写真素材")) {
                        Button {
                            selectedPhotoSource = .allLocalPhotos
                        } label: {
                            HStack {
                                Image(systemName: selectedPhotoSource == .allLocalPhotos ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedPhotoSource == .allLocalPhotos ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("端末内のすべての写真")
                                        .foregroundColor(.primary)
                                    Text("カメラロール内の保存済み写真すべてからマッチング")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Button {
                            handleAlbumSourceSelected()
                        } label: {
                            HStack {
                                Image(systemName: selectedPhotoSource != .allLocalPhotos ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedPhotoSource != .allLocalPhotos ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("特定のアルバムを指定")
                                            .foregroundColor(.primary)
                                        Text("👑Pro")
                                            .font(.caption2.bold())
                                            .foregroundColor(.orange)
                                    }
                                    if case .album(_, let albumTitle) = selectedPhotoSource {
                                        Text("選択中: \(albumTitle)")
                                            .font(.caption.bold())
                                            .foregroundColor(.accentColor)
                                    } else {
                                        Text("旅行・結婚式・推し活など、思い出のフォルダから作成")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // 4. 作成ボタン & 1本の統合進捗バー表示
                Section {
                    if isCreating {
                        unifiedProgressView
                            .padding(.vertical, 8)
                    } else {
                        Button {
                            handleStartButtonTapped()
                        } label: {
                            HStack {
                                if gridSize > 20 && storeKit.proStatus == .loading {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 4)
                                }
                                Text("モザイクアートを作成開始！")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                (selectedImage == nil || (gridSize > 20 && storeKit.proStatus == .loading))
                                ? Color.gray
                                : Color.accentColor
                            )
                            .cornerRadius(10)
                        }
                        .disabled(selectedImage == nil || (gridSize > 20 && storeKit.proStatus == .loading))
                    }
                }
            }
            .navigationTitle("新規プロジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPickerSheet) {
                PhotoPickerSheet { pickedImage in
                    self.selectedImage = pickedImage
                }
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywallView()
            }
            .sheet(isPresented: $showAlbumPickerSheet) {
                albumSelectionView
            }
            .alert("写真へのフルアクセスが必要です", isPresented: $showLimitedAccessAlert) {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("特定のアルバムを指定するには、設定で「すべての写真へのアクセス」を許可してください。")
            }
            .alert("写真へのアクセスが許可されていません", isPresented: $showPermissionDeniedAlert) {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真素材をスキャンしてモザイクを生成するために、設定アプリで写真へのアクセスを許可してください。")
            }
            .alert("アルバムが見つかりません", isPresented: $showAlbumNotFoundAlert) {
                Button("別のアルバムを選ぶ") {
                    showAlbumPickerSheet = true
                }
                Button("端末内の全写真を使用する") {
                    selectedPhotoSource = .allLocalPhotos
                    startGeneration()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(albumNotFoundMessage)
            }
            .alert("エラー", isPresented: $showGeneralErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                scanner.checkPermission()
            }
        }
    }
    
    // MARK: - 1本の統合プログレスバー & 4段階ステップ表示 UI
    private var unifiedProgressView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ヘッダー: ステージタイトル & パーセント表示
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: creationStage.iconName)
                        .foregroundColor(.accentColor)
                        .font(.subheadline.bold())
                    Text(creationStage.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                }
                Spacer()
                Text("\(Int(overallProgress * 100))%")
                    .font(.system(.subheadline, design: .monospaced).bold())
                    .foregroundColor(.accentColor)
            }
            
            // 1本のシームレス・グラデーションプログレスバー
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.8), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * CGFloat(overallProgress)), height: 8)
                        .animation(.easeInOut(duration: 0.25), value: overallProgress)
                }
            }
            .frame(height: 8)
            
            // 4ステップの進行状況インジケーター
            HStack(spacing: 4) {
                ForEach(MosaicCreationStep.allCases, id: \.self) { step in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(stepColor(for: step))
                            .frame(width: 7, height: 7)
                        Text(step.shortName)
                            .font(.system(size: 10, weight: stepFontWeight(for: step)))
                            .foregroundColor(stepTextColor(for: step))
                    }
                    if step != MosaicCreationStep.allCases.last {
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.4))
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 2)
            
            // 詳細進捗テキスト
            VStack(alignment: .leading, spacing: 3) {
                Text(creationStage.detailMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let subMessage = creationStage.subMessage {
                    Text(subMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
        }
    }
    
    private func stepColor(for step: MosaicCreationStep) -> Color {
        let currentStep = creationStage.step
        if step.rawValue < currentStep.rawValue {
            return .green // 完了
        } else if step == currentStep {
            return .accentColor // 進行中
        } else {
            return Color(.systemGray4) // 待機
        }
    }
    
    private func stepTextColor(for step: MosaicCreationStep) -> Color {
        let currentStep = creationStage.step
        if step.rawValue < currentStep.rawValue {
            return .primary
        } else if step == currentStep {
            return .accentColor
        } else {
            return .secondary.opacity(0.6)
        }
    }
    
    private func stepFontWeight(for step: MosaicCreationStep) -> Font.Weight {
        return step == creationStage.step ? .bold : .regular
    }
    
    // MARK: - アルバム選択シート
    private var albumSelectionView: some View {
        NavigationStack {
            List {
                if userAlbums.isEmpty {
                    Text("ユーザー作成のアルバムが見つかりませんでした。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(userAlbums) { album in
                        Button {
                            selectedPhotoSource = .album(localIdentifier: album.id, title: album.title)
                            showAlbumPickerSheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(album.assetCount) 枚の写真")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if case .album(let id, _) = selectedPhotoSource, id == album.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("アルバムを選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        showAlbumPickerSheet = false
                    }
                }
            }
            .onAppear {
                self.userAlbums = scanner.fetchUserAlbums()
            }
        }
    }
    
    private func handleAlbumSourceSelected() {
        guard storeKit.isProUser else {
            showPaywall = true
            return
        }
        
        scanner.checkPermission()
        
        switch scanner.authorizationStatus {
        case .authorized:
            self.userAlbums = scanner.fetchUserAlbums()
            showAlbumPickerSheet = true
            
        case .limited:
            showLimitedAccessAlert = true
            
        case .denied, .restricted:
            showPermissionDeniedAlert = true
            
        case .notDetermined:
            Task {
                let granted = await scanner.requestPermission()
                if granted {
                    if scanner.authorizationStatus == .authorized {
                        self.userAlbums = scanner.fetchUserAlbums()
                        showAlbumPickerSheet = true
                    } else if scanner.authorizationStatus == .limited {
                        showLimitedAccessAlert = true
                    }
                } else {
                    showPermissionDeniedAlert = true
                }
            }
            
        @unknown default:
            showPermissionDeniedAlert = true
        }
    }
    
    private func handleStartButtonTapped() {
        guard !(gridSize > 20 && storeKit.proStatus == .loading) else { return }
        
        if gridSize > 20 && !storeKit.isProUser {
            showPaywall = true
            return
        }
        
        if selectedPhotoSource != .allLocalPhotos && !storeKit.isProUser {
            showPaywall = true
            return
        }
        
        startGeneration()
    }
    
    @MainActor
    private func updateSliceProgress(current: Int, total: Int) {
        let stageRatio = Double(current) / Double(max(1, total))
        self.overallProgress = 0.02 + stageRatio * 0.13
        self.creationStage = .slicing(current: current, total: total)
    }
    
    @MainActor
    private func updateMatchProgress(current: Int, total: Int) {
        let matchRatio = Double(current) / Double(max(1, total))
        self.overallProgress = 0.75 + matchRatio * 0.20
        self.creationStage = .matching(current: current, total: total)
    }
    
    private func startGeneration() {
        guard let rawImage = selectedImage else { return }
        let image = ImageUtils.normalizeOrientationAndFit(image: rawImage, maxDimension: 1200)
        guard let cgImage = image.cgImage else { return }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        
        let totalTilesCount = gridSize * gridSize
        isCreating = true
        overallProgress = 0.02
        creationStage = .slicing(current: 0, total: totalTilesCount)
        
        Task {
            // 1. グリッド分割 & 高精度空間色シグネチャ抽出 (全体の 0% 〜 15%)
            let selectedGridSize = gridSize
            let tiles = await Task.detached(priority: .userInitiated) {
                ColorAnalysisService.shared.sliceTargetImage(
                    cgImage: cgImage,
                    gridWidth: selectedGridSize,
                    gridHeight: selectedGridSize
                ) { current, total in
                    Task { @MainActor [self] in
                        self.updateSliceProgress(current: current, total: total)
                    }
                }
            }.value
            
            var processedTiles = tiles
            
            // 2. ハイブリッドモードの場合は指定ソースから写真をスキャンして自動配置 (全体の 15% 〜 75%)
            if mode == .hybrid {
                self.overallProgress = 0.15
                self.creationStage = .scanning(processed: 0, total: scanner.totalPhotoCount, localAvailable: 0)
                
                // PhotoLibraryScanner の進行状況を監視して 15%〜75% にマッピング
                let progressTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        if self.scanner.isScanning {
                            let scanRatio = Double(self.scanner.scanProgress)
                            self.overallProgress = 0.15 + scanRatio * 0.60
                            self.creationStage = .scanning(
                                processed: self.scanner.processedCount,
                                total: self.scanner.totalPhotoCount,
                                localAvailable: self.scanner.localAvailableCount
                            )
                        }
                    }
                }
                
                let photos: [IndexedPhoto]
                do {
                    photos = try await scanner.scanPhotos(source: selectedPhotoSource)
                    progressTask.cancel()
                } catch let error as PhotoLibraryScannerError {
                    progressTask.cancel()
                    self.isCreating = false
                    switch error {
                    case .permissionDenied:
                        self.showPermissionDeniedAlert = true
                    case .albumNotFound(let albumTitle):
                        self.albumNotFoundMessage = "指定されたアルバム「\(albumTitle)」が見つかりません。削除された可能性があります。"
                        self.showAlbumNotFoundAlert = true
                    case .cancelled:
                        break
                    }
                    return
                } catch {
                    progressTask.cancel()
                    self.isCreating = false
                    self.errorMessage = "写真の取得中にエラーが発生しました: \(error.localizedDescription)"
                    self.showGeneralErrorAlert = true
                    return
                }
                
                // 3. 多次元ベストマッチ探索 & Kuhn二部マッチング (全体の 75% 〜 95%)
                self.overallProgress = 0.75
                self.creationStage = .matching(current: 0, total: tiles.count)
                
                processedTiles = await Task.detached(priority: .userInitiated) {
                    MosaicEngine.shared.matchTiles(
                        tiles: tiles,
                        availablePhotos: photos,
                        allowDuplicates: false,
                        passDistanceThreshold: 0.38
                    ) { current, total in
                        Task { @MainActor [self] in
                            self.updateMatchProgress(current: current, total: total)
                        }
                    }
                }.value
            } else {
                // 撮影専用モードの場合はスキップして直接仕上げへ
                self.overallProgress = 0.90
            }
            
            // 4. 不足色ミッションの生成 & 仕上げ (全体の 95% 〜 100%)
            self.overallProgress = 0.96
            self.creationStage = .finalizing
            
            let missions = MosaicEngine.shared.generateMissions(from: processedTiles)
            
            let newProject = MosaicProject(
                title: title.isEmpty ? "新しいモザイクアート" : title,
                targetImageData: imageData,
                gridWidth: gridSize,
                gridHeight: gridSize,
                mode: mode,
                photoSource: selectedPhotoSource,
                tiles: processedTiles,
                missions: missions,
                isCompleted: processedTiles.allSatisfy { $0.isFilled }
            )
            
            self.overallProgress = 1.0
            try? await Task.sleep(for: .milliseconds(200))
            self.isCreating = false
            self.onCreated(newProject)
            self.dismiss()
        }
    }
}

// MARK: - 4段階ステップ定義
public enum MosaicCreationStep: Int, CaseIterable, Sendable {
    case slicing = 0
    case scanning = 1
    case matching = 2
    case finalizing = 3
    
    public var shortName: String {
        switch self {
        case .slicing: return "① 分割解析"
        case .scanning: return "② 写真解析"
        case .matching: return "③ 最適探索"
        case .finalizing: return "④ 仕上げ"
        }
    }
}

// MARK: - 進行中ステージモデル
public enum MosaicCreationStage: Sendable {
    case slicing(current: Int, total: Int)
    case scanning(processed: Int, total: Int, localAvailable: Int)
    case matching(current: Int, total: Int)
    case finalizing
    
    public var step: MosaicCreationStep {
        switch self {
        case .slicing: return .slicing
        case .scanning: return .scanning
        case .matching: return .matching
        case .finalizing: return .finalizing
        }
    }
    
    public var iconName: String {
        switch self {
        case .slicing: return "square.grid.3x3.square"
        case .scanning: return "photo.stack"
        case .matching: return "wand.and.stars"
        case .finalizing: return "checkmark.seal.fill"
        }
    }
    
    public var title: String {
        switch self {
        case .slicing: return "画像のグリッド分割・解析中"
        case .scanning: return "写真素材のスキャン・解析中"
        case .matching: return "ベストマッチ写真を探索・配置中"
        case .finalizing: return "モザイクアートを完成中"
        }
    }
    
    public var detailMessage: String {
        switch self {
        case .slicing(let current, let total):
            return total > 0 ? "マスごとの空間色とエッジを解析中 (\(current)/\(total) マス)" : "画像を分割中..."
        case .scanning(let processed, let total, _):
            return total > 0 ? "写真素材の特徴量を解析中 (\(processed)/\(total) 枚)" : "写真ライブラリを読み込み中..."
        case .matching(let current, let total):
            return total > 0 ? "構図・グラデーション・明暗から最適配置を計算中 (\(current)/\(total) マス)" : "最適な写真を選択中..."
        case .finalizing:
            return "不足色ミッションとプロジェクトデータを構築しています..."
        }
    }
    
    public var subMessage: String? {
        switch self {
        case .slicing:
            return "48×48 Sobelエッジと明暗重心を抽出"
        case .scanning(_, _, let available):
            return available > 0 ? "端末内に保存済みの \(available) 枚を使用中" : nil
        case .matching:
            return "多次元空間インデックスと二部マッチングで最適化"
        case .finalizing:
            return "まもなく作品が完成します！"
        }
    }
}
