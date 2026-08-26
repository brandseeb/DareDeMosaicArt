import SwiftUI
import AVKit
import Photos

#if canImport(UIKit)
import UIKit
#endif

/// タイムラプス動画プレビュー＆保存・SNS共有シート
public struct TimelapseExportView: View {
    public let project: MosaicProject
    @Environment(\.dismiss) private var dismiss
    
    @State private var isRendering: Bool = true
    @State private var renderProgress: Float = 0.0
    @State private var renderError: String? = nil
    @State private var videoURL: URL? = nil
    
    // AVQueuePlayer ＋ AVPlayerLooper による完全シームレスループ再生
    @State private var player: AVQueuePlayer? = nil
    @State private var playerLooper: AVPlayerLooper? = nil
    
    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var showShareSheet: Bool = false
    
    @State private var renderTask: Task<Void, Never>? = nil
    
    public init(project: MosaicProject) {
        self.project = project
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isRendering {
                    renderingProgressView
                } else if let error = renderError {
                    errorView(message: error)
                } else if let _ = videoURL, let player = player {
                    videoPreviewSection(player: player)
                }
            }
            .padding()
            .navigationTitle("制作タイムラプス動画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRendering ? "キャンセル" : "閉じる") {
                        cancelAndDismiss()
                    }
                }
            }
            .onAppear {
                startRendering()
            }
            .onDisappear {
                cleanupPlayerAndTask()
            }
        }
    }
    
    // MARK: - レンダリング中プログレス表示
    private var renderingProgressView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 100, height: 100)
                
                Circle()
                    .trim(from: 0.0, to: CGFloat(renderProgress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 100, height: 100)
                    .animation(.linear(duration: 0.1), value: renderProgress)
                
                Text("\(Int(renderProgress * 100))%")
                    .font(.title3.bold())
            }
            
            VStack(spacing: 6) {
                Text("制作ショート動画をレンダリング中...")
                    .font(.headline)
                Text("写真ピースの配置アニメーションと刻印を合成しています")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("作成を中止する") {
                cancelAndDismiss()
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.top, 8)
            
            Spacer()
        }
    }
    
    // MARK: - エラー表示
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("動画の作成に失敗しました")
                .font(.headline)
            
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("もう一度試す") {
                startRendering()
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .cornerRadius(10)
            
            Spacer()
        }
    }
    
    // MARK: - プレビュー＆保存・共有セクション
    private func videoPreviewSection(player: AVQueuePlayer) -> some View {
        VStack(spacing: 16) {
            // ループ再生 VideoPlayer (正方形)
            VideoPlayer(player: player)
                .aspectRatio(1.0, contentMode: .fit)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .frame(maxHeight: 340)
            
            HStack(spacing: 4) {
                Image(systemName: "repeat")
                    .font(.caption2)
                Text("10.0秒 / 1080p 正方形 (ショート動画用)")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            
            Spacer()
            
            // アクションボタン
            VStack(spacing: 10) {
                Button {
                    shareVideo()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("SNSや友達にシェアする")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
                
                Button {
                    saveVideoToPhotos()
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView().padding(.trailing, 4)
                        } else {
                            Image(systemName: saveSuccess ? "checkmark.circle.fill" : "arrow.down.to.line")
                        }
                        Text(saveSuccess ? "カメラロールに保存しました！" : "カメラロールに保存")
                    }
                    .font(.headline)
                    .foregroundColor(saveSuccess ? .green : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .disabled(isSaving || saveSuccess)
            }
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - レンダリング開始
    private func startRendering() {
        isRendering = true
        renderProgress = 0.0
        renderError = nil
        saveSuccess = false
        
        renderTask?.cancel()
        renderTask = Task {
            do {
                let url = try await TimelapseExportService.shared.exportTimelapse(
                    project: project
                ) { progress in
                    Task { @MainActor in
                        self.renderProgress = progress
                    }
                }
                
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                
                await MainActor.run {
                    self.videoURL = url
                    self.setupLooperPlayer(url: url)
                    self.isRendering = false
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.renderError = error.localizedDescription
                        self.isRendering = false
                    }
                }
            }
        }
    }
    
    // MARK: - AVPlayerLooper によるループセットアップ
    private func setupLooperPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        let looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        
        self.player = queuePlayer
        self.playerLooper = looper
        queuePlayer.play()
    }
    
    // MARK: - カメラロール保存
    private func saveVideoToPhotos() {
        guard let url = videoURL, !isSaving else { return }
        isSaving = true
        
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { success, error in
            Task { @MainActor in
                self.isSaving = false
                if success {
                    self.saveSuccess = true
                }
            }
        }
    }
    
    // MARK: - SNS共有
    private func shareVideo() {
        guard let url = videoURL else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(av, animated: true)
        }
    }
    
    private func cancelAndDismiss() {
        cleanupPlayerAndTask()
        dismiss()
    }
    
    private func cleanupPlayerAndTask() {
        renderTask?.cancel()
        renderTask = nil
        player?.pause()
        player = nil
        playerLooper = nil
        if let url = videoURL {
            try? FileManager.default.removeItem(at: url)
            self.videoURL = nil
        }
    }
}
