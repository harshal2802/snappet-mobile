import AVFoundation
import Photos
import UIKit
import Observation

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

    /// A part saved to Photos (asset id, when it started, its length).
    var onPartSaved: ((RecordedClip) -> Void)?
    /// Recording stopped for a reason the owner must show.
    var onInterrupted: ((RacketInterruption) -> Void)?

    private let movie = AVCaptureMovieFileOutput()
    private let library = MediaLibraryService()
    private let queue = DispatchQueue(label: "com.snappet.racket.recorder", qos: .userInitiated)
    /// The owner wants the camera writing — a part that closes at the limit rolls straight into the next one.
    private var wantsCapture = false
    private var configured = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private struct Parts: @unchecked Sendable {
        let session: AVCaptureSession
        let movie: AVCaptureMovieFileOutput
    }
    private var parts: Parts { Parts(session: session, movie: movie) }

    init(fake: Bool = CameraController.fakeRequested || !CameraController.isAvailable) {
        self.fake = fake
        super.init()
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

    func startPreview(quality: RacketRecordingQuality) {
        observe()
        guard !fake else { return }
        if !configured { configure(quality: quality) }
        let p = parts
        queue.async { if !p.session.isRunning { p.session.startRunning() } }
    }

    func stopPreview() {
        wantsCapture = false
        if isCapturing { stopCapture() }
        guard !fake else { return }
        let p = parts
        queue.async { if p.session.isRunning { p.session.stopRunning() } }
    }

    private func configure(quality: RacketRecordingQuality) {
        configured = true
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }
        nonisolated(unsafe) let video = input
        nonisolated(unsafe) let mic = AVCaptureDevice.default(for: .audio).flatMap { try? AVCaptureDeviceInput(device: $0) }
        let preset: AVCaptureSession.Preset = quality == .uhd4k ? .hd4K3840x2160 : .hd1920x1080
        let limit = CMTime(seconds: RacketStorageCheck.partSec, preferredTimescale: 600)
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
            Task { @MainActor in self.codec = hevc ? .hevc : .h264 }
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
        wantsCapture = true
        beginPart()
    }

    func stopCapture() {
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
        let p = parts
        queue.async { p.movie.startRecording(to: url, recordingDelegate: self) }
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
            MainActor.assumeIsolated { self?.report(RacketInterruption.fromCaptureInterruption(reasonRaw: raw)) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(.cameraError) }
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard ProcessInfo.processInfo.thermalState == .critical else { return }
            MainActor.assumeIsolated { self?.report(.tooHot) }
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
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        let ns = error as NSError?
        // A file that stopped for a reason (disk full, interruption, the part limit) is usually still playable.
        let usable = ns?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let code = ns?.code
        Task { @MainActor in
            let started = self.partStartedAt ?? Date()
            let reason = self.pendingInterruption ?? RacketInterruption.fromRecordingError(code: code)
            self.pendingInterruption = nil
            self.partFinished(url: url, started: started, usable: usable, interruption: reason)
        }
    }
}
