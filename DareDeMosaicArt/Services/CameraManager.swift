import Foundation
import AVFoundation
import CoreImage

#if canImport(UIKit)
import UIKit
#endif

public enum CameraAvailabilityState: Equatable, Sendable {
    case checking
    case authorized
    case denied
    case restricted
    case unavailable
    case configurationFailed
}

/// カメラのリアルタイム映像キャプチャと色解析マネージャー（ファインダー枠完全同期）
public final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var session = AVCaptureSession()
    @Published public var currentLabColor: LabColor = LabColor(l: 50, a: 0, b: 0)
    @Published public var currentSignature: SpatialColorSignature? = nil
    @Published public var matchRatio: Float = 0.0
    @Published public var isMatchPass: Bool = false
    @Published public var isRunning: Bool = false
    @Published public var capturedImage: UIImage? = nil
    @Published public var availabilityState: CameraAvailabilityState = .checking
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.daredemosaic.camera.session")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var isConfigured = false
    
    /// 現在照合中のターゲット色
    public var targetColor: LabColor? {
        didSet {
            updateMatchCalculation()
        }
    }

    public var targetSignature: SpatialColorSignature? {
        didSet { updateMatchCalculation() }
    }
    
    /// 合格と判定する一致度しきい値
    public var passThreshold: Float = 0.60
    
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?
    
    public override init() {
        super.init()
    }
    
    /// 権限を確認し、許可済みのときだけカメラを初期化・起動する。
    public func prepareCamera() async {
        let initialStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let finalStatus: AVAuthorizationStatus
        if initialStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            finalStatus = granted ? .authorized : .denied
        } else {
            finalStatus = initialStatus
        }

        switch finalStatus {
        case .authorized:
            await MainActor.run { self.availabilityState = .authorized }
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                self.setupCameraIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        self.isRunning = true
                    }
                }
            }
        case .denied:
            stopSession()
            await MainActor.run { self.availabilityState = .denied }
        case .restricted:
            stopSession()
            await MainActor.run { self.availabilityState = .restricted }
        case .notDetermined:
            await MainActor.run { self.availabilityState = .checking }
        @unknown default:
            stopSession()
            await MainActor.run { self.availabilityState = .unavailable }
        }
    }

    /// カメラ初期化（sessionQueue上で実行）
    private func setupCameraIfNeeded() {
        guard !self.isConfigured else { return }
        self.session.beginConfiguration()
        self.session.inputs.forEach { self.session.removeInput($0) }
        self.session.outputs.forEach { self.session.removeOutput($0) }
        self.session.sessionPreset = .high
        
        // 背面カメラ取得
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.availabilityState = .unavailable }
            return
        }
        
        guard self.session.canAddInput(input) else {
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.availabilityState = .configurationFailed }
            return
        }
        self.session.addInput(input)
        
        // リアルタイム解析用ビデオ出力
        guard self.session.canAddOutput(self.videoOutput), self.session.canAddOutput(self.photoOutput) else {
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.availabilityState = .configurationFailed }
            return
        }
        self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.daredemosaic.camera.video"))
        self.videoOutput.alwaysDiscardsLateVideoFrames = true
        self.session.addOutput(self.videoOutput)
        if let connection = self.videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        
        // 静止画キャプチャ用出力
        self.session.addOutput(self.photoOutput)
        
        self.session.commitConfiguration()
        self.isConfigured = true
    }
    
    /// セッション開始
    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupCameraIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                }
            }
        }
    }
    
    /// セッション停止
    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }
    
    /// 写真撮影
    public func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, self.availabilityState == .authorized else {
                    continuation.resume(returning: nil)
                    return
                }
                self.photoContinuation = continuation
                let settings = AVCapturePhotoSettings()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    
    /// カメラリアルタイム判定（代表色の色味を主軸に判定）
    private func updateMatchCalculation() {
        guard let target = targetColor else {
            DispatchQueue.main.async {
                self.matchRatio = 0.0
                self.isMatchPass = false
            }
            return
        }
        
        let baseRatio = currentLabColor.matchRatio(to: target, maxDistance: 40.0)
        let pass = baseRatio >= passThreshold
        
        DispatchQueue.main.async {
            self.matchRatio = baseRatio
            self.isMatchPass = pass
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (リアルタイム解析)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        
        // 画面の正方形ファインダー枠と100%同じ「中央1:1正方形領域」をサンプリング
        let side = min(extent.width, extent.height)
        let sampleRect = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: sampleRect) else { return }
        let signature = ColorAnalysisService.shared.extractSpatialSignature(from: cgImage)
        
        DispatchQueue.main.async {
            self.currentSignature = signature
            self.currentLabColor = signature.average
            self.updateMatchCalculation()
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate (静止画撮影)
extension CameraManager: AVCapturePhotoCaptureDelegate {
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            photoContinuation?.resume(returning: nil)
            photoContinuation = nil
            return
        }
        
        photoContinuation?.resume(returning: image)
        photoContinuation = nil
    }
}
