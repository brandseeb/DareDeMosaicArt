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
    @State private var statusMessage: String = ""
    
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
                            Text(m.rawValue).tag(m)
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
                
                // 4. 作成ボタン & 進捗表示
                Section {
                    if isCreating {
                        VStack(spacing: 12) {
                            ProgressView(value: scanner.scanProgress)
                            
                            if scanner.isScanning && scanner.totalPhotoCount > 0 {
                                VStack(spacing: 4) {
                                    Text("写真 \(scanner.processedCount) / \(scanner.totalPhotoCount) 枚 解析中...")
                                        .font(.caption.bold())
                                        .foregroundColor(.primary)
                                    Text("端末保存済みの \(scanner.localAvailableCount) 枚を使用")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
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
        
        if scanner.authorizationStatus == .limited {
            showLimitedAccessAlert = true
            return
        }
        
        self.userAlbums = scanner.fetchUserAlbums()
        showAlbumPickerSheet = true
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
    
    private func startGeneration() {
        guard let rawImage = selectedImage else { return }
        let image = ImageUtils.normalizeOrientationAndFit(image: rawImage, maxDimension: 1200)
        guard let cgImage = image.cgImage else { return }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        
        isCreating = true
        statusMessage = "画像をグリッド分割中..."
        
        Task {
            // 1. グリッド分割 & 目標Lab色抽出
            let selectedGridSize = gridSize
            let tiles = await Task.detached(priority: .userInitiated) {
                ColorAnalysisService.shared.sliceTargetImage(
                    cgImage: cgImage,
                    gridWidth: selectedGridSize,
                    gridHeight: selectedGridSize
                )
            }.value
            
            var processedTiles = tiles
            
            // 2. ハイブリッドモードの場合は指定ソースから写真をスキャンして自動配置
            if mode == .hybrid {
                await MainActor.run {
                    self.statusMessage = "写真素材をスキャン中..."
                }
                
                do {
                    let photos = try await scanner.scanPhotos(source: selectedPhotoSource)
                    
                    await MainActor.run {
                        self.statusMessage = "\(photos.count) 枚の写真からベストマッチを探索中..."
                    }
                    
                    processedTiles = await Task.detached(priority: .userInitiated) {
                        MosaicEngine.shared.matchTiles(
                            tiles: tiles,
                            availablePhotos: photos,
                            allowDuplicates: false,
                            passDistanceThreshold: 14.0
                        )
                    }.value
                } catch let error as PhotoLibraryScannerError {
                    await MainActor.run {
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
                    }
                    return
                } catch {
                    await MainActor.run {
                        self.isCreating = false
                        self.errorMessage = "写真の取得中にエラーが発生しました: \(error.localizedDescription)"
                        self.showGeneralErrorAlert = true
                    }
                    return
                }
            }
            
            // 3. 不足色ミッションの生成
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
            
            await MainActor.run {
                self.isCreating = false
                self.onCreated(newProject)
                self.dismiss()
            }
        }
    }
}
