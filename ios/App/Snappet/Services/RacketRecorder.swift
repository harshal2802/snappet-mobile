import AVFoundation
import Photos
import UIKit
import Observation
import os

/// **Record everything's AVFoundation + Photos edge** (prompt 244). One back-camera capture session at the chosen
/// quality, a movie output cut into parts of `RacketStorageCheck.partSec` (each saved to the Photos library as it
/// closes, so a crash or full storage loses minutes, not the recording), and the platform signals that stop a
/// recording: session interruptions (a call, leaving the app, another app taking the camera, heat), a file that
/// ends with an error (disk full), and the thermal state reaching critical.
///
/// It makes no decisions: it reports parts and interruptions to its owner, which feeds them to the pure
/// `RacketRecordingMachine`. Main-actor for its observable state; every session change runs on one serial queue
/// (the `CameraController` pattern — prompt 193's startRunning crash).
///
/// With no camera (the simulator) or `-uiTestFakeCamera`, it runs no session: capture just flips `isCapturing`, so
/// the screens and the state machine are exercisable without a device.
@MainActor
@Observable
final class RacketRecorder: NSObject {
    let fake: Bool
    let session = AVCaptureSession()
    private(set) var isCapturing = false
    /// When the current Photos part started.
    private(set) var partStartedAt: Date?
    /// Parts still being written to Photos.
    private(set) var savingParts = 0
    private(set) var lastSavedAt: Date?
    /// The codec the movie output was set to (HEVC wherever it's offered) — feeds the storage estimate.
    private(set) var codec: RacketVideoCodec = .hevc
    /// Bytes of finished parts this session (read from each file before it's handed to Photos).
    private(set) var savedBytes: Int64 = 0
    /// The shown picture's width / height (the preview is mapped portrait, so a 16:9 format shows 9:16); nil until the
    /// camera is configured (and for the stand-in, which fills its box). The court guide fits itself to it.
    private(set) var previewAspect: CGFloat?

    // Pro camera (prompt 255): what this phone's back camera can do, and how it is set now. The fake (`-uiTestFakeCamera`)
    // keeps the same state against a fake capability set, so the camera's controls run in UI tests.
    /// Lens buttons, zoom range and qualities, from device discovery (the fake's from launch arguments).
    private(set) var capabilities: RacketCameraCapabilities
    /// Format, zoom, focus / exposure point, lock, bias and the preview look.
    private(set) var setup = RacketCameraSetup()
    /// The back camera in use: the virtual multi-camera device when the phone has one, so zoom crosses lenses smoothly.
    @ObservationIgnored private var device: AVCaptureDevice?

    /// A part saved to Photos (asset id, when it started, its length).
    var onPartSaved: ((RecordedClip) -> Void)?
    /// Recording stopped for a reason the owner must show.
    var onInterrupted: ((RacketInterruption) -> Void)?
    /// How warm the phone is (prompt 249, Warm / PhoneWarm): serious ⇒ warm (keep recording, pause the camera view);
    /// back to fair / nominal ⇒ ok. Critical still stops the recording (`onInterrupted(.tooHot)`).
    var onThermal: ((RacketThermalLevel) -> Void)?
    /// The level now, for a screen that opens while the phone is already warm.
    var thermal: RacketThermalLevel {
        fakeThermal ?? RacketThermalLevel.from(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
    }
    /// iOS says an interruption (a call, another app on the camera, leaving the app) is over (prompt 256): the screen
    /// starts a new part by itself when the reason allows (`RacketInterruptionCopy.autoResumes`).
    var onInterruptionEnded: (() -> Void)?
    /// The fake's thermal state, forced by UI tests (`simulate`).
    private var fakeThermal: RacketThermalLevel?

    private let movie = AVCaptureMovieFileOutput()
    private let library = MediaLibraryService()
    private let queue = DispatchQueue(label: "com.snappet.racket.recorder", qos: .userInitiated)
    /// The owner wants the camera writing — a part that closes at the limit rolls straight into the next one.
    private(set) var wantsCapture = false
    /// Bumped on every appear / disappear of the screen that owns this recorder.
    @ObservationIgnored private var lifeGeneration = 0
    private var configured = false
    /// Keeps each part level with the horizon however the phone is propped (device feedback round 1).
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private struct Parts: @unchecked Sendable {
        let session: AVCaptureSession
        let movie: AVCaptureMovieFileOutput
    }
    private var parts: Parts { Parts(session: session, movie: movie) }

    init(fake: Bool = CameraController.fakeRequested || !CameraController.isAvailable) {
        self.fake = fake
        capabilities = fake ? Self.fakeCapabilities : RacketCameraCapabilities.sample
        super.init()
        if fake {
            previewAspect = setup.format.portraitAspect
            // The fake camera's heat comes only from the test, so a test phone that is really warm doesn't change it.
            fakeThermal = .ok
        }
        Self.trace("recorder init session=\(Unmanaged.passUnretained(self.session).toOpaque())")
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Permissions + storage

    /// Camera (+ mic, best-effort) and read-write Photos — a part is shown back on the match page.
    static func requestAccess() async -> Bool {
        guard await CameraController.requestAccess() else { return false }
        if CameraController.fakeRequested { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Free space for new files, and the volume's size.
    nonisolated static func storage() -> (free: Int64, total: Int64)? {
        #if DEBUG
        // UI tests (`-uiTestCameraFreeGB 45`): a fixed free space, so the pill and the quality page read the same on any Mac.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestCameraFreeGB"), i + 1 < args.count, let gb = Double(args[i + 1]) {
            return (Int64(gb * 1e9), 256_000_000_000)
        }
        #endif
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (free, Int64(v.volumeTotalCapacity ?? 0))
    }

    // MARK: - Session

    /// `com.snappet` / `racket.camera`: session running, inputs, preview connection, thermal — read from the device log
    /// (device feedback round 2: "the camera view is dark").
    nonisolated static let log = Logger(subsystem: "com.snappet", category: "racket.camera")

    /// The part length: `RacketStorageCheck.partSec` (10 min); Debug builds take `-racketPartSeconds N` to test the
    /// rollover on a phone without waiting ten minutes.
    nonisolated static var partSec: TimeInterval {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-racketPartSeconds"), i + 1 < args.count, let n = Double(args[i + 1]), n >= 5 { return n }
        #endif
        return RacketStorageCheck.partSec
    }

    nonisolated static func trace(_ message: String) {
        log.notice("\(message, privacy: .public)")
        #if DEBUG
        print("[racket.camera] \(message)")
        if ProcessInfo.processInfo.arguments.contains("-racketCameraDebug"),
           let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("racket-camera.log")
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: url) }
        }
        #endif
    }

    /// Start the preview at `quality` (30 fps unless the camera was already set to 60 at that resolution).
    func startPreview(quality: RacketRecordingQuality) {
        startPreview(setup: setup.with(quality: quality))
    }

    /// Start the preview with a camera setup — the pro camera's own, or one carried from it into a recording screen.
    func startPreview(setup wanted: RacketCameraSetup) {
        observe()
        Self.trace("startPreview session=\(Unmanaged.passUnretained(self.session).toOpaque()) fake=\(self.fake) configured=\(self.configured) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        if !configured { setup = wanted }
        guard !fake else {
            configured = true
            setup.format = RacketCameraFormats.fallback(setup.format, supported: capabilities.formats)
            setup.zoom = RacketZoomDial.clamp(setup.zoom, capabilities)
            previewAspect = setup.format.portraitAspect
            return
        }
        if !configured { configure(setup: wanted) }
        let p = parts
        queue.async {
            if !p.session.isRunning { p.session.startRunning() }
            Self.trace("session running=\(p.session.isRunning) interrupted=\(p.session.isInterrupted) inputs=\(p.session.inputs.count) outputs=\(p.session.outputs.count) preset=\(p.session.sessionPreset.rawValue)")
        }
    }

    // MARK: - The owning screen's life (device feedback round 3)

    /// SwiftUI can send a full-screen cover a spurious onDisappear → onAppear while another cover is still dismissing
    /// (seen on the phone: the record-everything screen, opened 0.45 s after the warmup cover closed, got onDisappear
    /// 0.06 s after it started recording; `stopPreview` stopped the session and the part, the preview froze on its last
    /// frame, and the screen kept saying "● Recording"). So the owner's disappear only stops the camera if the screen
    /// hasn't come back shortly after.
    func screenAppeared() {
        lifeGeneration += 1
        Self.trace("screen appeared gen=\(lifeGeneration)")
    }

    func screenDisappeared(then finish: @escaping () -> Void) {
        lifeGeneration += 1
        let g = lifeGeneration
        Self.trace("screen disappeared gen=\(g)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard self.lifeGeneration == g else { Self.trace("disappear was spurious: camera kept"); return }
            self.stopPreview()
            finish()
        }
    }

    /// The machine says the camera should be writing but the recorder isn't (nothing pending): start a new part.
    /// A guard against any future desync — the screen must never say "Recording" while nothing is written.
    func ensureCapturing(_ shouldCapture: Bool) {
        guard shouldCapture, !fake, !isCapturing, !wantsCapture else { return }
        Self.trace("capture desync: restarting a part")
        startCapture()
    }

    func stopPreview() {
        Self.trace("stopPreview session=\(Unmanaged.passUnretained(self.session).toOpaque())")
        wantsCapture = false
        if isCapturing { stopCapture() }
        guard !fake else { return }
        let p = parts
        queue.async { if p.session.isRunning { p.session.stopRunning() } }
    }

    /// The back camera: the triple / dual-wide / dual virtual device when the phone has one (zoom then moves between
    /// lenses by itself at the switch-over factors, so it is continuous), else the wide camera.
    private static func backCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                                                   .builtInWideAngleCamera]
        for t in types { if let d = AVCaptureDevice.default(t, for: .video, position: .back) { return d } }
        return nil
    }

    /// What the device can do, described as plain values for `RacketCameraCapabilities`.
    nonisolated private static func info(_ d: AVCaptureDevice) -> RacketCameraDeviceInfo {
        let formats = d.formats.map { f -> RacketDeviceFormatInfo in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return RacketDeviceFormatInfo(width: dims.width, height: dims.height,
                                          maxFps: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
                                          isTenBit: sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        }
        return RacketCameraDeviceInfo(
            hasUltraWide: d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera },
            switchOverFactors: d.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            cropFactors: d.activeFormat.secondaryNativeResolutionZoomFactors.map { Double($0) },
            minZoom: Double(d.minAvailableVideoZoomFactor), maxZoom: Double(d.maxAvailableVideoZoomFactor),
            formats: formats)
    }

    private func configure(setup wanted: RacketCameraSetup) {
        configured = true
        guard let camera = Self.backCamera() else {
            Self.trace("configure: no back camera")
            return
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: camera) } catch {
            Self.trace("configure: camera input failed \(error.localizedDescription)")
            return
        }
        device = camera
        let caps = RacketCameraCapabilities(device: Self.info(camera))
        capabilities = caps
        var s = wanted
        s.format = RacketCameraFormats.fallback(wanted.format, supported: caps.formats)
        s.zoom = RacketZoomDial.clamp(wanted.zoom, caps)
        setup = s
        Self.trace("configure: \(camera.deviceType.rawValue) lenses=\(caps.lenses) zoom=\(caps.minZoom)...\(caps.maxZoom) wide=\(caps.wideFactor) formats=\(caps.formats.map(\.label)) format=\(s.format.label)")
        rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        nonisolated(unsafe) let video = input
        nonisolated(unsafe) let cam = camera
        nonisolated(unsafe) let mic = AVCaptureDevice.default(for: .audio).flatMap { try? AVCaptureDeviceInput(device: $0) }
        let preset: AVCaptureSession.Preset = s.format.quality == .uhd4k ? .hd4K3840x2160 : .hd1920x1080
        let limit = CMTime(seconds: Self.partSec, preferredTimescale: 600)
        let formatInfos = Self.info(camera).formats
        let p = parts
        queue.async {
            p.session.beginConfiguration()
            p.session.sessionPreset = p.session.canSetSessionPreset(preset) ? preset : .high
            if p.session.canAddInput(video) { p.session.addInput(video) }
            if let mic, p.session.canAddInput(mic) { p.session.addInput(mic) }
            if p.session.canAddOutput(p.movie) { p.movie.maxRecordedDuration = limit; p.session.addOutput(p.movie) }
            p.movie.maxRecordedDuration = limit
            let hevc = p.movie.availableVideoCodecTypes.contains(.hevc)
            if let connection = p.movie.connection(with: .video) {
                p.movie.setOutputSettings([AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264],
                                          for: connection)
            }
            p.session.commitConfiguration()
            // The exact format and frame rate (the session's preset then becomes input priority).
            Self.applyFormat(s.format, infos: formatInfos, on: cam)
            Self.applyCamera(s, caps: caps, on: cam)
            #if DEBUG
            // What the sensor is doing two seconds in: a black picture with the gain at its ceiling is a covered lens.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                Self.trace("sensor iso=\(cam.iso) max=\(cam.activeFormat.maxISO) shutter=\(cam.exposureDuration.seconds) offset=\(cam.exposureTargetOffset) zoom=\(cam.videoZoomFactor) active=\(cam.activeFormat) connections=\(p.session.connections.map { "\($0.isActive)/\($0.isEnabled)" })")
            }
            #endif
            let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
            let refreshed = RacketCameraCapabilities(device: Self.info(cam))
            Task { @MainActor in
                self.codec = hevc ? .hevc : .h264
                if dims.width > 0, dims.height > 0 { self.previewAspect = CGFloat(dims.height) / CGFloat(dims.width) }
                // The zoom range can depend on the active format.
                self.capabilities = refreshed
            }
        }
    }

    // MARK: - Pro camera controls (prompt 255)

    nonisolated private static func applyFormat(_ f: RacketCameraFormat, infos: [RacketDeviceFormatInfo], on d: AVCaptureDevice) {
        guard let i = RacketCameraFormats.pick(f, from: infos), i < d.formats.count else {
            trace("format \(f.label) not offered: keeping \(d.activeFormat)")
            return
        }
        do {
            try d.lockForConfiguration()
            d.activeFormat = d.formats[i]
            let duration = CMTime(value: 1, timescale: CMTimeScale(f.fps))
            d.activeVideoMinFrameDuration = duration
            d.activeVideoMaxFrameDuration = duration
            d.unlockForConfiguration()
            trace("format set \(f.label) index=\(i)")
        } catch { trace("format lock failed \(error.localizedDescription)") }
    }

    /// Zoom, focus / exposure point, lock and bias, in one device lock.
    nonisolated private static func applyCamera(_ s: RacketCameraSetup, caps: RacketCameraCapabilities, on d: AVCaptureDevice) {
        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = clampDeviceZoom(caps.deviceZoom(s.zoom), d)
            setPoint(s.focusPoint ?? CGPoint(x: 0.5, y: 0.5), locking: s.locked, on: d)
            d.setExposureTargetBias(Float(RacketExposureBias.clamp(s.exposureBias, deviceMin: Double(d.minExposureTargetBias),
                                                                   deviceMax: Double(d.maxExposureTargetBias))))
            d.unlockForConfiguration()
        } catch { trace("camera lock failed \(error.localizedDescription)") }
        if s.locked { lockSoon(d) }
    }

    nonisolated private static func clampDeviceZoom(_ z: Double, _ d: AVCaptureDevice) -> CGFloat {
        min(d.maxAvailableVideoZoomFactor, max(d.minAvailableVideoZoomFactor, CGFloat(z)))
    }

    /// Focus and expose at `p` once (then lock) or keep doing it there (continuous). Called inside a device lock.
    nonisolated private static func setPoint(_ p: CGPoint, locking: Bool, on d: AVCaptureDevice) {
        if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
        let focus: AVCaptureDevice.FocusMode = locking ? .autoFocus : .continuousAutoFocus
        if d.isFocusModeSupported(focus) { d.focusMode = focus }
        if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
        let exposure: AVCaptureDevice.ExposureMode = locking ? .autoExpose : .continuousAutoExposure
        if d.isExposureModeSupported(exposure) { d.exposureMode = exposure }
    }

    /// AE/AF lock: after the one-shot focus and exposure at the point have settled, hold them (they then stay put when
    /// players cross the frame, through the recording).
    nonisolated private static func lockSoon(_ d: AVCaptureDevice) {
        nonisolated(unsafe) let dev = d
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
            do {
                try dev.lockForConfiguration()
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                dev.unlockForConfiguration()
                trace("AE/AF locked focus=\(dev.focusMode.rawValue) exposure=\(dev.exposureMode.rawValue)")
            } catch { trace("lock failed \(error.localizedDescription)") }
        }
    }

    /// Zoom in display units (1 = wide), clamped to the phone. `ramp` eases there (a lens tap); otherwise it is set at
    /// once (a dial drag or a pinch, which already move smoothly).
    func setZoom(_ display: Double, ramp: Bool) {
        let z = RacketZoomDial.clamp(display, capabilities)
        setup.zoom = z
        guard !fake, let d = device else { return }
        nonisolated(unsafe) let dev = d
        let target = capabilities.deviceZoom(z)
        queue.async {
            do {
                try dev.lockForConfiguration()
                let f = Self.clampDeviceZoom(target, dev)
                if ramp { dev.ramp(toVideoZoomFactor: f, withRate: 6) } else {
                    if dev.isRampingVideoZoom { dev.cancelVideoZoomRamp() }
                    dev.videoZoomFactor = f
                }
                dev.unlockForConfiguration()
            } catch { Self.trace("zoom lock failed \(error.localizedDescription)") }
        }
    }

    /// A tap (focus and expose there, keep following) or a touch and hold (focus, expose, then lock). A new point
    /// resets the brightness, as the Camera app does.
    func focus(at point: CGPoint, lock: Bool) {
        setup.focusPoint = point
        setup.locked = lock
        setup.exposureBias = 0
        Self.trace("focus at \(point) lock=\(lock)")
        guard !fake, let d = device else { return }
        nonisolated(unsafe) let dev = d
        queue.async {
            do {
                try dev.lockForConfiguration()
                Self.setPoint(point, locking: lock, on: dev)
                dev.setExposureTargetBias(0)
                dev.unlockForConfiguration()
            } catch { Self.trace("focus lock failed \(error.localizedDescription)") }
            if lock { Self.lockSoon(dev) }
        }
    }

    /// "Tap anywhere to unlock": back to continuous focus and exposure at the centre.
    func unlock() {
        setup.locked = false
        setup.focusPoint = nil
        setup.exposureBias = 0
        guard !fake, let d = device else { return }
        nonisolated(unsafe) let dev = d
        queue.async {
            do {
                try dev.lockForConfiguration()
                Self.setPoint(CGPoint(x: 0.5, y: 0.5), locking: false, on: dev)
                dev.setExposureTargetBias(0)
                dev.unlockForConfiguration()
            } catch { Self.trace("unlock failed \(error.localizedDescription)") }
        }
    }

    /// The sun slider (EV). Works locked or not.
    func setExposureBias(_ bias: Double) {
        let b = RacketExposureBias.clamp(bias)
        setup.exposureBias = b
        guard !fake, let d = device else { return }
        nonisolated(unsafe) let dev = d
        queue.async {
            do {
                try dev.lockForConfiguration()
                dev.setExposureTargetBias(Float(RacketExposureBias.clamp(b, deviceMin: Double(dev.minExposureTargetBias),
                                                                        deviceMax: Double(dev.maxExposureTargetBias))))
                dev.unlockForConfiguration()
            } catch { Self.trace("bias lock failed \(error.localizedDescription)") }
        }
    }

    /// Video quality. Only before recording (the page is closed while a part is written). The zoom, point and lock are
    /// re-applied: a new format resets them.
    func setFormat(_ f: RacketCameraFormat) {
        guard !isCapturing else { return }
        let format = RacketCameraFormats.fallback(f, supported: capabilities.formats)
        setup.format = format
        guard !fake, let d = device else { previewAspect = format.portraitAspect; return }
        nonisolated(unsafe) let dev = d
        let s = setup
        let p = parts
        queue.async {
            let infos = Self.info(dev).formats
            p.session.beginConfiguration()
            Self.applyFormat(format, infos: infos, on: dev)
            p.session.commitConfiguration()
            let caps = RacketCameraCapabilities(device: Self.info(dev))
            Self.applyCamera(s, caps: caps, on: dev)
            let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            Task { @MainActor in
                self.capabilities = caps
                if dims.width > 0, dims.height > 0 { self.previewAspect = CGFloat(dims.height) / CGFloat(dims.width) }
            }
        }
    }

    /// The look shown on the live preview (never recorded).
    func setLook(_ look: RacketLook) { setup.look = look }

    /// UI tests (DEBUG, the fake camera only): force what a phone would report — heat, a call starting and ending.
    enum Simulated: String, CaseIterable { case warm, hot, cool, call, callEnded }

    func simulate(_ s: Simulated) {
        guard fake else { return }
        switch s {
        case .warm: fakeThermal = .warm; onThermal?(.warm)
        case .hot: fakeThermal = .tooHot; onThermal?(.tooHot); report(.tooHot)
        case .cool: fakeThermal = .ok; onThermal?(.ok)
        case .call: report(.call)
        case .callEnded: onInterruptionEnded?()
        }
    }

    /// The battery is charging (low battery isn't trouble then).
    static func isCharging() -> Bool {
        #if DEBUG
        // A test that sets the battery level means an unplugged phone, even when the test phone is on a cable.
        if ProcessInfo.processInfo.arguments.contains("-uiTestCameraBattery") { return false }
        #endif
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    /// The battery, when the phone reports one (the simulator doesn't; UI tests may pass `-uiTestCameraBattery 82`).
    static func batteryPercent() -> Int? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestCameraBattery"), i + 1 < args.count, let b = Int(args[i + 1]) { return b }
        #endif
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    /// The fake's capability set: the sample phone, or `-uiTestCameraLenses "0.5,1,2,3"` / `-uiTestCameraFormats
    /// "hd1080-30,uhd4k-30"` (DEBUG only).
    private static var fakeCapabilities: RacketCameraCapabilities {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        return RacketCameraCapabilities.fake(lenses: value("-uiTestCameraLenses"), formats: value("-uiTestCameraFormats"))
        #else
        return .sample
        #endif
    }

    /// Total bytes written by this recording so far (finished parts + the part being written); `nil` for the
    /// stand-in, which writes nothing — the screen then shows the config estimate.
    var bytesWritten: Int64? {
        guard !fake else { return nil }
        return savedBytes + (movie.isRecording ? movie.recordedFileSize : 0)
    }

    // MARK: - Capture

    func startCapture() {
        Self.trace("startCapture capturing=\(isCapturing) running=\(session.isRunning)")
        wantsCapture = true
        beginPart()
    }

    func stopCapture() {
        Self.trace("stopCapture capturing=\(isCapturing)")
        wantsCapture = false
        guard isCapturing else { return }
        if fake { isCapturing = false; partStartedAt = nil; return }
        let p = parts
        queue.async { p.movie.stopRecording() }   // → didFinishRecordingTo
    }

    private func beginPart() {
        guard !isCapturing else { return }
        isCapturing = true
        partStartedAt = Date()
        guard !fake else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snappet-racket-\(UUID().uuidString).mov")
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        let p = parts
        queue.async {
            if let angle, let c = p.movie.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
            p.movie.startRecording(to: url, recordingDelegate: self)
            Self.trace("part started session=\(Unmanaged.passUnretained(p.session).toOpaque())")
        }
    }

    private func partFinished(url: URL, started: Date, usable: Bool, interruption: RacketInterruption?) {
        isCapturing = false
        partStartedAt = nil
        // Count the part's bytes now, so the running total never dips between parts.
        savedBytes += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if usable { save(url, started: started) }
        if let interruption {
            wantsCapture = false
            onInterrupted?(interruption)
        } else if wantsCapture {
            beginPart()   // the part limit: roll into the next part of the same recording
        }
    }

    private func save(_ url: URL, started: Date) {
        savingParts += 1
        Task { @MainActor in
            defer { savingParts -= 1 }
            if let clip = try? await library.saveRecording(at: url, capturedAt: started) {
                lastSavedAt = Date()
                onPartSaved?(clip)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Platform signals

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                        queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
            Self.trace("session interrupted reason=\(raw) \(String(describing: (note.object as AnyObject?).map { Unmanaged.passUnretained($0).toOpaque() }))")
            MainActor.assumeIsolated { self?.report(RacketInterruption.fromCaptureInterruption(reasonRaw: raw)) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                        queue: .main) { [weak self] note in
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "?"
            Self.trace("session runtime error \(err)")
            MainActor.assumeIsolated { self?.report(.cameraError) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session,
                                        queue: .main) { [weak self] _ in
            Self.trace("session interruption ended")
            MainActor.assumeIsolated { self?.onInterruptionEnded?() }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session,
                                        queue: .main) { n in Self.trace("session didStartRunning \(String(describing: n.object.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }))") })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session,
                                        queue: .main) { n in Self.trace("session didStopRunning \(String(describing: n.object.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }))") })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            let level = RacketThermalLevel.from(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
            MainActor.assumeIsolated {
                guard self?.fake == false else { return }
                self?.onThermal?(level)
                if level == .tooHot { self?.report(.tooHot) }
            }
        })
        // The fake has no capture session to interrupt: leaving the app is the signal.
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fake, self.isCapturing else { return }
                self.isCapturing = false
                self.partStartedAt = nil
                self.wantsCapture = false
                self.onInterrupted?(.appLeft)
            }
        })
    }

    /// An interruption while writing ends the file (its delegate call reports it); one while idle is ignored.
    private func report(_ reason: RacketInterruption) {
        guard isCapturing || wantsCapture else { return }
        wantsCapture = false
        if fake || !movie.isRecording {
            isCapturing = false
            partStartedAt = nil
            onInterrupted?(reason)
        } else {
            pendingInterruption = reason
            let p = parts
            queue.async { p.movie.stopRecording() }
        }
    }

    /// The reason to report when the file the interruption ended finishes.
    private var pendingInterruption: RacketInterruption?
}

extension RacketRecorder: AVCaptureFileOutputRecordingDelegate {
    /// The file really starts with its first frame, a moment after `startRecording` (≈0.3–1 s on a phone): re-stamp the
    /// part's start then, so its video lines up with the recording's timeline (the split, rally marks and scrubbing
    /// read part starts from it — device feedback round 2 split audit).
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        let now = Date()
        Task { @MainActor in
            if self.isCapturing, let was = self.partStartedAt, now > was {
                Self.trace("part first frame +\(String(format: "%.2f", now.timeIntervalSince(was))) s")
                self.partStartedAt = now
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        let ns = error as NSError?
        // A file that stopped for a reason (disk full, interruption, the part limit) is usually still playable.
        let usable = ns?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let code = ns?.code
        Self.trace("part finished error=\(ns.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "none") usable=\(usable)")
        Task { @MainActor in
            let started = self.partStartedAt ?? Date()
            let reason = self.pendingInterruption ?? RacketInterruption.fromRecordingError(code: code)
            self.pendingInterruption = nil
            self.partFinished(url: url, started: started, usable: usable, interruption: reason)
        }
    }
}
