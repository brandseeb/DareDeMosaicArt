import SwiftUI

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
    @State private var selectedImage: UIImage? = nil
    @State private var title: String = "マイモザイクアート"
    @State private var gridSize: Int = 20 // デフォルト 20x20 = 400マス
    @State private var mode: GameMode = .hybrid
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
                
                // 3. 作成ボタン & 進捗表示
                Section {
                    if isCreating {
                        VStack(spacing: 12) {
                            ProgressView(value: scanner.scanProgress)
                            
                            if scanner.isScanning && scanner.totalPhotoCount > 0 {
                                Text("端末内の写真 \(scanner.processedCount) / \(scanner.totalPhotoCount) 枚 解析中...")
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
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
        }
    }
    
    private func handleStartButtonTapped() {
        guard !(gridSize > 20 && storeKit.proStatus == .loading) else { return }
        
        if gridSize > 20 && !storeKit.isProUser {
            showPaywall = true
            return
        }
        
        startGeneration()
    }
    
    private func startGeneration() {
        guard let rawImage = selectedImage else { return }
        // 高密度分割に合わせて解像度を適切に確保 (最大1200px)
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
            
            // 2. ハイブリッドモードの場合はライブラリから端末ローカル全写真を自動配置（写真重複なし）
            if mode == .hybrid {
                await MainActor.run {
                    self.statusMessage = "端末内の全写真をスキャン中..."
                }
                
                // 端末ローカル写真の全件をスキャン（iCloud通信なし）
                let photos = await scanner.scanAllLocalPhotos()
                
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
            }
            
            // 3. 不足色ミッションの生成
            let missions = MosaicEngine.shared.generateMissions(from: processedTiles)
            
            let newProject = MosaicProject(
                title: title.isEmpty ? "新しいモザイクアート" : title,
                targetImageData: imageData,
                gridWidth: gridSize,
                gridHeight: gridSize,
                mode: mode,
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
