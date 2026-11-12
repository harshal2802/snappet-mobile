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
    func composition(_ segments: [RacketVideoSegment], partStart: Double, partEnd: Double,
                     progress: (@MainActor (String, Double) -> Void)? = nil) async -> AVMutableComposition? {
        await layout(segments, partStart: partStart, partEnd: partEnd, progress: progress)?.comp
    }

    /// The composition and, when its parts were recorded in different orientations, the video composition that draws
    /// each part with its own transform (`RacketVideoOrientation`). One track per orientation.
    private func layout(_ segments: [RacketVideoSegment], partStart: Double, partEnd: Double,
                        progress: (@MainActor (String, Double) -> Void)?) async
        -> (comp: AVMutableComposition, video: AVMutableVideoComposition?)? {
        await assemble(segments.map { ($0, max(0, $0.timelineStart - partStart)) }, progress: progress)
    }

    /// Lay `items` (a segment and where it sits, in seconds) on one composition: a video track per orientation, and a
    /// video composition fitting each part upright when there's more than one orientation. The split player and the
    /// exports both build on this (device feedback round 2 / 3: a part never borrows another part's rotation).
    private func assemble(_ items: [(segment: RacketVideoSegment, atSec: Double)],
                          progress: (@MainActor (String, Double) -> Void)?) async
        -> (comp: AVMutableComposition, video: AVMutableVideoComposition?)? {
        guard !items.isEmpty else { return nil }
        let comp = AVMutableComposition()
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var tracks: [String: (track: AVMutableCompositionTrack, transform: CGAffineTransform, natural: CGSize)] = [:]
        var order: [String] = []
        var placed: [RacketVideoOrientation.Placed] = []
        var loaded: [String: AVAsset] = [:]
        for (s, atSec) in items {
            if loaded[s.localIdentifier] == nil {
                loaded[s.localIdentifier] = await avAsset(s.localIdentifier, network: true, progress: progress)
            }
            guard let asset = loaded[s.localIdentifier],
                  let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let transform = (try? await src.load(.preferredTransform)) ?? .identity
            let natural = (try? await src.load(.naturalSize)) ?? .zero
            let key = RacketVideoOrientation.key(transform)
            if tracks[key] == nil,
               let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                t.preferredTransform = transform
                tracks[key] = (t, transform, natural)
                order.append(key)
            }
            guard let vTrack = tracks[key]?.track else { continue }
            let range = CMTimeRange(start: CMTime(seconds: s.assetStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: s.durationSec, preferredTimescale: 600))
            let at = CMTime(seconds: atSec, preferredTimescale: 600)
            do {
                try vTrack.insertTimeRange(range, of: src, at: at)
                placed.append(.init(start: atSec, duration: s.durationSec, key: key))
                if let aSrc = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: aSrc, at: at)
                }
            } catch { continue }
        }
        guard !placed.isEmpty else { return nil }
        guard order.count > 1, let first = tracks[order[0]] else { return (comp, nil) }
        let render = RacketVideoOrientation.orientedSize(natural: first.natural, transform: first.transform)
        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = RacketVideoOrientation.spans(placed, total: comp.duration.seconds).map { span in
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: CMTime(seconds: span.start, preferredTimescale: 600),
                                        end: CMTime(seconds: span.end, preferredTimescale: 600))
            if let k = span.key, let t = tracks[k] {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: t.track)
                layer.setTransform(RacketVideoOrientation.fit(natural: t.natural, transform: t.transform, render: render),
                                   at: ins.timeRange.start)
                ins.layerInstructions = [layer]
            }
            return ins
        }
        return (comp, video)
    }

    func playerItem(_ segments: [RacketVideoSegment], partStart: Double, partEnd: Double,
                    progress: (@MainActor (String, Double) -> Void)? = nil) async -> AVPlayerItem? {
        guard let l = await layout(segments, partStart: partStart, partEnd: partEnd, progress: progress) else { return nil }
        let item = AVPlayerItem(asset: l.comp)
        if let v = l.video { item.videoComposition = v }
        return item
    }

    // MARK: iCloud-only originals (device feedback round 1)

    /// Which of `ids` are in the library but not on the phone (iCloud only): Photos won't hand them over without the
    /// network. Asked per video with network access off, so nothing downloads here.
    func cloudOnly(_ ids: [String]) async -> Set<String> {
        var out = Set<String>()
        for id in ids where !id.hasPrefix(RecapClipSeed.bundledScheme) {
            if await Self.request(id, network: false, progress: nil).inCloud { out.insert(id) }
        }
        return out
    }

    // MARK: Film strip (TtSplitEdit)

    /// Small frames of the player's video at `times` (seconds on the player's own clock). A time with no video (an
    /// interruption gap) gives nil. Off the main actor; the generator never leaves the helper.
    func thumbnails(_ player: AVPlayer, times: [Double], maxSide: CGFloat = 160) async -> [UIImage?] {
        guard let asset = player.currentItem?.asset, !times.isEmpty else { return times.map { _ in nil } }
        // Parts in different orientations: the strip draws them as the player does.
        let video = player.currentItem?.videoComposition
        let images = await Self.stills(Box(value: asset), video: video.map { Box(value: $0) }, times: times, maxSide: maxSide)
        return images.value.map { $0.map { UIImage(cgImage: $0) } }
    }

    nonisolated private static func stills(_ boxed: Box<AVAsset>, video: Box<AVVideoComposition>?, times: [Double],
                                           maxSide: CGFloat) async -> Box<[CGImage?]> {
        let g = AVAssetImageGenerator(asset: boxed.value)
        g.appliesPreferredTrackTransform = true
        if let video { g.videoComposition = video.value }
        g.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tol = CMTime(seconds: 1, preferredTimescale: 600)   // a film strip needs a nearby frame, not the exact one
        g.requestedTimeToleranceBefore = tol
        g.requestedTimeToleranceAfter = tol
        var out: [CGImage?] = []
        for t in times {
            out.append(try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
        }
        return Box(value: out)
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
        // Pieces end to end, each part with its own orientation (round 3).
        var items: [(segment: RacketVideoSegment, atSec: Double)] = []
        var cursorSec = 0.0
        for piece in pieces {
            for seg in piece.segments {
                items.append((seg, cursorSec))
                cursorSec += seg.durationSec
            }
        }
        let built = await assemble(items, progress: nil)
        guard let built else { throw VideoError.missing }
        let comp = built.comp
        let cursor = comp.duration

        #if targetEnvironment(simulator)
        let preset = AVAssetExportPresetPassthrough   // the simulator can't re-encode (see ReelExporter)
        let videoComposition: AVVideoComposition? = nil
        _ = captions
        _ = cursor
        #else
        let preset = smaller ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        var videoComposition: AVVideoComposition? = built.video
        let base: AVMutableVideoComposition? = built.video == nil
            ? await Self.propertiesComposition(CompositionBox(comp: comp)) : built.video
        if !captions.isEmpty, let vc = base {
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

    private func avAsset(_ id: String, network: Bool, progress: (@MainActor (String, Double) -> Void)? = nil) async -> AVAsset? {
        if id.hasPrefix(RecapClipSeed.bundledScheme) {
            let name = String(id.dropFirst(RecapClipSeed.bundledScheme.count))
            let res = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            return Bundle.main.url(forResource: res, withExtension: ext).map { AVURLAsset(url: $0) }
        }
        let report: (@Sendable (Double) -> Void)? = progress.map { p in
            { @Sendable f in Task { @MainActor in p(id, f) } }
        }
        let result = await Self.request(id, network: network, progress: report)
        if result.asset.value != nil { progress?(id, 1) }
        return result.asset.value
    }

    /// Ask Photos for one video. Nonisolated, so Photos' callbacks (on its own queues) never run main-actor closures.
    /// `inCloud` = Photos said the video is in iCloud and wasn't sent (network access off, or the download failed).
    nonisolated private static func request(_ id: String, network: Bool,
                                            progress: (@Sendable (Double) -> Void)?) async -> (asset: Box<AVAsset?>, inCloud: Bool) {
        guard let ph = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return (Box(value: nil), false)
        }
        return await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = network
            opts.deliveryMode = .highQualityFormat
            if let progress { opts.progressHandler = { f, _, _, _ in progress(f) } }
            PHImageManager.default().requestAVAsset(forVideo: ph, options: opts) { a, _, info in
                let cloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                cont.resume(returning: (Box(value: a), a == nil && cloud))
            }
        }
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
    /// Where `play(from:until:)` stops; cleared by a plain Play.
    @ObservationIgnored private var stopAt: Double?
    private(set) var player: AVPlayer?
    private(set) var loaded = false
    /// What the video area says while it checks Photos, downloads from iCloud, or finds nothing (device feedback round 1).
    private(set) var loadState: RacketVideoLoad = .checking
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var segments: [RacketVideoSegment] = []
    @ObservationIgnored private var downloaded: [String: Double] = [:]
    /// Scrubbing: one seek in flight at a time; the latest drag position waits here (smooth on long compositions).
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: (time: Double, tolerance: Double)?

    init(partStart: Double, partEnd: Double, startAt: Double? = nil) {
        self.partStart = partStart
        self.partEnd = partEnd
        self.position = startAt.map { min(max(partStart, $0), partEnd) } ?? partStart
    }

    func load(_ segments: [RacketVideoSegment]) async {
        defer { loaded = true }
        self.segments = segments
        guard !segments.isEmpty else { loadState = .noVideo; return }
        let lib = RacketVideoLibrary.shared
        var ids: [String] = []
        for s in segments where !ids.contains(s.localIdentifier) { ids.append(s.localIdentifier) }
        let found = lib.found(ids)
        let cloud = await lib.cloudOnly(ids.filter { found.contains($0) })
        loadState = RacketVideoLoad.initial(needed: ids, found: found, cloudOnly: cloud)
        if case .missing = loadState { return }
        downloaded = [:]
        let item = await lib.playerItem(segments, partStart: partStart, partEnd: partEnd) { [weak self] id, f in
            guard let self else { return }
            self.downloaded[id] = f
            if cloud.contains(id) { self.loadState = .downloading(RacketVideoLoad.overall(self.downloaded, ids: cloud)) }
        }
        let failedCloud = cloud.filter { (downloaded[$0] ?? 0) < 1 }.count
        guard let item else {
            loadState = cloud.isEmpty ? .missing(count: ids.count) : .downloadFailed
            return
        }
        loadState = .ready(missing: ids.count - found.count + failedCloud)
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

    /// "Try again" after iCloud didn't send the video.
    func retry() async {
        stop()
        player = nil
        loaded = false
        loadState = .checking
        await load(segments)
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
        stopAt = nil
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

    /// Seek to `t` and play from there, stopping at `end` (a part tapped in the split review plays that part).
    func play(from t: Double, until end: Double? = nil) {
        seek(to: t)
        play()
        stopAt = end
    }

    /// A drag on a strip: pauses, moves the playhead at once, and seeks the video within `tolerance` — one seek in
    /// flight, the newest position next. `seek(to:)` lands exactly when the drag ends.
    func scrub(to t: Double, tolerance: Double) {
        if playing { pause() }
        position = RacketPlaybackPolicy.clamp(t, partStart, partEnd)
        guard player != nil else { return }
        pendingSeek = (position, tolerance)
        if !seeking { nextSeek() }
    }

    private func nextSeek() {
        guard let player, let next = pendingSeek else { seeking = false; return }
        pendingSeek = nil
        seeking = true
        let tol = CMTime(seconds: next.tolerance, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: next.time - partStart, preferredTimescale: 600),
                    toleranceBefore: tol, toleranceAfter: tol) { @Sendable [weak self] _ in
            Task { @MainActor in self?.nextSeek() }
        }
    }

    func seek(to t: Double) {
        pendingSeek = nil
        position = RacketPlaybackPolicy.clamp(t, partStart, partEnd)
        player?.seek(to: CMTime(seconds: position - partStart, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ sec: Double) { seek(to: position + sec) }

    private func tick(_ t: Double) {
        position = min(partEnd, max(partStart, t))
        if position >= partEnd - 0.01 { pause(); return }
        if let s = stopAt, position >= s - 0.01 { pause(); return }
        if let rallies = ralliesOnly, playing {
            switch RacketPlaybackPolicy.ralliesOnly(at: position, rallies: rallies) {
            case .to(let next): seek(to: next)
            case .end: pause()
            case nil: break
            }
        }
    }
}
