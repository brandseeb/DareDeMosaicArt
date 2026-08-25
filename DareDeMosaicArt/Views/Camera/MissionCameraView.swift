import SwiftUI
import AVFoundation

#if canImport(UIKit)
import UIKit

/// レイヤー自体が AVCaptureVideoPreviewLayer である堅牢な UIView
final class VideoPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
}

/// カメラプレビューのUIViewラッパー（再表示時も確実に表示）
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> VideoPreviewUIView {
        let view = VideoPreviewUIView(frame: .zero)
        view.previewLayer.session = session
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        if uiView.previewLayer.session != session {
            uiView.previewLayer.session = session
        }
    }
}
#endif

/// 撮影ミッションカメラ画面（正方形ファインダー枠 ＋ 見た目通りのピース配置）
public struct MissionCameraView: View {
    public let mission: ColorMission
    public let onCaptured: (IndexedPhoto) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @StateObject private var cameraManager = CameraManager()
    @State private var isProcessing: Bool = false
    @State private var feedbackMessage: String? = nil
    @State private var showSuccessAnimation: Bool = false
    
    public init(
        mission: ColorMission,
        onCaptured: @escaping (IndexedPhoto) -> Void
    ) {
        self.mission = mission
        self.onCaptured = onCaptured
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let finderSize = min(geometry.size.width - 40, geometry.size.height * 0.45)
            
            ZStack {
                Color.black.ignoresSafeArea()
                
                #if canImport(UIKit)
                if cameraManager.availabilityState == .authorized {
                    CameraPreviewView(session: cameraManager.session)
                        .ignoresSafeArea()
                } else {
                    cameraFallbackOverlay
                }
                #endif
                
                if cameraManager.availabilityState == .authorized {
                    // 正方形ファインダー枠のマスクオーバーレイ（枠外を暗くして、枠内を明確に）
                    squareFinderMaskOverlay(screenSize: geometry.size, finderSize: finderSize)
                    
                    // 上部ミッションヘッダー
                    VStack {
                        HStack {
                            Button {
                                cameraManager.stopSession()
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(mission.title)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("残り \(mission.remainingCount) マス")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        }
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0.7), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        
                        Spacer()
                    }
                    
                    // 中央ファインダー枠 ＆ レティクル
                    ZStack {
                        // 正方形ファインダー枠
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(cameraManager.isMatchPass ? Color.green : Color.white.opacity(0.8), lineWidth: 3)
                            .frame(width: finderSize, height: finderSize)
                            .shadow(color: cameraManager.isMatchPass ? .green.opacity(0.5) : .clear, radius: 10)
                        
                        // 中央の色比較サークル
                        ColorReticleView(
                            targetColor: mission.targetColor,
                            currentColor: cameraManager.currentLabColor,
                            matchRatio: cameraManager.matchRatio,
                            isPass: cameraManager.isMatchPass
                        )
                    }
                    
                    // 下部UI（一致度メーター & シャッターボタン）
                    VStack(spacing: 14) {
                        Spacer()

                        if let feedbackMessage {
                            Text(feedbackMessage)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.red.opacity(0.88))
                                .cornerRadius(14)
                                .padding(.horizontal, 24)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        
                        // ヒント表示
                        Text(mission.hint)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(20)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        
                        // 一致度プログレスバー
                        VStack(spacing: 6) {
                            HStack {
                                Text("枠内の色の一致度")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(cameraManager.matchRatio * 100))%")
                                    .font(.caption.bold())
                                    .foregroundColor(cameraManager.isMatchPass ? .green : .white)
                            }
                            .padding(.horizontal, 40)
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 8)
                                    
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            LinearGradient(
                                                colors: cameraManager.isMatchPass ? [.green, .mint] : [.orange, .yellow],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(0, CGFloat(cameraManager.matchRatio) * geo.size.width), height: 8)
                                        .animation(.easeOut(duration: 0.15), value: cameraManager.matchRatio)
                                }
                            }
                            .frame(height: 8)
                            .padding(.horizontal, 40)
                        }
                        
                        // シャッターボタン
                        Button {
                            takePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(cameraManager.isMatchPass ? Color.green : Color.white, lineWidth: 4)
                                    .frame(width: 76, height: 76)
                                
                                Circle()
                                    .fill(cameraManager.isMatchPass ? Color.green : Color.white)
                                    .frame(width: 62, height: 62)
                            }
                        }
                        .disabled(isProcessing)
                        .padding(.bottom, 24)
                    }
                    
                    // 撮影成功時のポップアップ演出
                    if showSuccessAnimation {
                        ZStack {
                            Color.black.opacity(0.7).ignoresSafeArea()
                            
                            VStack(spacing: 16) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 64))
                                    .foregroundColor(.green)
                                
                                Text("ピース獲得！")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                
                                Text("モザイクアートにぴったりハマりました！")
                                    .font(.body)
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            .padding(32)
                            .background(Color(.darkGray).opacity(0.9))
                            .cornerRadius(20)
                            .scaleEffect(showSuccessAnimation ? 1.0 : 0.5)
                            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: showSuccessAnimation)
                        }
                    }
                }
            }
        }
        .task {
            cameraManager.targetColor = mission.targetColor
            cameraManager.targetSignature = mission.targetSignature
            cameraManager.passThreshold = mission.passThreshold
            await cameraManager.prepareCamera()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await cameraManager.prepareCamera() }
            }
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }

    /// 正方形ファインダー枠の外側を暗くマスクするビュー
    private func squareFinderMaskOverlay(screenSize: CGSize, finderSize: CGFloat) -> some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color.black.opacity(0.55)))
            
            let centerRect = CGRect(
                x: (size.width - finderSize) / 2,
                y: (size.height - finderSize) / 2,
                width: finderSize,
                height: finderSize
            )
            // 枠内をクリア（くり抜き）
            context.blendMode = .clear
            context.fill(Path(roundedRect: centerRect, cornerRadius: 16), with: .color(.black))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var cameraFallbackOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                switch cameraManager.availabilityState {
                case .checking:
                    ProgressView()
                        .tint(.white)
                    Text("カメラの権限を確認中…")
                        .foregroundColor(.white)

                case .denied:
                    fallbackMessage(
                        icon: "camera.fill",
                        title: "カメラへのアクセスが必要です",
                        message: "設定アプリで「カメラ」を許可すると、色探しミッションを続けられます。"
                    )
                    settingsButton

                case .restricted:
                    fallbackMessage(
                        icon: "lock.fill",
                        title: "カメラの使用が制限されています",
                        message: "スクリーンタイムや管理設定の制限を確認してください。"
                    )

                case .unavailable:
                    fallbackMessage(
                        icon: "camera.slash.fill",
                        title: "カメラを使用できません",
                        message: "この端末で利用できる背面カメラが見つかりませんでした。"
                    )

                case .configurationFailed:
                    fallbackMessage(
                        icon: "exclamationmark.triangle.fill",
                        title: "カメラを起動できませんでした",
                        message: "他のアプリがカメラを使用中でないか確認し、もう一度お試しください。"
                    )
                    Button("もう一度試す") {
                        Task { await cameraManager.prepareCamera() }
                    }
                    .buttonStyle(.borderedProminent)

                case .authorized:
                    EmptyView()
                }

                if cameraManager.availabilityState != .checking {
                    Button("ミッションに戻る") {
                        dismiss()
                    }
                    .foregroundColor(.white.opacity(0.85))
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
        }
    }

    private func fallbackMessage(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundColor(.white)
            Text(title)
                .font(.title3.bold())
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
        }
    }

    private var settingsButton: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            Label("設定アプリを開く", systemImage: "gear")
        }
        .buttonStyle(.borderedProminent)
    }
    
    private func takePhoto() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task {
            if let image = await cameraManager.capturePhoto() {
                // ファインダー枠で見えていた中央正方形領域（1:1）をそのまま丸ごと切り抜く
                guard let croppedImage = ImageUtils.cropCenterSquare(image: image, ratio: 1.0, maxDimension: 512),
                      let cgImage = croppedImage.cgImage else {
                    await MainActor.run {
                        feedbackMessage = "写真を解析できませんでした。もう一度お試しください。"
                        isProcessing = false
                    }
                    return
                }

                let signature = ColorAnalysisService.shared.extractSpatialSignature(from: cgImage)
                let matchRatio = signature.average.matchRatio(to: mission.targetColor, maxDistance: 40.0)

                guard matchRatio >= mission.passThreshold else {
                    await MainActor.run {
                        withAnimation {
                            feedbackMessage = retryAdvice(for: signature.average, target: mission.targetColor)
                        }
                        isProcessing = false
                    }
                    return
                }

                let thumbData = croppedImage.jpegData(compressionQuality: 0.85)
                
                let photo = IndexedPhoto(
                    id: UUID().uuidString,
                    labColor: signature.average,
                    signature: signature,
                    thumbnailData: thumbData
                )
                
                await MainActor.run {
                    feedbackMessage = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation {
                        showSuccessAnimation = true
                    }
                }
                
                // 1秒待ってから閉じる
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                cameraManager.stopSession()
                onCaptured(photo)
                dismiss()
            }
            isProcessing = false
        }
    }

    private func retryAdvice(for captured: LabColor, target: LabColor) -> String {
        let lightnessDelta = target.l - captured.l
        if lightnessDelta > 8 { return "もう少し明るい場所や光の当たる場所を狙ってみましょう。" }
        if lightnessDelta < -8 { return "もう少し暗い場所や影に近づけてみましょう。" }

        let redGreenDelta = target.a - captured.a
        if redGreenDelta > 9 { return "赤みがもう少し必要です。赤・オレンジ側の色を狙ってみましょう。" }
        if redGreenDelta < -9 { return "緑みがもう少し必要です。植物や緑の小物を探してみましょう。" }

        let yellowBlueDelta = target.b - captured.b
        if yellowBlueDelta > 9 { return "黄色みがもう少し必要です。暖色系の色を狙ってみましょう。" }
        if yellowBlueDelta < -9 { return "青みがもう少し必要です。空や青い小物に近づけてみましょう。" }
        return "ファインダー枠の中に、探している色を入れてみましょう！"
    }
}
