import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// モザイクアート作成・進行ワークスペース画面
public struct MosaicWorkspaceView: View {
    @Binding public var project: MosaicProject
    @Environment(\.dismiss) private var dismiss
    
    @State private var activeMission: ColorMission? = nil
    @State private var selectedTile: MosaicTile? = nil
    @State private var showCamera: Bool = false
    @State private var showCompletion: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var showGuideImage: Bool = false
    @State private var guideOpacity: Double = 0.5
    
    public init(project: Binding<MosaicProject>) {
        self._project = project
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 上部プログレスバー
                progressHeader
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .zIndex(2)
                
                // キャンバストップツールバー（全体表示 / ズーム / 下絵ガイド）
                canvasToolbar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemBackground))
                    .zIndex(2)
                
                // メインキャンバス（画面サイズに合わせて正方形全体表示 & はみ出し防止クリップ）
                ZStack {
                    MosaicCanvasView(
                        project: project,
                        selectedTileId: selectedTile?.id,
                        showGuideImage: showGuideImage,
                        guideOpacity: guideOpacity,
                        zoomScale: $zoomScale,
                        offset: $canvasOffset
                    ) { tile in
                        selectedTile = tile
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipped() // ズーム時の絵柄が上下のツールバーに被さるのを完全に遮断
                .zIndex(1)
                
                // 下部ミッションセクション
                missionSection
                    .padding(.top, 8)
                    .background(Color(.secondarySystemBackground))
                    .zIndex(2)
            }
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCompletion = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .fullScreenCover(item: $activeMission) { mission in
                MissionCameraView(mission: mission) { capturedPhoto in
                    handleCapturedPhoto(capturedPhoto, mission: mission)
                }
            }
            .sheet(isPresented: $showCompletion) {
                CompletionView(project: project)
            }
            .sheet(item: $selectedTile) { tile in
                tileDetailSheet(for: tile)
                    .presentationDetents([.fraction(0.35)])
            }
        }
    }
    
    // MARK: - プログレスヘッダー
    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Text("完成度")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(project.filledTilesCount) / \(project.totalTilesCount) ピース (\(project.progressPercentageString))")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
            }
            
            ProgressView(value: Double(project.progress))
                .tint(project.isCompleted ? .green : .accentColor)
        }
    }
    
    // MARK: - キャンバスツールバー
    private var canvasToolbar: some View {
        HStack(spacing: 12) {
            // 下絵（元画像）ガイドトグル
            Button {
                withAnimation {
                    showGuideImage.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showGuideImage ? "eye.fill" : "eye.slash")
                    Text(showGuideImage ? "下絵 ON" : "下絵 OFF")
                }
                .font(.caption.bold())
                .foregroundColor(showGuideImage ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(showGuideImage ? Color.accentColor : Color(.systemGray5))
                .cornerRadius(14)
            }
            
            Spacer()
            
            // ズームリセット / 全体表示ボタン（スケールと位置を同時に中央リセット）
            if zoomScale > 1.05 || canvasOffset != .zero {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                        canvasOffset = .zero
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                        Text("全体表示に戻す")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
                }
            } else {
                Text("ピンチで拡大 / ダブルタップでリセット")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
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
    
    // MARK: - タイル詳細シート
    private func tileDetailSheet(for tile: MosaicTile) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                if let data = tile.thumbnailData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .cornerRadius(10)
                } else {
                    tile.targetLabColor.swiftUIColor
                        .frame(width: 80, height: 80)
                        .cornerRadius(10)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("マス (\(tile.gridX + 1), \(tile.gridY + 1))")
                        .font(.headline)
                    Text("目標色: \(tile.targetLabColor.localizedName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if tile.isFilled {
                        Text("状態: ピース配置済み ✨")
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
            .padding()
            
            // 撮影・再撮影ボタン
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
                    Text(tile.isFilled ? "このピースを撮り直す" : "この色をカメラで撮影する")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(tile.isFilled ? Color.orange : Color.accentColor)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            
            Spacer()
        }
    }
    
    // MARK: - 撮影完了処理
    private func handleCapturedPhoto(_ photo: IndexedPhoto, mission: ColorMission) {
        _ = MosaicEngine.shared.tryFitCapturedPhoto(
            capturedPhoto: photo,
            in: &project,
            targetMission: mission
        )
        
        if project.isCompleted {
            showCompletion = true
        }
    }
}
