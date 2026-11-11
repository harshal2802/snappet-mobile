import AVFoundation
import Foundation
import Photos

/// **The placeholder model's frame edge** (prompt 248, issue #438 step 5). Turns a recording range into the motion
/// signal `PlaceholderMotionRallyModel` reads: for each sample (10 a second), the fraction of a coarse grid of luma
/// cells that changed by more than a few levels since the previous sample. Video only — no audio track is opened.
///
/// - Decodes with `AVAssetReader` (hardware HEVC / H.264), asking the decoder for small frames, and reads only the Y
///   plane. Frames between samples are decoded but not compared.
/// - Each 30 s chunk is cached in Caches (`racket-motion/`), so a scan that was stopped (by the user, leaving the app or
///   heat) picks up where it stopped. iOS may purge the cache; the scan then just reads again.
/// - Heat: at `serious` it waits 2 s before each chunk (a gentler pace); at `critical` it stops with
///   `RallyScanError.tooHot`, which pauses the scan.
/// The pure rule decides everything; this only measures.
struct RacketMotionReader: RallyFrameSource {
    /// The recording's Photos parts, as playback uses them (`RacketVideoMap.segments` over the scanned range).
    let segments: [RacketVideoSegment]
    /// Identifies the recording in the cache (its start time).
    let cacheKey: String

    /// Bumped when the measurement changes, so old cached chunks aren't mixed in.
    static let measureVersion = 1
    /// A cell changed when its mean luma moved by more than this (0–255).
    static let cellThreshold: Float = 10

    func motion(from a: Double, to b: Double, fps: Double, gridWidth: Int) async throws -> [Float] {
        let n = RacketMotionRallyRule.sampleCount(b - a, fps: fps)
        guard n > 0 else { return [] }
        let key = String(format: "%@-%.1f-%.1f-%.0f-%d-v%d", cacheKey, a, b, fps, gridWidth, Self.measureVersion)
        if let cached = RacketMotionCache.load(key, count: n) { return cached }

        switch ProcessInfo.processInfo.thermalState {
        case .critical: throw RallyScanError.tooHot
        case .serious: try await Task.sleep(for: .seconds(2))
        default: break
        }

        var out = [Float](repeating: .nan, count: n)
        let parts = segments.filter { $0.timelineStart < b && $0.timelineStart + $0.durationSec > a }
        guard !parts.isEmpty else { return out }
        var anyVideo = false
        for seg in parts {
            try Task.checkCancellation()
            guard let asset = await Self.asset(seg.localIdentifier) else { continue }
            let from = max(a, seg.timelineStart), to = min(b, seg.timelineStart + seg.durationSec)
            let assetFrom = seg.assetStart + (from - seg.timelineStart)
            let values = try await Self.read(asset, assetFrom: assetFrom, length: to - from, fps: fps, gridWidth: gridWidth)
            let offset = Int(((from - a) * fps).rounded())
            for (k, v) in values.enumerated() where offset + k < n { out[offset + k] = v }
            anyVideo = anyVideo || values.contains { !$0.isNaN }
        }
        if anyVideo { RacketMotionCache.save(key, out) }
        return out
    }

    // MARK: Reading

    private struct Box<T>: @unchecked Sendable { let value: T }

    /// Motion samples over `[assetFrom, assetFrom + length)` of one asset. Sample `k` is at `assetFrom + k / fps`.
    private static func read(_ asset: Box<AVAsset>, assetFrom: Double, length: Double, fps: Double,
                             gridWidth: Int) async throws -> [Float] {
        let n = RacketMotionRallyRule.sampleCount(length, fps: fps)
        var out = [Float](repeating: .nan, count: n)
        guard n > 0, let track = try? await asset.value.loadTracks(withMediaType: .video).first else { return out }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset.value) } catch { throw RallyScanError.readFailed(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            // Ask the decoder for small frames; whatever size arrives, the grid below averages it down.
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RallyScanError.readFailed("no video output") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: assetFrom, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        guard reader.startReading() else {
            throw RallyScanError.readFailed(reader.error?.localizedDescription ?? "couldn’t start")
        }
        defer { reader.cancelReading() }

        var previous: [Float]?
        var nextSample = 0
        var frames = 0
        while nextSample < n {
            frames += 1
            if frames % 30 == 0 { try Task.checkCancellation() }
            guard let sample = output.copyNextSampleBuffer() else { break }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - assetFrom
            let k = Int((t * fps).rounded(.down))
            guard k >= nextSample, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = lumaGrid(buffer, width: gridWidth)
            if let prev = previous, prev.count == grid.count, k < n {
                var changed = 0
                for i in grid.indices where abs(grid[i] - prev[i]) > cellThreshold { changed += 1 }
                out[k] = Float(changed) / Float(max(1, grid.count))
            }
            previous = grid
            nextSample = k + 1
        }
        // A reader that stops early looks like the end of the video (the spike's lesson): say so instead of a short result.
        if reader.status == .failed {
            throw RallyScanError.readFailed(reader.error?.localizedDescription ?? "stopped early")
        }
        // The first sample has no frame before it: borrow its neighbour so it isn't a gap.
        if n > 1, out[0].isNaN, !out[1].isNaN { out[0] = out[1] }
        return out
    }

    /// Mean luma of a `width` × (width · 9/16) grid of cells over the Y plane.
    private static func lumaGrid(_ buffer: CVPixelBuffer, width gw: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let gh = max(1, gw * min(w, h) / max(1, max(w, h)))
        let cols = w >= h ? gw : gh, rows = w >= h ? gh : gw
        let cw = max(1, w / cols), ch = max(1, h / rows)
        // Sample every other pixel inside a cell: plenty for a mean, half the reads.
        let step = 2
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum = 0, count = 0
                var y = r * ch
                while y < min(h, (r + 1) * ch) {
                    let row = p + y * stride
                    var x = c * cw
                    while x < min(w, (c + 1) * cw) { sum += Int(row[x]); count += 1; x += step }
                    y += step
                }
                out[r * cols + c] = count > 0 ? Float(sum) / Float(count) : 0
            }
        }
        return out
    }

    /// The Photos video (or a bundled UI-test clip).
    private static func asset(_ id: String) async -> Box<AVAsset>? {
        if id.hasPrefix(RecapClipSeed.bundledScheme) {
            let name = String(id.dropFirst(RecapClipSeed.bundledScheme.count))
            let res = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            return Bundle.main.url(forResource: res, withExtension: ext).map { Box(value: AVURLAsset(url: $0)) }
        }
        guard let ph = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            // A scan never downloads from iCloud on its own: a missing original says so on Your videos.
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: ph, options: opts) { a, _, _ in cont.resume(returning: Box(value: a)) }
        }
        return boxed.value.map { Box(value: $0) }
    }
}

/// Cached motion chunks (Caches/racket-motion). Raw little-endian Float32.
enum RacketMotionCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("racket-motion", isDirectory: true)
    }

    private static func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".f32")
    }

    static func load(_ key: String, count: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: url(key)), data.count == count * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func save(_ key: String, _ values: [Float]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url(key), options: .atomic)
    }
}

/// UI tests only (`-uiTestStubRallySignal`): a synthetic motion signal — a quiet floor with a burst every 20 s that
/// lasts 8 s — so the real placeholder model and rule run on the simulator, which has no recorded video. A short pause
/// per chunk makes progress visible.
struct RacketSyntheticMotionSource: RallyFrameSource {
    static let argument = "-uiTestStubRallySignal"
    var pausePerChunk: Duration = .milliseconds(40)

    func motion(from a: Double, to b: Double, fps: Double, gridWidth: Int) async throws -> [Float] {
        try await Task.sleep(for: pausePerChunk)
        let n = RacketMotionRallyRule.sampleCount(b - a, fps: fps)
        return (0..<n).map { k in
            let t = a + Double(k) / fps
            let phase = t.truncatingRemainder(dividingBy: 20)
            // Every fourth burst is weak, so the model is unsure of it.
            let weak = Int(t / 20) % 4 == 3
            let jitter = Float((k * 7919) % 13) / 1300
            return phase >= 4 && phase < 12 ? (weak ? 0.05 : 0.2) + jitter : 0.02 + jitter
        }
    }
}
