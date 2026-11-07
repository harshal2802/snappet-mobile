import Foundation

// MARK: - Racket model hooks (prompt 248, issue #438 step 5) — pure
//
// A per-sport capability registry, the `RallyModel` seam a rally finder plugs into, and Snappet's placeholder model: a
// pure rally rule over a cheap per-frame motion signal, anchored by score taps when there are any. Vision only (no
// audio). The research spike's weights (prompt 220) are evaluation-only and are not used here in any way. Frame
// decoding lives in `Services/RacketMotionReader.swift`; the queue in `Services/RacketScanCenter.swift`.
// Boards: TtCapabilities, TtChooseModel, TtModelCompare, Analyzing, FindRallies, AnalysisSettings, Summary, Timeline,
// QuickTag, TtTagDone. Tested in `RacketModelHooksTests`.

// MARK: - Capabilities (TtCapabilities)

/// The eight rows of "What works for <sport>", in the boards' order, each with what the user does without it.
enum RacketFeature: String, CaseIterable, Codable, Sendable {
    case findRallies, liveTracking, courtCheck, shotCount, shotTypes, endings, ballPath, longestRallyInDrills

    var title: String {
        switch self {
        case .findRallies: return "Find rallies"
        case .liveTracking: return "Live tracking"
        case .courtCheck: return "Court check"
        case .shotCount: return "Shot count"
        case .shotTypes: return "Shot types"
        case .endings: return "Endings"
        case .ballPath: return "Ball path on video"
        case .longestRallyInDrills: return "Longest rally in drills"
        }
    }

    /// "Without it: mark rallies on the timeline".
    var withoutIt: String {
        switch self {
        case .findRallies: return "Without it: mark rallies on the timeline"
        case .liveTracking: return "Without it: play uses the tracking-off screens"
        case .courtCheck: return "Without it: line up the view yourself"
        case .shotCount: return "Without it: count shots by hand, or skip"
        case .shotTypes: return "Without it: tag each shot yourself"
        case .endings: return "Without it: pick endings, nothing preselected"
        case .ballPath: return "Without it: the player shows the original"
        case .longestRallyInDrills: return "Without it: enter it during rest"
        }
    }
}

/// What a model needs as input. The placeholder needs only a motion signal; a learned model would ask for frames.
enum RallyModelInput: Codable, Hashable, Sendable {
    /// Fraction of a coarse grid of luma cells that changed between samples, `fps` samples a second, frames scaled to
    /// `gridWidth` cells across (`Services/RacketMotionReader.swift`).
    case motionEnergy(fps: Double, gridWidth: Int)

    var fps: Double {
        switch self { case .motionEnergy(let f, _): return f }
    }
}

/// A rally model's identity. `id` + `version` are stored on every guess and scan, so results always say which model
/// (and which version of it) made them.
struct RallyModelInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var version: Int
    /// "Snappet placeholder".
    var name: String
    var sports: [RacketSport]
    var input: RallyModelInput
    /// The features this model backs. The placeholder declares all of them (#438: "every sport assumes a placeholder
    /// model and the UI shows every feature as available"); see decisions 2026-11-07 for which are built.
    var features: [RacketFeature]
    var isPlaceholder: Bool
    /// "Recommended for this sport" etc. (ChooseModel).
    var note: String

    /// "Snappet placeholder v1".
    var label: String { "\(name) v\(version)" }
    /// Stored on rallies: `model:<id>@<version>`.
    var source: String { RacketModelSource.raw(id: id, version: version) }
}

/// Where a model's rally came from. Distinct from another AI app's `ai:` prefix (prompt 247).
enum RacketModelSource {
    static let prefix = "model:"

    static func raw(id: String, version: Int) -> String { "\(prefix)\(id)@\(version)" }
    static func isModel(_ raw: String?) -> Bool { raw?.hasPrefix(prefix) == true }

    /// (`id`, `version`) of a model source.
    static func parse(_ raw: String?) -> (id: String, version: Int)? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        let body = raw.dropFirst(prefix.count)
        guard let at = body.lastIndex(of: "@"), let v = Int(body[body.index(after: at)...]) else { return nil }
        return (String(body[..<at]), v)
    }
}

/// What works for a sport right now.
struct RacketSportCapabilities: Equatable, Sendable {
    var sport: RacketSport
    /// The model used for new scans; nil = no model (by hand only).
    var model: RallyModelInfo?
    /// Every model for the sport, newest first (ChooseModel).
    var models: [RallyModelInfo]

    func has(_ f: RacketFeature) -> Bool { model?.features.contains(f) == true }
    var hasModel: Bool { model != nil }
}

/// The per-sport registry. One place says which model each sport uses and what it supports; Capabilities, the "Without
/// it" lines, the no-model states and "Preview a sport with no model" all read it.
enum RacketCapabilityRegistry {
    /// Snappet's placeholder: motion energy + score taps. Every sport, every feature declared (user decision).
    static let placeholder = RallyModelInfo(
        id: "snappet.placeholder.motion", version: 1, name: "Snappet placeholder",
        sports: RacketSport.allCases, input: .motionEnergy(fps: 10, gridWidth: 32),
        features: RacketFeature.allCases, isPlaceholder: true,
        note: "Placeholder: finds rallies from movement and your score taps")

    /// Models per sport, newest first. Add a model here (and its `RallyModel` in `RacketRallyModels.all`) to ship it.
    static func models(for sport: RacketSport) -> [RallyModelInfo] {
        [placeholder].filter { $0.sports.contains(sport) }.sorted { $0.version > $1.version }
    }

    /// `noModel` previews a sport with no model ("Preview a sport with no model").
    static func capabilities(for sport: RacketSport, noModel: Bool = false) -> RacketSportCapabilities {
        let ms = noModel ? [] : models(for: sport)
        return RacketSportCapabilities(sport: sport, model: ms.first, models: ms)
    }

    static func model(id: String, version: Int? = nil) -> RallyModelInfo? {
        let all = RacketSport.allCases.flatMap(models(for:))
        return all.first { $0.id == id && (version == nil || $0.version == version) }
    }

    /// TtCapabilities: "✓ Available" or "Not yet".
    static func statusLabel(_ caps: RacketSportCapabilities, _ f: RacketFeature) -> String {
        caps.has(f) ? "✓ Available" : "Not yet"
    }
}

/// Whether a model can find rallies for a sport (step 3's seam, now read from the registry).
enum RacketRallyFinding {
    enum Availability: Equatable, Sendable { case notYet, available(modelName: String) }

    static func availability(for sport: RacketSport, noModel: Bool = false) -> Availability {
        let caps = RacketCapabilityRegistry.capabilities(for: sport, noModel: noModel)
        guard let m = caps.model, caps.has(.findRallies) else { return .notYet }
        return .available(modelName: m.label)
    }

    /// "Rally finding isn't available for table tennis yet."
    static func notYetLine(_ sport: RacketSport) -> String {
        "Rally finding isn’t available for \(sport.label.lowercased()) yet."
    }
}

// MARK: - The model seam

/// A point tapped during play, on the recording's timeline: the rally before it ended, and `winner` won it.
struct RallyAnchor: Equatable, Sendable {
    var atSec: Double
    var winner: RacketRallyWinner?
}

/// One rally a model found. Times are on the recording's timeline.
struct RallyGuess: Codable, Hashable, Sendable {
    var startSec: Double
    var endSec: Double
    /// 0…1. Below `RacketRallyGuessMerge.unsureBelow` the rally is "unsure" (dashed, checked first).
    var confidence: Double
    /// From the score tap after it, when there was one. A suggestion, never a tag.
    var winnerRaw: String?
    /// A score tap confirmed this rally ended here.
    var anchored: Bool?

    var winner: RacketRallyWinner? { winnerRaw.flatMap(RacketRallyWinner.init(rawValue:)) }
    var durationSec: Double { max(0, endSec - startSec) }
}

/// What a scan covers.
struct RallyScanRequest: Equatable, Sendable {
    var sport: RacketSport
    var startSec: Double
    var endSec: Double
    var anchors: [RallyAnchor]
    var lengthSec: Double { max(0, endSec - startSec) }
}

struct RallyScanProgress: Equatable, Sendable {
    /// Recording seconds scanned from the request's start.
    var doneSec: Double
    var totalSec: Double
    var fraction: Double { totalSec > 0 ? min(1, doneSec / totalSec) : 1 }
}

enum RallyScanError: LocalizedError, Equatable, Sendable {
    /// No video on the phone for this range (deleted, iCloud only, or the simulator's stand-in camera).
    case noVideo
    /// The phone reached a critical thermal state; the scan stopped and resumes later.
    case tooHot
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "No video on this phone for this part"
        case .tooHot: return "Paused: the phone is too hot"
        case .readFailed(let m): return "Couldn’t read the video: \(m)"
        }
    }
}

/// The platform edge that turns video into a model's input. Implemented in Services (AVFoundation) and by fakes in tests.
protocol RallyFrameSource: Sendable {
    /// Motion values for `[from, to)` of recording time at `fps`: one value per sample, `nan` where there is no video
    /// (an interruption gap). Throws `RallyScanError`.
    func motion(from: Double, to: Double, fps: Double, gridWidth: Int) async throws -> [Float]
}

/// A rally finder. Async, cancellable (checks `Task.isCancelled` between chunks), reports progress.
protocol RallyModel: Sendable {
    var info: RallyModelInfo { get }
    func scan(_ request: RallyScanRequest, source: RallyFrameSource,
              progress: @escaping @Sendable (RallyScanProgress) async -> Void) async throws -> [RallyGuess]
}

/// The shipping models by id.
enum RacketRallyModels {
    static let all: [RallyModel] = [PlaceholderMotionRallyModel()]

    static func model(for info: RallyModelInfo) -> RallyModel? {
        all.first { $0.info.id == info.id && $0.info.version == info.version }
    }
}

// MARK: - The placeholder model

/// Snappet's placeholder: reads the motion signal chunk by chunk (so it can stop between chunks and resume from the
/// source's cache), then runs `RacketMotionRallyRule`.
struct PlaceholderMotionRallyModel: RallyModel {
    var info: RallyModelInfo = RacketCapabilityRegistry.placeholder
    var chunkSec: Double = 30
    var params = RacketMotionRallyRule.Params()

    func scan(_ request: RallyScanRequest, source: RallyFrameSource,
              progress: @escaping @Sendable (RallyScanProgress) async -> Void) async throws -> [RallyGuess] {
        let fps = info.input.fps
        let grid: Int
        switch info.input { case .motionEnergy(_, let g): grid = g }
        var values: [Float] = []
        var t = request.startSec
        while t < request.endSec - 0.001 {
            try Task.checkCancellation()
            let b = min(request.endSec, t + chunkSec)
            let chunk = try await source.motion(from: t, to: b, fps: fps, gridWidth: grid)
            let n = RacketMotionRallyRule.sampleCount(b - t, fps: fps)
            // Exactly `n` values per chunk keeps sample time = start + index / fps.
            values += chunk.count >= n ? Array(chunk.prefix(n)) : chunk + Array(repeating: .nan, count: n - chunk.count)
            t = b
            await progress(RallyScanProgress(doneSec: t - request.startSec, totalSec: request.lengthSec))
        }
        try Task.checkCancellation()
        guard values.contains(where: { !$0.isNaN }) else { throw RallyScanError.noVideo }
        let signal = RacketMotionSignal(startSec: request.startSec, fps: fps, values: values)
        return RacketMotionRallyRule.rallies(signal, anchors: request.anchors, params: params)
    }
}

// MARK: - The rule (pure)

/// A motion signal on the recording's timeline: sample `i` is at `startSec + i / fps`. `nan` = no video.
struct RacketMotionSignal: Equatable, Sendable {
    var startSec: Double
    var fps: Double
    var values: [Float]

    var endSec: Double { startSec + Double(values.count) / fps }
    func time(_ i: Int) -> Double { startSec + Double(i) / fps }

    static func == (a: Self, b: Self) -> Bool {
        a.startSec == b.startSec && a.fps == b.fps && a.values.count == b.values.count
            && zip(a.values, b.values).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }
}

/// The placeholder's rally rule. A fixed camera sees more movement during a rally (swings, footwork, the ball) than
/// between rallies (walking, picking the ball up). Steps: smooth; a rolling quiet baseline (a low percentile over a
/// minute); one robust spread for the part; hysteresis (start above `zOn`, stay above `zOff`); merge gaps shorter than
/// `gapSec`; drop shorter than `minRallySec`; pad. Then score taps anchor it. Same shape as the spike's frozen rule
/// (gap 1.5 s, minimum 1 s, pad), a much weaker signal — limits in decisions 2026-11-07.
enum RacketMotionRallyRule {
    struct Params: Equatable, Sendable {
        var smoothSec = 0.5
        /// Two minutes: a rally (or a long tennis point) is never most of the window, so the low percentile stays quiet.
        var baselineWindowSec = 120.0
        var baselineBlockSec = 10.0
        var baselinePercentile = 0.2
        var minSpread: Float = 0.004
        var zOn: Float = 3
        var zOff: Float = 1.5
        var gapSec = 1.5
        var minRallySec = 1.5
        /// Longer stretches are kept but unsure (continuous movement, not one rally).
        var maxRallySec = 120.0
        var padStartSec = 0.5
        var padEndSec = 0.5
        /// A score tap confirms the rally ending up to this long before it (or 1 s after).
        var anchorWindowSec = 15.0
        /// A tap with no rally before it adds a guess this long, ending 1 s before the tap.
        var anchorGuessSec = 6.0
    }

    static func sampleCount(_ seconds: Double, fps: Double) -> Int { max(0, Int((seconds * fps).rounded())) }

    static func rallies(_ s: RacketMotionSignal, anchors: [RallyAnchor] = [], params p: Params = Params()) -> [RallyGuess] {
        let raw = detect(s, params: p)
        return anchor(raw, anchors: anchors, within: s.startSec, s.endSec, params: p)
    }

    // MARK: Steps

    /// Moving average over `smoothSec`; a window touching a gap is a gap.
    static func smooth(_ v: [Float], window w: Int) -> [Float] {
        guard w > 1, !v.isEmpty else { return v }
        // Prefix sums of the values (gaps as 0) and of the gaps; window [i-h, i+h].
        var sum = [Double](repeating: 0, count: v.count + 1), gaps = [Int](repeating: 0, count: v.count + 1)
        for (i, x) in v.enumerated() {
            sum[i + 1] = sum[i] + (x.isNaN ? 0 : Double(x))
            gaps[i + 1] = gaps[i] + (x.isNaN ? 1 : 0)
        }
        let h = w / 2
        return v.indices.map { i in
            let lo = max(0, i - h), hi = min(v.count - 1, i + h)
            guard gaps[hi + 1] - gaps[lo] == 0 else { return .nan }
            return Float((sum[hi + 1] - sum[lo]) / Double(hi - lo + 1))
        }
    }

    /// Percentile of the valid values (linear between ranks); nil when none.
    static func percentile(_ v: [Float], _ q: Double) -> Float? {
        let xs = v.filter { !$0.isNaN }.sorted()
        guard !xs.isEmpty else { return nil }
        let r = q * Double(xs.count - 1)
        let lo = Int(r.rounded(.down)), hi = min(xs.count - 1, lo + 1)
        let f = Float(r - Double(lo))
        return xs[lo] + (xs[hi] - xs[lo]) * f
    }

    /// The quiet level around each sample: the `baselinePercentile` of a `baselineWindowSec` window, computed per
    /// `baselineBlockSec` block and held across it.
    static func baseline(_ v: [Float], fps: Double, params p: Params) -> [Float] {
        let block = max(1, Int(p.baselineBlockSec * fps)), half = max(block, Int(p.baselineWindowSec * fps / 2))
        let global = percentile(v, p.baselinePercentile) ?? 0
        var out = [Float](repeating: global, count: v.count)
        var start = 0
        while start < v.count {
            let mid = start + block / 2
            let lo = max(0, mid - half), hi = min(v.count, mid + half)
            let b = percentile(Array(v[lo..<hi]), p.baselinePercentile) ?? global
            for i in start..<min(v.count, start + block) { out[i] = b }
            start += block
        }
        return out
    }

    /// Candidate rallies from the signal alone, with a confidence from how far above the quiet level they stood.
    static func detect(_ s: RacketMotionSignal, params p: Params = Params()) -> [RallyGuess] {
        guard s.values.count > 2, s.fps > 0 else { return [] }
        let sm = smooth(s.values, window: max(1, Int((p.smoothSec * s.fps).rounded())))
        let base = baseline(sm, fps: s.fps, params: p)
        var resid: [Float] = []
        resid.reserveCapacity(sm.count)
        for i in sm.indices where !sm[i].isNaN { resid.append(abs(sm[i] - base[i])) }
        let spread = max(p.minSpread, 1.4826 * (percentile(resid, 0.5) ?? 0))
        let z = sm.indices.map { i -> Float in sm[i].isNaN ? .nan : (sm[i] - base[i]) / spread }

        // Hysteresis.
        var runs: [(Int, Int)] = []
        var open: Int?
        for i in z.indices {
            let zi = z[i]
            if let o = open {
                if zi.isNaN || zi < p.zOff { runs.append((o, i)); open = nil }
            } else if !zi.isNaN, zi >= p.zOn {
                open = i
            }
        }
        if let o = open { runs.append((o, z.count)) }

        // Merge short gaps (never across missing video).
        let gap = Int(p.gapSec * s.fps)
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 - last.1 <= gap, !(last.1..<r.0).contains(where: { z[$0].isNaN }) {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }

        // Confidence is relative: a stretch as strong as this part's typical one is a likely rally (0.75); one with a
        // quarter of the movement is unsure. Absolute levels vary too much with the camera, light and distance.
        let kept = merged.filter { Double($0.1 - $0.0) / s.fps >= p.minRallySec }
        func meanZ(_ r: (Int, Int)) -> Float {
            let zs = z[r.0..<r.1].filter { !$0.isNaN }
            return zs.reduce(0, +) / Float(max(1, zs.count))
        }
        let typical = max(p.zOn, percentile(kept.map(meanZ), 0.5) ?? p.zOn)
        var out: [RallyGuess] = []
        for (a, b) in kept {
            let dur = Double(b - a) / s.fps
            let m = meanZ((a, b))
            var c = Double(min(0.85, max(0.1, 0.25 + 0.5 * m / typical)))
            if m < 2 * p.zOn { c *= 0.7 }
            if dur < 2.5 { c *= 0.7 }
            if dur > p.maxRallySec { c = min(c, 0.3) }
            var start = s.time(a) - p.padStartSec
            let end = min(s.endSec, s.time(b) + p.padEndSec)
            start = max(s.startSec, max(out.last?.endSec ?? -.infinity, start))
            guard end - start >= p.minRallySec else { continue }
            out.append(RallyGuess(startSec: start, endSec: end, confidence: (c * 100).rounded() / 100))
        }
        return out
    }

    /// Score taps: each point tapped ends the rally before it. A found rally ending within `anchorWindowSec` before a
    /// tap is confirmed (confidence up, the tap's winner suggested); a tap with no rally before it adds an unsure guess;
    /// with two or more taps, a found stretch between them that no tap confirms is probably not a rally (picking the
    /// ball up) and turns unsure.
    static func anchor(_ guesses: [RallyGuess], anchors: [RallyAnchor], within lo: Double, _ hi: Double,
                       params p: Params = Params()) -> [RallyGuess] {
        let taps = anchors.filter { $0.atSec > lo && $0.atSec <= hi + 1 }.sorted { $0.atSec < $1.atSec }
        guard !taps.isEmpty else { return guesses }
        var out = guesses
        var used = Set<Int>()
        for tap in taps {
            let cand = out.indices.filter { i in
                !used.contains(i) && out[i].endSec <= tap.atSec + 1 && out[i].endSec >= tap.atSec - p.anchorWindowSec
            }
            if let i = cand.max(by: { out[$0].endSec < out[$1].endSec }) {
                used.insert(i)
                out[i].confidence = min(0.95, ((out[i].confidence + 0.3) * 100).rounded() / 100)
                out[i].winnerRaw = tap.winner?.rawValue
                out[i].anchored = true
            } else {
                let end = tap.atSec - 1
                let prevEnd = out.filter { $0.endSec <= end }.map(\.endSec).max() ?? lo
                let start = max(lo, prevEnd, end - p.anchorGuessSec)
                guard end - start >= 1 else { continue }
                out.append(RallyGuess(startSec: start, endSec: end, confidence: 0.3, winnerRaw: tap.winner?.rawValue,
                                      anchored: true))
                used.insert(out.count - 1)
            }
        }
        if taps.count >= 2, let first = taps.first?.atSec, let last = taps.last?.atSec {
            for i in out.indices where !used.contains(i) && out[i].startSec > first - 1 && out[i].endSec < last {
                out[i].confidence = min(out[i].confidence, (out[i].confidence * 0.6 * 100).rounded() / 100)
            }
        }
        return out.sorted { $0.startSec < $1.startSec }
    }
}

// MARK: - Anchors from the recording

enum RacketScanAnchors {
    /// Point taps (`point` marks, prompt 248) inside the range, with who won; older recordings have only each game's
    /// first point (`firstPoint`), which anchors without a winner.
    static func anchors(_ log: RacketRecordingLog, from lo: Double, to hi: Double) -> [RallyAnchor] {
        let points = log.marks.filter { $0.kind == .point && $0.startSec > lo && $0.startSec <= hi + 1 }
        if !points.isEmpty {
            return points.map { RallyAnchor(atSec: $0.startSec, winner: $0.index == 1 ? .them : $0.index == 0 ? .us : nil) }
        }
        return log.marks.filter { $0.kind == .firstPoint && $0.startSec > lo && $0.startSec <= hi + 1 }
            .map { RallyAnchor(atSec: $0.startSec, winner: nil) }
    }
}

// MARK: - Scans stored on the recording

/// One scan of one part (Analyzing, ChooseModel "Older results stay available", ModelCompare).
struct RacketScanRecord: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, running
        /// Stopped by the user, by leaving the app, or by heat; Resume picks up where it stopped.
        case paused
        case done, failed
    }

    var id = UUID()
    var modelID: String
    var modelVersion: Int
    var modelName: String
    var partStart: Double
    var partEnd: Double
    var startedAt: Date
    var finishedAt: Date?
    /// Recording seconds scanned (from `partStart`), for "62%" after a relaunch.
    var doneSec: Double = 0
    var statusRaw: String
    /// Why it paused or failed, in the user's words.
    var note: String?
    var guesses: [RallyGuess]?
    /// These results are the ones on the timeline now ("Used for this video now").
    var applied: Bool?
    /// Compare before replacing: results wait for ModelCompare.
    var compare: Bool?
    /// "Scan all on charger".
    var waitForCharger: Bool?

    var status: Status { Status(rawValue: statusRaw) ?? .paused }
    var fraction: Double { partEnd > partStart ? min(1, doneSec / (partEnd - partStart)) : 0 }
    var isActive: Bool { status == .queued || status == .running }
    var isPendingCompare: Bool { status == .done && applied != true && compare == true }
    var modelLabel: String { "\(modelName) v\(modelVersion)" }

    func covers(_ lo: Double, _ hi: Double) -> Bool { abs(partStart - lo) < 0.5 && abs(partEnd - hi) < 0.5 }
}

extension RacketRecordingLog {
    var allScans: [RacketScanRecord] { scans ?? [] }

    /// Scans of exactly this part, oldest first.
    func scans(partStart lo: Double, partEnd hi: Double) -> [RacketScanRecord] {
        allScans.filter { $0.covers(lo, hi) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The scan whose results are on the part's timeline: one of exactly this part, else one of a range holding it (a
    /// whole recording scanned before it was split — rallies live on the recording's timeline, so they carry over).
    func appliedScan(partStart lo: Double, partEnd hi: Double) -> RacketScanRecord? {
        if let exact = scans(partStart: lo, partEnd: hi).last(where: { $0.applied == true }) { return exact }
        return allScans.filter { $0.applied == true && $0.partStart <= lo + 0.5 && $0.partEnd >= hi - 0.5 }
            .max { $0.startedAt < $1.startedAt }
    }

    /// The newest scan of the part (any state).
    func latestScan(partStart lo: Double, partEnd hi: Double) -> RacketScanRecord? {
        scans(partStart: lo, partEnd: hi).last
    }

    mutating func updateScan(_ id: UUID, _ body: (inout RacketScanRecord) -> Void) {
        guard var all = scans, let i = all.firstIndex(where: { $0.id == id }) else { return }
        body(&all[i])
        scans = all
    }
}

/// One row's scan state on Your videos / Drill videos.
enum RacketScanState: Equatable, Sendable {
    case notScanned
    case scanning(Double)
    case queued
    case waiting
    case paused(Double, note: String?)
    case failed(String)
    case scanned(modelLabel: String, newerAvailable: Bool)
    case readyToCompare

    static func of(_ log: RacketRecordingLog, partStart lo: Double, partEnd hi: Double,
                   current: RallyModelInfo?) -> RacketScanState {
        let all = log.scans(partStart: lo, partEnd: hi)
        if let s = all.last(where: { $0.isActive }) {
            if s.status == .running { return .scanning(s.fraction) }
            return s.waitForCharger == true ? .waiting : .queued
        }
        if let last = all.last {
            switch last.status {
            case .paused: return .paused(last.fraction, note: last.note)
            case .failed: return .failed(last.note ?? "Couldn’t scan")
            case .done where last.isPendingCompare: return .readyToCompare
            default: break
            }
        }
        if let a = log.appliedScan(partStart: lo, partEnd: hi) {
            let newer = current.map { $0.id != a.modelID || $0.version > a.modelVersion } ?? false
            return .scanned(modelLabel: a.modelLabel, newerAvailable: newer)
        }
        return .notScanned
    }

    /// The row's chip: "Snappet placeholder v1", "Not scanned", "62%", "Paused at 62%".
    var chip: String {
        switch self {
        case .notScanned: return "Not scanned"
        case .scanning(let f): return "Scanning · \(Int((f * 100).rounded()))%"
        case .queued: return "Waiting to scan"
        case .waiting: return "Waiting for a charger"
        case .paused(let f, _): return "Paused at \(Int((f * 100).rounded()))%"
        case .failed: return "Not scanned"
        case .scanned(let m, _): return m
        case .readyToCompare: return "New scan ready"
        }
    }

    var isScanned: Bool {
        if case .scanned = self { return true }
        return self == .readyToCompare
    }
}

// MARK: - Guesses on the timeline

enum RacketRallyGuessMerge {
    /// Below this a guess is "unsure" (dashed; "Check N unsure rallies").
    static let unsureBelow = 0.6

    /// Put a scan's guesses on the part: earlier guesses you haven't confirmed are replaced; your rallies, rallies you
    /// accepted from another app, and guesses you tagged or checked are kept, and a new guess that overlaps one of them
    /// is dropped. Rallies outside the part are untouched.
    static func apply(_ guesses: [RallyGuess], source: String, to rallies: [RacketRally],
                      partStart lo: Double, partEnd hi: Double) -> [RacketRally] {
        func inPart(_ r: RacketRally) -> Bool { r.startSec >= lo - 0.01 && r.startSec < hi }
        let kept = rallies.filter { !inPart($0) || !$0.isGuess }
        let keptInPart = kept.filter(inPart)
        var out = kept
        for g in guesses.sorted(by: { $0.startSec < $1.startSec }) {
            let a = max(lo, g.startSec), b = min(hi, g.endSec)
            guard b - a >= RacketRallyMarking.minRallySec,
                  !RacketRallyMarking.overlaps(a, b, keptInPart + out.filter(inPart).filter(\.isGuess), except: nil)
            else { continue }
            var r = RacketRally(startSec: a, endSec: b)
            r.sourceRaw = source
            r.confidence = g.confidence
            r.guessWinnerRaw = g.winnerRaw
            out.append(r)
        }
        return out.sorted { $0.startSec < $1.startSec }
    }
}

// MARK: - Model vs model (TtModelCompare)

struct RacketModelCompareItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable { case split, merged, onlyNew, onlyOld, winner }
    var kind: Kind
    /// 1-based, in the newer scan's order (the older's when only it found the rally).
    var number: Int
    var title: String
    var newer: String
    var older: String
    /// Where it is on the recording, for ordering.
    var atSec: Double = 0
    var id: String { "\(kind.rawValue)-\(number)-\(newer)-\(older)" }
}

struct RacketModelCompareResult: Equatable, Sendable {
    var items: [RacketModelCompareItem]
    var newerCount: Int
    var olderCount: Int
    var newerName: String
    var olderName: String

    /// "3 differences".
    var differencesLine: String {
        items.isEmpty ? "No differences" : "\(items.count) \(items.count == 1 ? "difference" : "differences")"
    }
    /// "v3 found 23 rallies, v2 found 21".
    var countsLine: String { "\(newerName) found \(newerCount) \(newerCount == 1 ? "rally" : "rallies"), \(olderName) found \(olderCount)" }
}

enum RacketModelCompare {
    static func overlaps(_ a: RallyGuess, _ b: RallyGuess) -> Bool {
        min(a.endSec, b.endSec) - max(a.startSec, b.startSec) > 0.25
    }

    /// Short names for two scans: "v3" / "v2" when the versions differ, the model names when the models differ, "New
    /// scan" / "Earlier scan" for the same model twice.
    static func names(newer: RacketScanRecord, older: RacketScanRecord) -> (String, String) {
        if newer.modelID == older.modelID {
            return newer.modelVersion != older.modelVersion ? ("v\(newer.modelVersion)", "v\(older.modelVersion)")
                : ("New scan", "Earlier scan")
        }
        return (newer.modelLabel, older.modelLabel)
    }

    /// `within` limits both sides to a part (an earlier scan may have covered the whole recording).
    static func build(newer: [RallyGuess], older: [RallyGuess], newerName: String, olderName: String,
                      sides: (us: String, them: String), within: ClosedRange<Double>? = nil) -> RacketModelCompareResult {
        func keep(_ g: RallyGuess) -> Bool { within.map { g.startSec >= $0.lowerBound - 0.01 && g.startSec < $0.upperBound } ?? true }
        let n = newer.filter(keep).sorted { $0.startSec < $1.startSec }, o = older.filter(keep).sorted { $0.startSec < $1.startSec }
        var items: [RacketModelCompareItem] = []
        var oSeen = Set<Int>()
        for (i, g) in n.enumerated() {
            let hits = o.indices.filter { overlaps(g, o[$0]) }
            hits.forEach { oSeen.insert($0) }
            let num = i + 1
            if hits.isEmpty {
                items.append(.init(kind: .onlyNew, number: num, title: "Rally \(num) · found only by \(newerName)",
                                   newer: "\(newerName): a rally", older: "\(olderName): nothing", atSec: g.startSec))
            } else if hits.count >= 2 {
                items.append(.init(kind: .merged, number: num, title: "Rally \(num) · one rally or \(hits.count)?",
                                   newer: "\(newerName): one", older: "\(olderName): \(hits.count == 2 ? "two" : "\(hits.count)")",
                                   atSec: g.startSec))
            } else {
                let og = o[hits[0]]
                let split = n.indices.filter { overlaps(n[$0], og) }
                if split.count >= 2 {
                    // Report a split once, at its first piece.
                    if split.first == i {
                        items.append(.init(kind: .split, number: num, title: "Rally \(num) · one rally or two?",
                                           newer: "\(newerName): \(split.count == 2 ? "two" : "\(split.count)")",
                                           older: "\(olderName): one", atSec: g.startSec))
                    }
                } else if let w = g.winner, let ow = og.winner, w != ow {
                    func t(_ x: RacketRallyWinner) -> String { x == .us ? "\(sides.us) won" : "\(sides.them) won" }
                    items.append(.init(kind: .winner, number: num, title: "Rally \(num) · winner",
                                       newer: "\(newerName): \(t(w))", older: "\(olderName): \(t(ow))", atSec: g.startSec))
                }
            }
        }
        for (j, g) in o.enumerated() where !oSeen.contains(j) {
            let num = (n.firstIndex { $0.startSec > g.startSec } ?? n.count) + 1
            items.append(.init(kind: .onlyOld, number: num, title: "Rally near \(num) · found only by \(olderName)",
                               newer: "\(newerName): nothing", older: "\(olderName): a rally", atSec: g.startSec))
        }
        return RacketModelCompareResult(items: items.sorted { $0.atSec < $1.atSec }, newerCount: n.count,
                                        olderCount: o.count, newerName: newerName, olderName: olderName)
    }
}

// MARK: - Progress (Analyzing)

enum RacketScanETA {
    /// Seconds left from the measured rate (recording seconds per wall second), once there's enough to measure.
    static func remaining(doneSec: Double, totalSec: Double, elapsedWallSec: Double) -> Double? {
        guard doneSec >= 30, elapsedWallSec >= 2, totalSec > doneSec else { return totalSec <= doneSec ? 0 : nil }
        return (totalSec - doneSec) * elapsedWallSec / doneSec
    }

    /// "about 4 min left" / "under a minute left" / "working out the time left".
    static func line(_ sec: Double?) -> String {
        guard let sec else { return "working out the time left" }
        if sec < 60 { return "under a minute left" }
        return "about \(Int((sec / 60).rounded())) min left"
    }

    /// "Game 2 · 62% · about 4 min left".
    static func headline(title: String, fraction: Double, eta: Double?) -> String {
        "\(title) · \(Int((fraction * 100).rounded()))% · \(line(eta))"
    }
}

// MARK: - Analysis settings (AnalysisSettings)

enum RacketAutoScan: String, CaseIterable, Codable, Sendable {
    case automatically, onCharger, ask, never

    static let storageKey = "racket.analysis.afterSession"
    /// "Ask me" until the user picks: a scan warms the phone and uses battery, so it starts only when asked.
    static let `default`: RacketAutoScan = .ask

    var title: String {
        switch self {
        case .automatically: return "Automatically"
        case .onCharger: return "Only on charger"
        case .ask: return "Ask me"
        case .never: return "Never"
        }
    }

    var detail: String {
        switch self {
        case .automatically: return "Starts when you finish"
        case .onCharger: return "Waits until it’s plugged in"
        case .ask: return "You choose each time"
        case .never: return "Use Find rallies on any video"
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> RacketAutoScan {
        defaults.string(forKey: storageKey).flatMap(RacketAutoScan.init(rawValue:)) ?? .default
    }

    enum Decision: Equatable, Sendable { case start, startOnCharger, ask, nothing }

    /// What Your videos does with parts nobody has scanned yet, the first time it opens after a session.
    static func decision(_ setting: RacketAutoScan, unscanned: Int, alreadyHandled: Bool) -> Decision {
        guard unscanned > 0, !alreadyHandled else { return .nothing }
        switch setting {
        case .automatically: return .start
        case .onCharger: return .startOnCharger
        case .ask: return .ask
        case .never: return .nothing
        }
    }
}

// MARK: - Guess counts (Summary · TagDone)

struct RacketGuessSummary: Equatable, Sendable {
    /// Rallies on the part (yours + guesses), "Not a rally" excluded.
    var found: Int
    /// Guesses you haven't tagged or checked.
    var guesses: Int
    /// Guesses the model wasn't sure of (any state).
    var unsureTotal: Int
    /// Of those, not checked yet.
    var unsureLeft: Int
    var longestSec: Double?
    var averageSec: Double?

    static func make(_ rallies: [RacketRally]) -> RacketGuessSummary {
        let rs = rallies.filter(\.isRally)
        let unsure = rallies.filter { RacketModelSource.isModel($0.sourceRaw) && ($0.confidence ?? 1) < RacketRallyGuessMerge.unsureBelow }
        let d = rs.map(\.durationSec).filter { $0 > 0 }
        return RacketGuessSummary(found: rs.count, guesses: rs.filter(\.isGuess).count, unsureTotal: unsure.count,
                                  unsureLeft: rs.filter(\.isUnsure).count, longestSec: d.max(),
                                  averageSec: d.isEmpty ? nil : d.reduce(0, +) / Double(d.count))
    }

    /// TagDone headline in the model path: "4 of 4 checked".
    var checkedLine: String { "\(unsureTotal - unsureLeft) of \(unsureTotal) checked" }
}
