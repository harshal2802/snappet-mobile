import AVFoundation
import Photos
import UIKit
import Observation

/// **Racket videos' Photos + AVFoundation edge** (prompt 246, issue #438 step 3). Plays a time range of a recording
/// (which may span several 10-minute Photos parts, with gaps where it was interrupted), exports a part / rally clip,
/// saves new videos to Photos, deletes originals (iOS confirms), and checks the originals are still there. Makes no
/// decisions: the ranges come from the pure `RacketVideoMap` / `RacketKeepRallies` (`RacketVideoSplit.swift`).
@MainActor
final class RacketVideoLibrary {
    static let shared = RacketVideoLibrary()

    enum VideoError: LocalizedError {
        case missing
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "This video isn’t on your phone."
            case .exportFailed(let m): return "Couldn’t make the video: \(m)"
            }
        }
    }

    private struct Box<T>: @unchecked Sendable { let value: T }
    private let library = MediaLibraryService()

    // MARK: Availability (TtOriginalMissing)

    /// Which of `ids` are still in the Photos library (a bundled UI-test clip always is).
    func found(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var out = Set(ids.filter { $0.hasPrefix(RecapClipSeed.bundledScheme) })
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return out }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        fetched.enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }

    /// "Download from iCloud": ask Photos for each video with network access, so iCloud-only ones come down.
    func download(_ ids: [String]) async -> Bool {
        var ok = true
        for id in ids where !id.hasPrefix(RecapClipSeed.bundledScheme) {
            if await avAsset(id, network: true) == nil { ok = false }
        }
        return ok
    }

    /// "Find it in Photos".
    func openPhotos() {
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
    }

    // MARK: Composition

    /// One composition playing `segments` laid out on the part's own clock: segment `k` sits at
    /// `timelineStart − partStart`, and gaps stay empty, so composition time = recording time − part start.
    func composition(_ segments: [RacketVideoSegment], partStart: Double, partEnd: Double) async -> AVMutableComposition? {
        guard !segments.isEmpty else { return nil }
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var inserted = false
        for s in segments {
            guard let asset = await avAsset(s.localIdentifier, network: true),
                  let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let start = CMTime(seconds: s.assetStart, preferredTimescale: 600)
            let dur = CMTime(seconds: s.durationSec, preferredTimescale: 600)
            let at = CMTime(seconds: max(0, s.timelineStart - partStart), preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: dur)
            do {
                try vTrack.insertTimeRange(range, of: src, at: at)
                if !inserted, let t = try? await src.load(.preferredTransform) { vTrack.preferredTransform = t }
                inserted = true
                if let aSrc = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: aSrc, at: at)
                }
            } catch { continue }
        }
        return inserted ? comp : nil
    }

    func playerItem(_ segments: [RacketVideoSegment], partStart: Double, partEnd: Double) async -> AVPlayerItem? {
        guard let comp = await composition(segments, partStart: partStart, partEnd: partEnd) else { return nil }
        return AVPlayerItem(asset: comp)
    }

    // MARK: Export (TtPlayerExport · DeleteOriginal · KeepRallies)

    /// The mutable composition is not Sendable, so it crosses the await in a box (same approach as
    /// `ReelExporter.PlacedComposition`); it is not touched again until this returns.
    private struct CompositionBox: @unchecked Sendable { let comp: AVMutableComposition }

    private nonisolated static func propertiesComposition(_ box: CompositionBox) async -> AVMutableVideoComposition? {
        try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: box.comp)
    }

    /// Export `pieces` (each a list of segments for one recording range, joined end to end) to an .mp4. `captions`
    /// (output-relative ranges + text) are burned in on a device ("Analyzed"); the simulator can only pass through.
    func export(_ pieces: [(segments: [RacketVideoSegment], start: Double, end: Double)], smaller: Bool = false,
                captions: [(start: Double, end: Double, text: String)] = []) async throws -> URL {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoError.exportFailed("no track") }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var any = false
        for piece in pieces {
            for s in piece.segments {
                guard let asset = await avAsset(s.localIdentifier, network: true),
                      let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                let range = CMTimeRange(start: CMTime(seconds: s.assetStart, preferredTimescale: 600),
                                        duration: CMTime(seconds: s.durationSec, preferredTimescale: 600))
                try? vTrack.insertTimeRange(range, of: src, at: cursor)
                if !any, let t = try? await src.load(.preferredTransform) { vTrack.preferredTransform = t }
                if let aSrc = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: aSrc, at: cursor)
                }
                cursor = cursor + range.duration
                any = true
            }
        }
        guard any else { throw VideoError.missing }

        #if targetEnvironment(simulator)
        let preset = AVAssetExportPresetPassthrough   // the simulator can't re-encode (see ReelExporter)
        let videoComposition: AVVideoComposition? = nil
        _ = captions
        #else
        let preset = smaller ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        var videoComposition: AVVideoComposition?
        if !captions.isEmpty, let vc = await Self.propertiesComposition(CompositionBox(comp: comp)) {
            let overlays = captions.map {
                OverlayItem(kind: .text, content: $0.text, startSec: $0.start, endSec: $0.end,
                            position: CGPoint(x: 0.5, y: 0.1), scale: 0.9, highlightHex: "#000000")
            }
            if let tool = StudioOverlays.makeAnimationTool(overlays: overlays, canvas: vc.renderSize,
                                                           totalDuration: cursor.seconds) {
                vc.animationTool = tool
                videoComposition = vc
            }
        }
        #endif
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw VideoError.exportFailed("no export session")
        }
        session.videoComposition = videoComposition
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("racket-\(UUID().uuidString).mp4")
        do { try await session.export(to: out, as: .mp4) } catch { throw VideoError.exportFailed(error.localizedDescription) }
        return out
    }

    /// Export and save to Photos; returns the new video's id. The temp file is removed after.
    func saveToPhotos(_ pieces: [(segments: [RacketVideoSegment], start: Double, end: Double)], smaller: Bool = false,
                      captions: [(start: Double, end: Double, text: String)] = []) async throws -> String {
        let url = try await export(pieces, smaller: smaller, captions: captions)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let id = try await library.saveVideoToPhotos(url, accessLevel: .readWrite) else {
            throw VideoError.exportFailed("no asset id")
        }
        return id
    }

    /// Delete originals from Photos. iOS shows its own confirmation; Snappet confirms first too.
    func delete(_ ids: [String]) async throws {
        try await library.deleteAssets(localIdentifiers: ids.filter { !$0.hasPrefix(RecapClipSeed.bundledScheme) })
    }

    // MARK: Still frames (TtAISend "Claude · frames only", prompt 247)

    /// JPEG stills for an app that can't take video. Each shot is the segment holding that instant (its `assetStart`
    /// is the moment); files are named by the clip time, as the prompt tells the app: `frame-0012.5s.jpg`. Returns the
    /// files made (none when no video is on the phone).
    func frames(_ shots: [(clipSec: Double, segment: RacketVideoSegment)]) async throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racket-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        var assets: [String: AVAsset] = [:]
        for shot in shots {
            let id = shot.segment.localIdentifier
            if assets[id] == nil { assets[id] = await avAsset(id, network: true) }
            guard let asset = assets[id], let image = await Self.still(Box(value: asset), at: shot.segment.assetStart),
                  let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { continue }
            let url = dir.appendingPathComponent(String(format: "frame-%06.1fs.jpg", shot.clipSec))
            try data.write(to: url)
            out.append(url)
        }
        guard !out.isEmpty else { throw VideoError.missing }
        return out
    }

    /// One still, off the main actor (the generator never leaves this function).
    nonisolated private static func still(_ boxed: Box<AVAsset>, at sec: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: boxed.value)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1280, height: 1280)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        return try? await g.image(at: CMTime(seconds: sec, preferredTimescale: 600)).image
    }

    // MARK: Internals

    private func avAsset(_ id: String, network: Bool) async -> AVAsset? {
        if id.hasPrefix(RecapClipSeed.bundledScheme) {
            let name = String(id.dropFirst(RecapClipSeed.bundledScheme.count))
            let res = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            return Bundle.main.url(forResource: res, withExtension: ext).map { AVURLAsset(url: $0) }
        }
        guard let ph = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = network
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: ph, options: opts) { a, _, _ in cont.resume(returning: Box(value: a)) }
        }
        return boxed.value
    }
}

/// The player's clock (PlayerOriginal / NoModelTimeline): an `AVPlayer` on a part's composition, or — when the
/// recording saved no video (the simulator's stand-in camera) — a virtual clock so marking and tagging still work.
/// Positions are on the **recording's** timeline.
@MainActor
@Observable
final class RacketPlayback {
    let partStart: Double
    let partEnd: Double
    private(set) var position: Double
    private(set) var playing = false
    var rate: Float = 1 { didSet { if playing { player?.rate = rate } } }
    /// Ranges to play in "Rallies only" (set by the view).
    var ralliesOnly: [RacketRally]? = nil
    private(set) var player: AVPlayer?
    private(set) var loaded = false
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(partStart: Double, partEnd: Double, startAt: Double? = nil) {
        self.partStart = partStart
        self.partEnd = partEnd
        self.position = startAt.map { min(max(partStart, $0), partEnd) } ?? partStart
    }

    func load(_ segments: [RacketVideoSegment]) async {
        defer { loaded = true }
        guard !segments.isEmpty,
              let item = await RacketVideoLibrary.shared.playerItem(segments, partStart: partStart, partEnd: partEnd) else { return }
        let p = AVPlayer(playerItem: item)
        player = p
        seek(to: position)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                self.tick(self.partStart + t.seconds)
            }
        }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        ticker?.cancel()
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        if position >= partEnd - 0.05 { seek(to: partStart) }
        playing = true
        if let player { player.rate = rate; return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.playing else { return }
                self.tick(self.position + 0.1 * Double(self.rate))
            }
        }
    }

    func pause() {
        playing = false
        player?.pause()
        ticker?.cancel()
    }

    func seek(to t: Double) {
        position = RacketPlaybackPolicy.clamp(t, partStart, partEnd)
        player?.seek(to: CMTime(seconds: position - partStart, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ sec: Double) { seek(to: position + sec) }

    private func tick(_ t: Double) {
        position = min(partEnd, max(partStart, t))
        if position >= partEnd - 0.01 { pause(); return }
        if let rallies = ralliesOnly, playing {
            switch RacketPlaybackPolicy.ralliesOnly(at: position, rallies: rallies) {
            case .to(let next): seek(to: next)
            case .end: pause()
            case nil: break
            }
        }
    }
}
