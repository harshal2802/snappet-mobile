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

    /// SplitPhotos (prompt 251): when a picked Photos video was recorded, how long it is, and whether the Camera app
    /// made it (a video with no creation date, e.g. saved from elsewhere, reads as "now").
    func videoInfo(_ id: String) -> (created: Date?, durationSec: Double)? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let a = fetched.firstObject, a.mediaType == .video else { return nil }
        return (a.creationDate, a.duration)
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
        await assemble(segments.map { ($0, max(0, $0.timelineStart - partStart)) }, turns: 0, progress: progress)
    }

    /// Lay `items` (a segment and where it sits, in seconds) on one composition: a video track per orientation, and a
    /// video composition fitting each part upright when there's more than one orientation. The split player and the
    /// exports both build on this (device feedback round 2 / 3: a part never borrows another part's rotation).
    ///
    /// `turns` (prompt 259, copies only — the player turns on screen): each track's transform becomes "stored, then the
    /// viewer's turn" (`RacketVideoTurn.transform`), so a copy that isn't re-encoded plays upright from its track
    /// transform and a re-encoded one renders upright from it. 0 ⇒ the stored transforms, exactly as before.
    private func assemble(_ items: [(segment: RacketVideoSegment, atSec: Double)], turns: Int,
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
            let natural = (try? await src.load(.naturalSize)) ?? .zero
            let stored = (try? await src.load(.preferredTransform)) ?? .identity
            let transform = RacketVideoTurn.transform(natural: natural, preferred: stored, turns: turns)
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
        // A recording with no sound leaves the audio track empty. An empty track makes a re-encoding export stop at
        // once ("Operation Stopped", found on the phone, prompt 254); passthrough and playback don't mind. Drop it.
        if let a = aTrack, a.segments.isEmpty { comp.removeTrack(a) }
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

    // MARK: First frame and shape (PlayerOpening · PlayerLetterbox, prompt 253)

    /// A still of video `id` near `sec`, from what is on the phone: the bundled test clip's frame, or Photos' own
    /// still of the video with the network off (an iCloud-only video still has one). nil when there is none.
    /// `turns` (prompt 259): a still shown outside the turned player (the camera's thumbnail) turns itself; the
    /// player's poster stays as stored (`RacketTurned` turns it with the video).
    func poster(_ id: String, at sec: Double = 0, turns: Int = 0) async -> UIImage? {
        if id.hasPrefix(RecapClipSeed.bundledScheme) {
            guard let asset = await avAsset(id, network: false),
                  let image = await Self.still(Box(value: asset), at: sec) else { return nil }
            return Self.turned(UIImage(cgImage: image), turns: turns)
        }
        guard let ph = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let image = await PhotosImageRequest.image(for: ph, targetSize: CGSize(width: 1080, height: 1080),
                                                   contentMode: .aspectFit, network: false)
        return image.map { Self.turned($0, turns: turns) }
    }

    /// A still turned `turns` quarter turns clockwise, redrawn (so the pixels, not just an orientation tag, are turned).
    nonisolated static func turned(_ image: UIImage, turns: Int) -> UIImage {
        let k = RacketVideoTurn.normalized(turns)
        guard k > 0, image.size.width > 0, image.size.height > 0 else { return image }
        let size = RacketVideoTurn.displayed(image.size, turns: k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: CGFloat(k) * .pi / 2)   // y down: a positive angle turns clockwise on screen
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// The size a video file shows at in any player: its first video track's natural size turned by its transform.
    nonisolated static func displayedSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        return RacketVideoOrientation.orientedSize(natural: natural, transform: transform)
    }

    /// The upright size of what `item` shows: the video composition's render size, else the first video track's
    /// natural size turned by its transform.
    func uprightSize(_ item: AVPlayerItem) async -> CGSize? {
        if let v = item.videoComposition { return v.renderSize }
        guard let track = try? await item.asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    // MARK: Film strip (TtSplitEdit)

    /// Small frames of the player's video at `times` (seconds on the player's own clock). A time with no video (an
    /// interruption gap) gives nil. Off the main actor; the generator never leaves the helper.
    /// `turns`: the recording's turn (prompt 259), so a strip shows the frames as the turned player does.
    func thumbnails(_ player: AVPlayer, times: [Double], maxSide: CGFloat = 160, turns: Int = 0) async -> [UIImage?] {
        guard let asset = player.currentItem?.asset, !times.isEmpty else { return times.map { _ in nil } }
        // Parts in different orientations: the strip draws them as the player does.
        let video = player.currentItem?.videoComposition
        let images = await Self.stills(Box(value: asset), video: video.map { Box(value: $0) }, times: times, maxSide: maxSide)
        return images.value.map { $0.map { Self.turned(UIImage(cgImage: $0), turns: turns) } }
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

    /// The composition's first video track as it shows (its transform applied).
    private nonisolated static func uprightSize(_ box: CompositionBox) async -> CGSize? {
        guard let t = try? await box.comp.loadTracks(withMediaType: .video).first,
              let natural = try? await t.load(.naturalSize) else { return nil }
        let transform = (try? await t.load(.preferredTransform)) ?? .identity
        return RacketVideoOrientation.orientedSize(natural: natural, transform: transform)
    }

    private nonisolated static func propertiesComposition(_ box: CompositionBox) async -> AVMutableVideoComposition? {
        try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: box.comp)
    }

    /// The look / label composition for a share copy, boxed the same way (device builds only reach this).
    private nonisolated static func lookComposition(_ box: CompositionBox, control: RacketLookControl) async -> AVVideoComposition? {
        await RacketLookRenderer.composition(for: box.comp, control: control)
    }

    /// Export `pieces` (each a list of segments for one recording range, joined end to end) to an .mp4. `captions`
    /// (output-relative ranges + text) are burned in on a device ("Analyzed"); the simulator can only pass through.
    ///
    /// `turns` (prompt 259): the viewer's turn of the recording. Every route takes it from the composition tracks'
    /// turned `preferredTransform`: a passthrough copy (simulator) and a plain re-encode (device, no look / labels /
    /// captions / mixed orientations) keep it as the output track's transform; the look-and-labels composition renders
    /// at the turned size with upright frames (Core Image gets frames with the track transform applied), so labels sit
    /// upright on the turned picture; captions render at the turned upright size; mixed orientations fit each turned
    /// part into the turned render size. 0 turns ⇒ the stored transforms: the same route and output as before.
    func export(_ pieces: [(segments: [RacketVideoSegment], start: Double, end: Double)], smaller: Bool = false,
                captions: [(start: Double, end: Double, text: String)] = [],
                look: RacketLook = .original, speed: Double = 1, labels: [RacketSharePlan.Label] = [], turns: Int = 0,
                progress: (@MainActor (Double) -> Void)? = nil, fileName: String? = nil) async throws -> URL {
        // Pieces end to end, each part with its own orientation (round 3).
        var items: [(segment: RacketVideoSegment, atSec: Double)] = []
        var cursorSec = 0.0
        for piece in pieces {
            for seg in piece.segments {
                items.append((seg, cursorSec))
                cursorSec += seg.durationSec
            }
        }
        let built = await assemble(items, turns: turns, progress: nil)
        guard let built else { throw VideoError.missing }
        let comp = built.comp
        let cursor = comp.duration

        #if targetEnvironment(simulator)
        let preset = AVAssetExportPresetPassthrough   // the simulator can't re-encode (see ReelExporter): no look, labels or speed
        let videoComposition: AVVideoComposition? = nil
        _ = captions
        _ = cursor
        _ = (look, speed, labels)
        #else
        let preset = smaller ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        var videoComposition: AVVideoComposition? = built.video
        let base: AVMutableVideoComposition? = built.video == nil
            ? await Self.propertiesComposition(CompositionBox(comp: comp)) : built.video
        // Share (prompt 254): keep the speed, then the look and the score / rally labels drawn by one Core Image pass.
        // A recording mixing orientations keeps its own fitting composition and shares at normal speed, unfiltered.
        if built.video == nil, speed > 0, abs(speed - 1) > 0.001 {
            let all = CMTimeRange(start: .zero, duration: comp.duration)
            comp.scaleTimeRange(all, toDuration: CMTimeMultiplyByFloat64(comp.duration, multiplier: 1 / speed))
        }
        if built.video == nil, !look.isOriginal || !labels.isEmpty {
            videoComposition = await Self.lookComposition(CompositionBox(comp: comp), control: RacketLookControl(look: look, labels: labels))
        } else if !captions.isEmpty, let vc = base {
            let overlays = captions.map {
                OverlayItem(kind: .text, content: $0.text, startSec: $0.start, endSec: $0.end,
                            position: CGPoint(x: 0.5, y: 0.1), scale: 0.9, highlightHex: "#000000")
            }
            // A turned copy: the properties composition sizes itself from the composition's natural size, which
            // doesn't know the turn; render at the turned track's upright size (prompt 259). Unturned: as before.
            if RacketVideoTurn.normalized(turns) != 0, let size = await Self.uprightSize(CompositionBox(comp: comp)) {
                vc.renderSize = size
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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(fileName ?? "racket-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        let watcher = progress.map { report in
            Task { @MainActor in
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { report(p.fractionCompleted) }
                }
            }
        }
        defer { watcher?.cancel() }
        do {
            try await session.export(to: out, as: .mp4)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: out)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: out)
            if Task.isCancelled { throw CancellationError() }
            #if DEBUG
            let ns = error as NSError
            print("RACKETEXPORT failed \(ns.domain) \(ns.code) \(ns.userInfo) underlying: \(String(describing: ns.userInfo[NSUnderlyingErrorKey]))")
            #endif
            throw VideoError.exportFailed(error.localizedDescription)
        }
        progress?(1)
        return out
    }

    /// Export and save to Photos; returns the new video's id. The temp file is removed after.
    /// `turns`: the viewer's turn, baked in (a derived video made from it is upright — `playFromDerived`).
    func saveToPhotos(_ pieces: [(segments: [RacketVideoSegment], start: Double, end: Double)], smaller: Bool = false,
                      captions: [(start: Double, end: Double, text: String)] = [], turns: Int = 0) async throws -> String {
        let url = try await export(pieces, smaller: smaller, captions: captions, turns: turns)
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
    /// `turns`: the viewer's turn, drawn into the pixels (an app may ignore an orientation tag) — prompt 259.
    func frames(_ shots: [(clipSec: Double, segment: RacketVideoSegment)], turns: Int = 0) async throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racket-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        var assets: [String: AVAsset] = [:]
        for shot in shots {
            let id = shot.segment.localIdentifier
            if assets[id] == nil { assets[id] = await avAsset(id, network: true) }
            guard let asset = assets[id], let image = await Self.still(Box(value: asset), at: shot.segment.assetStart),
                  let data = Self.turned(UIImage(cgImage: image), turns: turns).jpegData(compressionQuality: 0.8) else { continue }
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
        #if DEBUG
        // Unit tests only (prompt 259): a copy made by `export` read back as a source (the turn round trip).
        if id.hasPrefix("file://"), let url = URL(string: id) { return AVURLAsset(url: url) }
        #endif
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
    /// "Loop this rally" (prompt 253): back to its start at its end; ends when the viewer moves away.
    var loop: ClosedRange<Double>? = nil
    /// Prompt 258: a game joined across timeouts plays as one game — playing through, seeking, scrubbing and skipping
    /// all jump over its timeouts (`RacketPlayedTime`). nil ⇒ nothing skipped.
    var playedClock: RacketPlayedTime? = nil
    /// The player's mute button (prompt 253).
    var muted = false { didSet { player?.isMuted = muted } }
    /// Playback reached the end of the part (or the last rally in Rallies only): PlayerEnd. Cleared by any seek or Play.
    private(set) var ended = false
    /// The video's upright size in pixels once loaded (PlayerLetterbox decides on it); nil for the stand-in.
    private(set) var videoSize: CGSize?
    /// Quarter turns the viewer chose for this recording (prompt 257, `RacketRecordingLog.quarterTurns`): every surface
    /// drawing this playback turns the picture by it.
    var quarterTurns = 0
    /// The picture's shape as shown (the video, else the poster, after `quarterTurns`); nil for the stand-in.
    var displayedSize: CGSize? {
        (videoSize ?? poster?.size).map { RacketVideoTurn.displayed($0, turns: quarterTurns) }
    }
    /// A still of the video while it opens or downloads (PlayerOpening "an immediate first frame").
    private(set) var poster: UIImage?
    /// The look it plays with (prompt 254): set any time, the next frame shows it. Playback only.
    var look: RacketLook = .original {
        didSet { lookControl.look = look; if !playing { redrawFrame() } }
    }
    /// EditLooks "Hold the video to see the original".
    var showOriginal = false {
        didSet { lookControl.bypassed = showOriginal; if !playing { redrawFrame() } }
    }
    @ObservationIgnored private let lookControl = RacketLookControl(look: .original)
    /// Where `play(from:until:)` stops; cleared by a plain Play.
    @ObservationIgnored private var stopAt: Double?
    private(set) var player: AVPlayer?
    private(set) var loaded = false
    /// What the video area says while it checks Photos, downloads from iCloud, or finds nothing (device feedback round 1).
    private(set) var loadState: RacketVideoLoad = .checking
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
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
        // The first frame at once, from what Photos keeps on the phone (no download), while the rest opens.
        if poster == nil, let first = segments.first(where: { found.contains($0.localIdentifier) }) {
            poster = await lib.poster(first.localIdentifier, at: first.assetStart)
        }
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
        // Looks (prompt 254): a filter while drawing, for a recording in one orientation (a mixed one already has its own
        // composition fitting each part upright, and plays without a look).
        if item.videoComposition == nil,
           let vc = await RacketLookRenderer.composition(for: item.asset, control: lookControl) {
            item.videoComposition = vc
        }
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        player = p
        videoSize = await lib.uprightSize(item)
        // Open on a frame, not on the empty start of the recording (the camera starts a moment after the log).
        if !playing { position = RacketScrub.firstFrame(at: position, segments: segments, end: partEnd) }
        seek(to: position)
        // Device bug (prompt 251): a seek issued before the item is ready may draw nothing, so a paused player opened
        // on the split screens stayed black until the first seek or play. Once ready, ask for the frame again.
        Task { [weak self] in
            for _ in 0..<80 where item.status != .readyToPlay {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, item.status == .readyToPlay, !self.playing, self.pendingSeek == nil, !self.seeking else { return }
            self.redrawFrame()
        }
        // The item played to its end (a seek to the very end, or the video running out before the part's end): the
        // periodic observer may not fire there, so PlayerEnd hangs on this (prompt 253).
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                if let l = self.loop { self.seek(to: l.lowerBound); self.player?.rate = self.rate; return }
                self.position = self.partEnd
                self.pause()
                self.ended = true
            }
        }
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        ticker?.cancel()
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        if position >= partEnd - 0.05 { seek(to: partStart) }
        ended = false
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
        ended = false
        position = landing(RacketPlaybackPolicy.clamp(t, partStart, partEnd))
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

    /// A position inside a timeout of the game moves to its edge (on the way it was going).
    private func landing(_ t: Double) -> Double {
        guard let c = playedClock else { return t }
        return c.landing(t, forward: t >= position)
    }

    func seek(to t: Double) {
        pendingSeek = nil
        position = landing(RacketPlaybackPolicy.clamp(t, partStart, partEnd))
        // Still at the end (another skip forward there) stays ended; anywhere else is not.
        if position < partEnd - 0.05 { ended = false }
        player?.seek(to: CMTime(seconds: position - partStart, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        // Skipping onto the very end while playing is the end (the player may report nothing more from there).
        if playing, loop == nil, position >= partEnd - 0.05 {
            pause()
            ended = true
        }
    }

    func step(_ sec: Double) { seek(to: playedClock.map { $0.step(from: position, by: sec) } ?? position + sec) }

    /// Draw the frame at the playhead again (a tick off and back: a seek to where the player already is can be
    /// skipped and draw nothing).
    func redrawFrame() {
        guard let player else { return }
        let t = CMTime(seconds: position - partStart, preferredTimescale: 600)
        player.seek(to: CMTimeAdd(t, CMTime(value: 1, timescale: 600)), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, !self.playing, self.pendingSeek == nil, !self.seeking else { return }
                self.player?.seek(to: CMTime(seconds: self.position - self.partStart, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func tick(_ t: Double) {
        position = min(partEnd, max(partStart, t))
        // Playing into a timeout: on to its end (prompt 258).
        if playing, let s = playedClock?.skip(at: position) { seek(to: s.upperBound); return }
        if let l = loop, playing {
            switch RacketPlayerLoop.jump(at: position, loop: l) {
            case .to(let start): seek(to: start); return
            case .clear: loop = nil
            case nil: return
            }
        }
        if position >= partEnd - 0.01 { pause(); ended = true; return }
        if let s = stopAt, position >= s - 0.01 { pause(); return }
        if let rallies = ralliesOnly, playing {
            switch RacketPlaybackPolicy.ralliesOnly(at: position, rallies: rallies) {
            case .to(let next): seek(to: next)
            case .end: pause(); ended = true
            case nil: break
            }
        }
    }

    /// UI tests only (`-uiTestRacketPlayer opening`): stay on PlayerOpening at `fraction`, with the poster, as an
    /// iCloud download in progress would (the simulator has no iCloud library).
    func holdOpening(_ segments: [RacketVideoSegment], fraction: Double) async {
        self.segments = segments
        if let first = segments.first {
            poster = await RacketVideoLibrary.shared.poster(first.localIdentifier, at: first.assetStart)
        }
        loadState = .downloading(fraction)
        loaded = true
    }
}
