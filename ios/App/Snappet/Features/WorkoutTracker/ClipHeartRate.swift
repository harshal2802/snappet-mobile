import Foundation
import HighlightEngine

/// What a surface asks for on top of a clip's own footage when it reads heart rate (prompt 309).
/// Everything a surface may legitimately do differently is a field here; nothing else about the
/// reading can differ between two surfaces.
struct ClipHROptions: Sendable, Equatable {
    /// Seconds of heart rate shown before the first frame (prompt 115). Clamped so the window
    /// cannot start before the session.
    var leadSec: Double = 0
    /// Seconds of heart rate shown after the last frame.
    var tailSec: Double = 0
    /// Which samples the peak, the average and the other aggregates are taken over: the whole
    /// window, or the footage only. The chart always shows the whole window.
    var scope: HRMetricsScope = .window
    /// The session's maximum heart rate, for zones and colours. `nil` = `HeartRateZone.defaultMaxHR`.
    var maxHR: Double? = nil
    /// The session's resting heart rate, for % effort and recovery. `nil` hides those.
    var restHR: Double? = nil
    /// The profile calories are estimated from. `nil` = no calories (every surface but the Studio).
    var energyProfile: UserHRProfile? = nil
    /// Whether heart-rate variability is worked out from the window's RR intervals (the Studio).
    var includesHRV: Bool = false
    /// How far outside the recorded heart rate a clip may lie and still show the nearest reading
    /// held flat (`HRWindowSlicer`).
    var clampTolerance: Double = HRWindowSlicer.defaultClampTolerance

    /// The footage and nothing around it: a reel's clips.
    static let footageOnly = ClipHROptions()

    /// A photo: one moment, read over 10 s either side of it (the lead-in is shorter for a photo
    /// taken in the session's first 10 s).
    static let photo = ClipHROptions(leadSec: 10, tailSec: 10)

    /// A clip as the feed, the viewers, the poster chip and the activity pages read it: the
    /// clip's own HR window (its Studio edit, or the Studio's defaults for a clip never edited).
    static func clip(edit: ClipStudioEdit?, maxHR: Double?, restHR: Double?) -> ClipHROptions {
        let edit = edit ?? ClipStudioEdit()
        return ClipHROptions(leadSec: edit.hrLeadSec, tailSec: edit.hrTailSec, scope: edit.hrMetricsScope,
                             maxHR: maxHR, restHR: restHR)
    }

    /// A clip on the Studio's timeline: its HR-window sliders, plus calories and HRV.
    static func studio(clip: TimelineClip, maxHR: Double?, restHR: Double?,
                       profile: UserHRProfile?) -> ClipHROptions {
        ClipHROptions(leadSec: clip.hrWindowLeadSec, tailSec: clip.hrWindowTailSec,
                      scope: clip.hrMetricsScope, maxHR: maxHR, restHR: restHR,
                      energyProfile: profile, includesHRV: true)
    }
}

/// A clip's heart rate, resolved: everything a surface draws or prints comes from this value.
struct ClipHR: Sendable {
    /// The session second the window starts at (the footage's first frame minus the lead-in).
    let captureStartSec: Double
    /// The window's shape: lead-in, footage and tail, in seconds of the session.
    let window: HRClipWindow
    /// The window's samples; `t` runs from 0 at `captureStartSec`. Recorded samples inside the
    /// window, plus one reading at each edge (`HRWindowSlicer`). Never fewer than two.
    let samples: [HRPoint]
    /// The range of the video the asset plays now that the footage is (seconds).
    let renditionStartSec: Double
    let renditionEndSec: Double
    /// The text, colours and chart every tile is drawn from.
    let values: HROverlayValues

    /// `false` when no recorded sample lies in the window: the readings are the nearest recorded
    /// sample held (a window just outside the recording), or a straight line between two samples
    /// either side of it, not measurements. The tile draws such a window dashed
    /// (`HROverlayValues.isSparseChart`) and may show it; a surface with no chart prints no
    /// number for it (`ClipHRSummary.hasRecordedSample`).
    let hasRecordedSample: Bool

    /// The footage's readings in rendition time with each recorded sample once: what a reel's
    /// AVG and PEAK count (`ClipHeartRate.countedOnce`).
    var countedRenditionSamples: [HRPoint] { ClipHeartRate.countedOnce(renditionSamples) }

    /// The footage's samples in **rendition time**: `t` is seconds into the video the asset plays
    /// now, from `renditionStartSec` to `renditionEndSec`. The footage's stretch of the session
    /// is laid evenly over the video (the rule the playhead dot follows), so a clip baked at 2×
    /// has its 20 s of heart rate over its 10 s of video.
    var renditionSamples: [HRPoint] { Self.renditionTimed(footage(of: samples), self) }

    /// The same for the smoothed series the chart and the live number are read from.
    var renditionChartSamples: [HRPoint] {
        let maxT = values.chartMaxT
        let from = window.footageStartFraction(maxT: maxT) * maxT
        let to = window.footageEndFraction(maxT: maxT) * maxT
        let chart = values.chartSamples
        var inside = chart.filter { $0.t > from && $0.t < to }
        if let first = HRChartGeometry.sampleBPM(chart, atFraction: maxT > 0 ? from / maxT : 0) {
            inside.insert(HRPoint(t: from, bpm: first), at: 0)
        }
        if to > from, let last = HRChartGeometry.sampleBPM(chart, atFraction: maxT > 0 ? to / maxT : 0) {
            inside.append(HRPoint(t: to, bpm: last))
        }
        return Self.renditionTimed(inside.map { HRPoint(t: $0.t - window.leadSec, bpm: $0.bpm) }, self)
    }

    private func footage(of samples: [HRPoint]) -> [HRPoint] {
        window.isExtended
            ? HRWindowSlicer.slice(samples, start: window.leadSec, span: window.footageSec)
            : samples
    }

    /// Footage-local capture seconds → seconds of the video.
    private static func renditionTimed(_ footage: [HRPoint], _ hr: ClipHR) -> [HRPoint] {
        let scale = hr.window.footageSec > 0
            ? (hr.renditionEndSec - hr.renditionStartSec) / hr.window.footageSec : 0
        return footage.map {
            HRPoint(t: hr.renditionStartSec + $0.t * scale, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs)
        }
    }
}

/// A clip's peak and average, as numbers. The cheap result for a surface that prints nothing
/// else (the poster chip, the activity pages): no chart is built for it.
struct ClipHRSummary: Sendable, Equatable {
    /// The highest reading over the options' scope.
    var peakBpm: Double
    /// The plain mean of the readings over the options' scope.
    var averageBpm: Double
    /// `false` when no recorded sample lies in the clip's window: the numbers are a held or a
    /// drawn-between reading, not a measurement (see `ClipHR.hasRecordedSample`).
    var hasRecordedSample: Bool = true

    /// The summary a surface WITH NO CHART prints (the activity row and the caption in its
    /// viewer, the Recap poster chip): a number only when a recorded sample lies in the clip's
    /// window. The tile, which draws a dashed line for a held reading, may show one; a bare
    /// "♥ 132" has no way to say it is not a measurement. One rule for all of them.
    var printable: ClipHRSummary? { hasRecordedSample ? self : nil }

    /// Whole beats, rounded the one way every surface rounds.
    var peak: Int { ClipHeartRate.rounded(peakBpm) }
    var average: Int { ClipHeartRate.rounded(averageBpm) }

    /// The zone of the peak against `maxHR`.
    func peakZone(maxHR: Double?) -> HeartRateZone {
        HeartRateZone.forBpm(peakBpm, maxHR: maxHR ?? HeartRateZone.defaultMaxHR)
    }
}

/// A clip with no heart rate to show: the session recorded none, or the footage lies more than
/// the clamp tolerance outside the recording. The window is still known (the Studio's HR-window
/// sliders show it).
struct ClipHRGap: Sendable, Equatable {
    var captureStartSec: Double
    var window: HRClipWindow
}

/// The answer of `ClipHeartRate.resolve`: readings, or an explicit "no data".
enum ClipHRResult: Sendable {
    case data(ClipHR)
    case noData(ClipHRGap)

    var data: ClipHR? {
        if case .data(let hr) = self { return hr }
        return nil
    }

    var window: HRClipWindow {
        switch self {
        case .data(let hr): return hr.window
        case .noData(let gap): return gap.window
        }
    }

    var captureStartSec: Double {
        switch self {
        case .data(let hr): return hr.captureStartSec
        case .noData(let gap): return gap.captureStartSec
        }
    }
}

/// **The one heart-rate resolver** (prompt 309): which samples belong to a clip, and what numbers
/// are shown for it. The Clips feed's overlay and its viewers, "Share with heart rate", the poster
/// chip, the activity pages' average, the Studio (preview tile, HR-window sliders, export, bake)
/// and the reel maker's scorebug all call it, so one clip over one series gives the same reading
/// everywhere. Pure: Foundation and the app's value types only.
///
/// The rules, each in one place:
/// - **When a frame was filmed**: `ClipCaptureClock` (prompt 305).
/// - **The window**: the footage's capture window, widened by `options.leadSec` (clamped at the
///   session's start) and `options.tailSec`.
/// - **Which samples**: `HRWindowSlicer`. Recorded samples inside the window, plus one reading at
///   each edge, read off the straight line between the two samples around it.
/// - **Outside the recording**: footage more than `clampTolerance` (90 s) before the first
///   recorded sample or after the last one, measured from the footage's nearest edge, has no
///   data, on either side; the lead-in and the tail do not move this limit. Nearer than that, a
///   window that reaches no recorded sample shows the nearest one, held. A window with no
///   recorded sample in it (`hasRecordedSample == false`) is shown by the tile, dashed, and by
///   no surface that prints a bare number (`ClipHRSummary.printable`).
/// - **The reading at a moment**: straight-line interpolation in the window's display series
///   (`HRChartGeometry.displaySeries`: a 0.5 s grid, smoothed over 2 s). Never "hold the last
///   sample".
/// - **Peak and average**: the highest reading and the plain mean of the readings in the scope
///   (the whole window, or the footage for `.clip`), from `WorkoutHRStats`. Each recorded sample
///   counts once: where a window reaches past the first or the last recorded sample the slicer's
///   edge reading is that sample again, at the same time; such a repeat is dropped once
///   (`countedOnce`), before the footage is cut out of the window, and again after.
/// - **Rounding**: to the nearest whole beat, halves away from zero.
/// - **Zone**: `HeartRateZone.forBpm` against `options.maxHR`, or 190 when the session has none.
enum ClipHeartRate {

    /// A clip's heart rate over the rendition range `[renditionStart, renditionEnd]` (seconds of
    /// the video the asset plays now; the whole video is `0 … its length`).
    static func resolve(series: [HRPoint], clock: ClipCaptureClock,
                        renditionStart: Double, renditionEnd: Double,
                        options: ClipHROptions) -> ClipHRResult {
        let slice = slice(series: series, clock: clock, renditionStart: renditionStart,
                          renditionEnd: renditionEnd, options: options)
        guard !slice.samples.isEmpty else {
            return .noData(ClipHRGap(captureStartSec: slice.start, window: slice.window))
        }
        return .data(ClipHR(captureStartSec: slice.start, window: slice.window, samples: slice.samples,
                            renditionStartSec: renditionStart,
                            renditionEndSec: max(renditionStart, renditionEnd),
                            values: values(samples: slice.samples, window: slice.window, options: options,
                                           scoped: slice.scoped, counted: slice.counted),
                            hasRecordedSample: slice.hasRecordedSample))
    }

    /// The peak and the average `resolve` gives, without building the chart. `nil` = no data.
    static func summary(series: [HRPoint], clock: ClipCaptureClock,
                        renditionStart: Double, renditionEnd: Double,
                        options: ClipHROptions) -> ClipHRSummary? {
        let slice = slice(series: series, clock: clock, renditionStart: renditionStart,
                          renditionEnd: renditionEnd, options: options)
        guard let stats = WorkoutHRStats.make(from: slice.counted ?? slice.scoped?.samples ?? slice.samples)
        else { return nil }
        return ClipHRSummary(peakBpm: stats.maxBpm, averageBpm: stats.avgBpm,
                             hasRecordedSample: slice.hasRecordedSample)
    }

    /// The window a clip's heart rate is read over: the footage's capture window from the clock,
    /// with the lead-in clamped so it cannot start before the session.
    /// (For footage filmed before the session began the lead-in comes out negative: the window
    /// starts at the session's start and the footage lies before the chart's left edge.)
    static func window(clock: ClipCaptureClock, renditionStart: Double, renditionEnd: Double,
                       leadSec: Double, tailSec: Double) -> (start: Double, window: HRClipWindow) {
        let footage = clock.captureWindow(renditionStart: renditionStart, renditionEnd: renditionEnd)
        let span = max(0.001, footage.span)
        let lead = min(max(0, leadSec), footage.start)
        return (footage.start - lead, HRClipWindow(leadSec: lead, footageSec: span, tailSec: max(0, tailSec)))
    }

    /// The values for a tile that is NOT over one clip's window (the Studio's whole-session
    /// fallback for a clip whose row cannot be found): the same builder, no window.
    static func values(samples: [HRPoint], window: HRClipWindow?, options: ClipHROptions) -> HROverlayValues {
        values(samples: samples, window: window, options: options,
               scoped: window.flatMap { scoped(samples: samples, window: $0, scope: options.scope) },
               counted: nil)
    }

    /// `samples` with each reading at one time once. `HRWindowSlicer` reads a window's edge off
    /// the series; where the window reaches past the first or the last recorded sample that
    /// reading IS the sample, returned at the sample's own time, so the sample is in the slice
    /// twice. The line is not changed by it; an average is.
    static func countedOnce(_ samples: [HRPoint]) -> [HRPoint] {
        var out: [HRPoint] = []
        out.reserveCapacity(samples.count)
        for point in samples {
            if let last = out.last, abs(point.t - last.t) < 1e-6, point.bpm == last.bpm { continue }
            out.append(point)
        }
        return out
    }

    /// A reading as a whole number of beats.
    static func rounded(_ bpm: Double) -> Int { Int(bpm.rounded()) }

    // MARK: - Private

    private struct Slice {
        var start: Double
        var window: HRClipWindow
        /// The window's samples, window-local. Empty = no data.
        var samples: [HRPoint] = []
        /// The footage's part of them, when the scope is the footage and the window is wider.
        var scoped: (samples: [HRPoint], span: Double)? = nil
        /// The readings the peak and the average count, when that is not all of the scope's
        /// samples (an edge reading that repeats a recorded sample is left out). `nil` = all.
        var counted: [HRPoint]? = nil
        var hasRecordedSample = false
    }

    private static func values(samples: [HRPoint], window: HRClipWindow?, options: ClipHROptions,
                               scoped: (samples: [HRPoint], span: Double)?,
                               counted: [HRPoint]?) -> HROverlayValues {
        let span = samples.last?.t ?? 0
        let statsSamples = scoped?.samples ?? samples
        let statsSpan = scoped?.span ?? span
        let kcal = options.energyProfile?.estimatedKcal(forSeries: statsSamples, durationSec: statsSpan)
        let hrv = options.includesHRV
            ? HRVMetrics.make(
                from: statsSamples.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
                start: 0, end: statsSpan)
            : .empty
        return HROverlayValues(samples: samples, durationSec: span, maxHR: options.maxHR, restHR: options.restHR,
                               kcal: kcal, hrv: hrv, window: window,
                               statsSamples: scoped?.samples, statsDurationSec: scoped?.span,
                               countedSamples: counted)
    }

    private static func slice(series: [HRPoint], clock: ClipCaptureClock,
                              renditionStart: Double, renditionEnd: Double,
                              options: ClipHROptions) -> Slice {
        let ext = window(clock: clock, renditionStart: renditionStart, renditionEnd: renditionEnd,
                         leadSec: options.leadSec, tailSec: options.tailSec)
        var out = Slice(start: ext.start, window: ext.window)
        let footage = clock.captureWindow(renditionStart: renditionStart, renditionEnd: renditionEnd)
        let footageEnd = footage.start + max(0, footage.span)
        // The window as asked for, before the slicer's clamps (footage filmed before the session
        // starts before second 0).
        let askedFrom = min(ext.start, footage.start)
        let askedTo = footageEnd + ext.window.tailSec
        guard let recorded = recorded(series, from: askedFrom, to: askedTo) else { return out }

        // Outside the recording: one limit, on both sides, from the footage's nearest edge.
        if footage.start > recorded.last + options.clampTolerance
            || footageEnd < recorded.first - options.clampTolerance { return out }

        out.samples = HRWindowSlicer.slice(series, start: ext.start, span: ext.window.spanSec,
                                           clampTolerance: options.clampTolerance)
        guard !out.samples.isEmpty else { return out }
        out.hasRecordedSample = recorded.anyInside
        // Each recorded sample once: repeats are dropped from the window's samples BEFORE the
        // footage is cut out of them (the cut would otherwise carry the repeat inside), and from
        // the cut again (it makes its own edge readings).
        let once = countedOnce(out.samples)
        if let scoped = scoped(samples: out.samples, window: ext.window, scope: options.scope) {
            out.scoped = scoped
            out.counted = self.scoped(samples: once, window: ext.window, scope: options.scope)
                .map { countedOnce($0.samples) }
        } else if once.count != out.samples.count {
            out.counted = once
        }
        return out
    }

    /// The first and the last recorded second of a series, and whether a recorded sample lies
    /// in `from … to`. One pass.
    private static func recorded(_ series: [HRPoint], from: Double, to: Double)
        -> (first: Double, last: Double, anyInside: Bool)? {
        guard var first = series.first?.t else { return nil }
        var last = first
        var anyInside = false
        for point in series {
            if point.t < first { first = point.t }
            if point.t > last { last = point.t }
            if point.t >= from, point.t <= to { anyInside = true }
        }
        return (first, last, anyInside)
    }

    /// The footage's part of the window, when the scope is the footage and the window is wider.
    private static func scoped(samples: [HRPoint], window: HRClipWindow,
                               scope: HRMetricsScope) -> (samples: [HRPoint], span: Double)? {
        guard scope == .clip, window.isExtended else { return nil }
        let inside = HRWindowSlicer.slice(samples, start: window.leadSec, span: window.footageSec)
        return (inside, inside.last?.t ?? window.footageSec)
    }
}
