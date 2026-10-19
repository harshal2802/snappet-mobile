import AVFoundation
import UIKit
import Observation

/// **The in-app camera's AVFoundation edge** (prompt 190): one capture session with the back camera's virtual
/// multi-lens device (ultra-wide · wide · telephoto, so zoom glides across lenses like the iPhone Camera) or the
/// front camera, a movie output (video + slo-mo, with audio) and a photo output (stills — also mid-clip).
/// It applies `CameraSettings` to the hardware: the format for the resolution · frame rate (or slo-mo rate),
/// stabilization, torch, zoom, and focus / exposure at a point (tap) or locked (long-press). The rules live in the
/// pure `CameraLogic`; this only talks to the device.
///
/// Main-actor, like `SnappetQRScannerController`: configuration is quick and happens here; only the blocking
/// `startRunning` / `stopRunning` go to a background queue (the session isn't `Sendable` — handed over as
/// `nonisolated(unsafe)`). Delegate callbacks hop back to the main actor.
///
/// `fake` (the simulator under `-uiTestFakeCamera`) runs no session — `CameraCapabilities.sample`, a pretend
/// recording — so the camera's controls are exercisable in UI tests.
@MainActor
@Observable
final class CameraController: NSObject {
    static let fakeArgument = "-uiTestFakeCamera"

    /// A real camera exists (never on the simulator), or the UI-test fake is on.
    static var isAvailable: Bool {
        if ProcessInfo.processInfo.arguments.contains(fakeArgument) { return true }
        #if targetEnvironment(simulator)
        return false
        #else
        return AVCaptureDevice.default(for: .video) != nil
        #endif
    }

    /// Camera (required) + microphone (best-effort — a denied mic records silent video).
    static func requestAccess() async -> Bool {
        if ProcessInfo.processInfo.arguments.contains(fakeArgument) { return true }
        func access(_ media: AVMediaType) async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: media) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
            default: return false
            }
        }
        guard await access(.video) else { return false }
        _ = await access(.audio)
        return true
    }

    let fake: Bool
    let session = AVCaptureSession()
    private(set) var capabilities = CameraCapabilities.sample
    private(set) var position: AVCaptureDevice.Position = .back
    /// Display zoom (1 = the wide lens; 0.5 = ultra-wide).
    private(set) var zoom: Double = 1
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var torchOn = false
    private(set) var focusLocked = false
    private(set) var configured = false

    /// A finished video (temp file) and when it started; a still (HEIC/JPEG data) and when it was taken.
    var onMovie: ((URL, Date) -> Void)?
    var onPhoto: ((Data, Date) -> Void)?

    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    /// Display zoom = device zoom × this (0.5 on a phone whose virtual device starts at the ultra-wide).
    private var zoomMultiplier: Double = 1
    private var settings = CameraSettings()

    init(fake: Bool = ProcessInfo.processInfo.arguments.contains(CameraController.fakeArgument)) {
        self.fake = fake
        super.init()
    }

    // MARK: - Session

    func start(with settings: CameraSettings) {
        self.settings = settings
        guard !fake else { configured = true; return }
        if !configured { configure(position: .back) }
        apply(settings)
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        if isRecording { stopRecording() }
        setTorch(false)
        guard !fake else { return }
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    private func configure(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let videoInput { session.removeInput(videoInput) }
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        guard let device = types.lazy.compactMap({ t in found.first { $0.deviceType == t } }).first,
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        self.device = device
        self.videoInput = input
        self.position = position
        if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let a = try? AVCaptureDeviceInput(device: mic), session.canAddInput(a) {
            session.addInput(a)
            audioInput = a
        }
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        zoomMultiplier = Double(device.displayVideoZoomFactorMultiplier)
        let lensFactors = [1.0] + device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        let hasFront = !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                         position: .front).devices.isEmpty
        capabilities = CameraCapabilities.from(
            formats: device.formats.map { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return .init(width: Int(d.width), height: Int(d.height),
                             maxFPS: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
            },
            lenses: position == .back ? lensFactors.map { $0 * zoomMultiplier } : [],
            minZoom: Double(device.minAvailableVideoZoomFactor) * zoomMultiplier,
            maxZoom: min(Double(device.maxAvailableVideoZoomFactor), 15 / zoomMultiplier) * zoomMultiplier,
            hasTorch: device.hasTorch, hasFront: hasFront,
            enhancedStabilization: device.formats.contains {
                $0.isVideoStabilizationModeSupported(.cinematicExtended) || $0.isVideoStabilizationModeSupported(.cinematic)
            })
        zoom = 1
        configured = true
    }

    /// Point the hardware at `settings` (already resolved against `capabilities`).
    func apply(_ settings: CameraSettings) {
        self.settings = settings
        guard !fake, let device else { return }
        session.beginConfiguration()
        if settings.mode == .photo {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        } else {
            let res = settings.mode == .slomo ? CameraResolution.hd : settings.resolution
            let fps = Double(settings.mode == .slomo ? settings.slomoFPS : settings.fps)
            let format = device.formats.first { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return Int(d.width) == res.width && Int(d.height) == res.height
                    && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate + 0.5 }
                    && (settings.stabilization == .standard || f.isVideoStabilizationModeSupported(.cinematic))
            } ?? device.formats.first { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return Int(d.width) == res.width && Int(d.height) == res.height
                    && f.videoSupportedFrameRateRanges.contains { fps <= $0.maxFrameRate + 0.5 }
            }
            if let format, (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            }
            if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                let enhanced: AVCaptureVideoStabilizationMode =
                    device.activeFormat.isVideoStabilizationModeSupported(.cinematicExtended) ? .cinematicExtended : .cinematic
                connection.preferredVideoStabilizationMode = settings.stabilization == .enhanced ? enhanced : .standard
            }
        }
        session.commitConfiguration()
        setZoom(zoom, animated: false)
    }

    // MARK: - Controls

    func flip() {
        guard !isRecording else { return }
        guard !fake else { position = position == .back ? .front : .back; return }
        setTorch(false)
        configure(position: position == .back ? .front : .back)
        apply(settings)
    }

    func setZoom(_ display: Double, animated: Bool) {
        let z = CameraLogic.clampZoom(display, capabilities)
        zoom = z
        guard !fake, let device, (try? device.lockForConfiguration()) != nil else { return }
        let factor = CGFloat(z / zoomMultiplier)
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if animated { device.ramp(toVideoZoomFactor: clamped, withRate: 8) } else { device.videoZoomFactor = clamped }
        device.unlockForConfiguration()
    }

    func setTorch(_ on: Bool) {
        torchOn = on && capabilities.hasTorch && position == .back
        guard !fake, let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    /// Focus + expose at a point (0…1 in the device's coordinate space). `lock` holds both there (AE/AF LOCK) so the
    /// camera doesn't hunt when the climber moves; a plain tap returns to continuous auto.
    func focus(at point: CGPoint, lock: Bool) {
        focusLocked = lock
        guard !fake, let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        let focus: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
        let exposure: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
        if device.isFocusModeSupported(focus) { device.focusMode = focus }
        if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
        device.unlockForConfiguration()
        guard lock else { return }
        // Hold what the one-shot focus / exposure settled on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.focusLocked, let device = self.device,
                      (try? device.lockForConfiguration()) != nil else { return }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
            }
        }
    }

    func unlockFocus() {
        focus(at: CGPoint(x: 0.5, y: 0.5), lock: false)
    }

    // MARK: - Capture

    func startRecording() {
        guard !isRecording else { return }
        recordingStartedAt = Date()
        isRecording = true
        guard !fake else { return }
        if let connection = movieOutput.connection(with: .video), let rotation {
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if position == .front { connection.isVideoMirrored = true }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snappet-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        guard isRecording else { return }
        if fake {
            isRecording = false
            recordingStartedAt = nil
            return
        }
        movieOutput.stopRecording()   // → didFinishRecordingTo
    }

    func capturePhoto() {
        guard !fake else { onPhoto?(Data(), Date()); return }
        let format: [String: Any] = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? [AVVideoCodecKey: AVVideoCodecType.hevc] : [:]
        let settings = AVCapturePhotoSettings(format: format)
        if let connection = photoOutput.connection(with: .video), let rotation {
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// The preview's device-coordinate point for a tap (the preview layer converts).
    static func devicePoint(for tap: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.captureDevicePointConverted(fromLayerPoint: tap)
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // A recording that stopped for a reason (disk full, interruption) can still be a usable file.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        Task { @MainActor in
            let started = self.recordingStartedAt ?? Date()
            self.isRecording = false
            self.recordingStartedAt = nil
            if finished { self.onMovie?(url, started) }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in self.onPhoto?(data, Date()) }
    }
}
