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

    /// A part saved to Photos (asset id, when it started, its length).
    var onPartSaved: ((RecordedClip) -> Void)?
    /// Recording stopped for a reason the owner must show.
    var onInterrupted: ((RacketInterruption) -> Void)?
    /// How warm the phone is (prompt 249, Warm / PhoneWarm): serious ⇒ warm (keep recording, pause the camera view);
    /// back to fair / nominal ⇒ ok. Critical still stops the recording (`onInterrupted(.tooHot)`).
    var onThermal: ((RacketThermalLevel) -> Void)?
    /// The level now, for a screen that opens while the phone is already warm.
    var thermal: RacketThermalLevel { RacketThermalLevel.from(rawValue: ProcessInfo.processInfo.thermalState.rawValue) }

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
        super.init()
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

    func startPreview(quality: RacketRecordingQuality) {
        observe()
        Self.trace("startPreview session=\(Unmanaged.passUnretained(self.session).toOpaque()) fake=\(self.fake) configured=\(self.configured) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        guard !fake else { return }
        if !configured { configure(quality: quality) }
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

    private func configure(quality: RacketRecordingQuality) {
        configured = true
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            Self.trace("configure: no back wide camera")
            return
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: camera) } catch {
            Self.trace("configure: camera input failed \(error.localizedDescription)")
            return
        }
        rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        nonisolated(unsafe) let video = input
        nonisolated(unsafe) let cam = camera
        nonisolated(unsafe) let mic = AVCaptureDevice.default(for: .audio).flatMap { try? AVCaptureDeviceInput(device: $0) }
        let preset: AVCaptureSession.Preset = quality == .uhd4k ? .hd4K3840x2160 : .hd1920x1080
        let limit = CMTime(seconds: Self.partSec, preferredTimescale: 600)
        let p = parts
        queue.async {
            p.session.beginConfiguration()
            p.session.sessionPreset = p.session.canSetSessionPreset(preset) ? preset : .high
            if p.session.canAddInput(video) { p.session.addInput(video) }
            if let mic, p.session.canAddInput(mic) { p.session.addInput(mic) }
            if p.session.canAddOutput(p.movie) { p.session.addOutput(p.movie) }
            p.movie.maxRecordedDuration = limit
            let hevc = p.movie.availableVideoCodecTypes.contains(.hevc)
            if let connection = p.movie.connection(with: .video) {
                p.movie.setOutputSettings([AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264],
                                          for: connection)
            }
            p.session.commitConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
            Task { @MainActor in
                self.codec = hevc ? .hevc : .h264
                if dims.width > 0, dims.height > 0 { self.previewAspect = CGFloat(dims.height) / CGFloat(dims.width) }
            }
        }
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
                                        queue: .main) { _ in Self.trace("session interruption ended") })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session,
                                        queue: .main) { n in Self.trace("session didStartRunning \(String(describing: n.object.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }))") })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session,
                                        queue: .main) { n in Self.trace("session didStopRunning \(String(describing: n.object.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }))") })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            let level = RacketThermalLevel.from(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
            MainActor.assumeIsolated {
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
