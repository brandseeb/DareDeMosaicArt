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
    @State private var includeAudio: Bool = true
    
    // AVQueuePlayer ＋ AVPlayerLooper による完全シームレスループ再生
    @State private var player: AVQueuePlayer? = nil
    @State private var playerLooper: AVPlayerLooper? = nil
    
    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var saveError: String? = nil
    @State private var shareItem: TimelapseShareItem? = nil
    
    @State private var renderTask: Task<Void, Never>? = nil
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var deferredCleanupURL: URL? = nil
    @State private var isViewVisible: Bool = false
    private let onClose: (() -> Void)?
    
    public init(project: MosaicProject, onClose: (() -> Void)? = nil) {
        self.project = project
        self.onClose = onClose
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
            .navigationTitle(Text(LocalizedStringResource("timelapse.navTitle", defaultValue: "制作タイムラプス動画")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRendering ? String(localized: "common.cancel", defaultValue: "キャンセル") : String(localized: "common.close", defaultValue: "閉じる")) {
                        cancelAndDismiss()
                    }
                }
            }
            .onAppear {
                isViewVisible = true
                startRendering()
            }
            .onDisappear {
                isViewVisible = false
                cleanupPlayerAndTask()
            }
            .alert(String(localized: "timelapse.alert.saveFailed.title", defaultValue: "動画を保存できません"), isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
                Button(String(localized: "common.openSettings", defaultValue: "設定を開く")) {
                    openAppSettings()
                }
            } message: {
                Text(saveError ?? String(localized: "timelapse.saveError.fallback"))
            }
            .sheet(item: $shareItem) { item in
                ActivityShareSheet(activityItems: [item.url])
                    .ignoresSafeArea()
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
                Text(LocalizedStringResource("timelapse.rendering.title", defaultValue: "制作ショート動画をレンダリング中..."))
                    .font(.headline)
                Text(LocalizedStringResource("timelapse.rendering.subtitle", defaultValue: "写真ピースの物理落下・立体影・効果音を合成しています"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button(String(localized: "timelapse.button.cancel", defaultValue: "作成を中止する")) {
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
            
            Text(LocalizedStringResource("timelapse.error.title", defaultValue: "動画の作成に失敗しました"))
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(String(localized: "common.retry", defaultValue: "再試行する")) {
                startRendering()
            }
            .font(.headline)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)
            
            Spacer()
        }
    }
    
    // MARK: - プレビュー＆保存・共有セクション
    private func videoPreviewSection(player: AVQueuePlayer) -> some View {
        VStack(spacing: 14) {
            // ループ再生 VideoPlayer (正方形)
            VideoPlayer(player: player)
                .aspectRatio(1.0, contentMode: .fit)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .frame(maxHeight: 320)
                .allowsHitTesting(false)
            
            // 効果音 ON / OFF 切替バー
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundColor(includeAudio ? .accentColor : .secondary)
                    Text(LocalizedStringResource("timelapse.setting.se"))
                        .font(.subheadline.bold())
                }
                Spacer()
                Toggle("", isOn: $includeAudio)
                    .labelsHidden()
                    .disabled(isSaving)
                    .onChange(of: includeAudio) { _, _ in
                        startRendering()
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            HStack(spacing: 4) {
                Image(systemName: "repeat")
                    .font(.caption2)
                Text(LocalizedStringResource("timelapse.format.spec"))
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            
            Spacer()
            
            // アクションボタン
            VStack(spacing: 10) {
                Button {
                    if let videoURL,
                       FileManager.default.fileExists(atPath: videoURL.path) {
                        shareItem = TimelapseShareItem(url: videoURL)
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(LocalizedStringResource("common.share"))
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
                .disabled(videoURL == nil)

                Button {
                    saveVideoToPhotos()
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView().padding(.trailing, 4)
                        } else {
                            Image(systemName: saveSuccess ? "checkmark.circle.fill" : "arrow.down.to.line")
                        }
                        Text(saveSuccess ? LocalizedStringResource("export.button.savedToPhotos", defaultValue: "カメラロールに保存しました！") : LocalizedStringResource("export.button.saveToPhotos", defaultValue: "カメラロールに保存"))
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
        let projectSnapshot = project
        let audioFlag = includeAudio
        
        renderTask = Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try await TimelapseExportService.shared.exportTimelapse(
                        project: projectSnapshot,
                        includeAudio: audioFlag
                    ) { progress in
                        Task { @MainActor in
                            self.renderProgress = progress
                        }
                    }
                }.value
                
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
        
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            performPhotoSave(url: url)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized || newStatus == .limited {
                        self.performPhotoSave(url: url)
                    } else {
                        self.isSaving = false
                        self.saveError = String(localized: "timelapse.saveError.accessNotAllowed")
                    }
                }
            }
        case .denied, .restricted:
            isSaving = false
            saveError = String(localized: "timelapse.saveError.openSettings")
        @unknown default:
            isSaving = false
            saveError = String(localized: "timelapse.saveError.unexpectedStatus")
        }
    }
    
    private func performPhotoSave(url: URL) {
        // プレビューとPhotoKitが同一MP4を同時に読み続けないよう、取り込み中は再生を一時停止する。
        player?.pause()
        saveTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await TimelapseExportService.shared.saveVideoToPhotoLibrary(at: url)
                }.value
                isSaving = false
                saveSuccess = true
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }

            if isViewVisible {
                player?.play()
            }

            // 画面を閉じても、PhotoKitがファイルの取り込みを完了するまでMP4を保持する。
            if let cleanupURL = deferredCleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
                deferredCleanupURL = nil
            }
            saveTask = nil
        }
    }
    
    private func openAppSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
    
    private func cancelAndDismiss() {
        cleanupPlayerAndTask()
        if let onClose = onClose {
            onClose()
        } else {
            dismiss()
        }
    }
    
    private func cleanupPlayerAndTask() {
        renderTask?.cancel()
        renderTask = nil
        player?.pause()
        player = nil
        playerLooper = nil
        if let url = videoURL {
            self.videoURL = nil
            if isSaving {
                deferredCleanupURL = url
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

public struct TimelapseShareItem: Identifiable {
    public let id = UUID()
    public let url: URL
}

#if canImport(UIKit)
public struct ActivityShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]
    public let applicationActivities: [UIActivity]? = nil

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
