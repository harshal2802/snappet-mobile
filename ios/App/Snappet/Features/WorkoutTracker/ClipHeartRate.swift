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

    /// The session-time window the samples cover as asked for (the recorded data may end sooner).
    var captureWindow: (start: Double, span: Double) { (captureStartSec, window.spanSec) }

    /// Where the video's progress (0…1 of the footage) is on the chart (0…1 of its width).
    func chartFraction(videoFraction f: Double) -> Double { values.chartFraction(forVideoFraction: f) }

    /// The bpm shown when the video is at `f` (0…1 of the footage).
    func bpm(atVideoFraction f: Double) -> Double? {
        values.bpm(atFraction: chartFraction(videoFraction: f))
    }

    /// The bpm shown at `t` seconds into the video the asset plays now.
    func bpm(atRenditionTime t: Double) -> Double? {
        bpm(atVideoFraction: videoFraction(atRenditionTime: t))
    }

    /// The zone (and so the colour) of the reading at `f`, against the options' maximum.
    func zone(atVideoFraction f: Double) -> HeartRateZone {
        bpm(atVideoFraction: f).map { HeartRateZone.forBpm($0, maxHR: values.resolvedMaxHR) } ?? .none
    }

    /// The highest reading over the options' scope, before rounding.
    var peakBpm: Double? { values.rawPeakBpm }
    /// The plain mean of the readings over the options' scope, before rounding.
    var averageBpm: Double? { values.rawAverageBpm }
    /// The peak and the average as every surface prints them.
    var summary: ClipHRSummary? {
        guard let peak = values.rawPeakBpm, let average = values.rawAverageBpm else { return nil }
        return ClipHRSummary(peakBpm: peak, averageBpm: average)
    }

    func videoFraction(atRenditionTime t: Double) -> Double {
        let span = renditionEndSec - renditionStartSec
        return span > 0 ? min(1, max(0, (t - renditionStartSec) / span)) : 0
    }

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

    /// Whole beats, rounded the one way every surface rounds.
    var peak: Int { ClipHeartRate.rounded(peakBpm) }
    var average: Int { ClipHeartRate.rounded(averageBpm) }

    /// The zone of the peak against `maxHR`.
    func peakZone(maxHR: Double?) -> HeartRateZone {
        HeartRateZone.forBpm(peakBpm, maxHR: maxHR ?? HeartRateZone.defaultMaxHR)
    }
}

/// Why a clip has no heart rate to show.
struct ClipHRGap: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The session recorded no heart rate.
        case noSeries
        /// The window is further than the clamp tolerance from every recorded sample.
        case farFromAnySample
    }
    var reason: Reason
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
///   each edge, read off the straight line between the two samples around it. A window outside
///   the recording but within `clampTolerance` of it holds the nearest sample flat; further away
///   there is no data.
/// - **The reading at a moment**: straight-line interpolation in the window's display series
///   (`HRChartGeometry.displaySeries`: a 0.5 s grid, smoothed over 2 s). Never "hold the last
///   sample".
/// - **Peak and average**: the highest reading and the plain mean of the readings in the scope
///   (the whole window, or the footage for `.clip`), from `WorkoutHRStats`.
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
            return .noData(ClipHRGap(reason: series.isEmpty ? .noSeries : .farFromAnySample,
                                     captureStartSec: slice.start, window: slice.window))
        }
        return .data(ClipHR(captureStartSec: slice.start, window: slice.window, samples: slice.samples,
                            renditionStartSec: renditionStart,
                            renditionEndSec: max(renditionStart, renditionEnd),
                            values: values(samples: slice.samples, window: slice.window, options: options)))
    }

    /// The peak and the average `resolve` gives, without building the chart. `nil` = no data.
    static func summary(series: [HRPoint], clock: ClipCaptureClock,
                        renditionStart: Double, renditionEnd: Double,
                        options: ClipHROptions) -> ClipHRSummary? {
        let slice = slice(series: series, clock: clock, renditionStart: renditionStart,
                          renditionEnd: renditionEnd, options: options)
        let scoped = scoped(samples: slice.samples, window: slice.window, scope: options.scope)
        guard let stats = WorkoutHRStats.make(from: scoped?.samples ?? slice.samples) else { return nil }
        return ClipHRSummary(peakBpm: stats.maxBpm, averageBpm: stats.avgBpm)
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
        let span = samples.last?.t ?? 0
        let scoped = window.flatMap { Self.scoped(samples: samples, window: $0, scope: options.scope) }
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
                               statsSamples: scoped?.samples, statsDurationSec: scoped?.span)
    }

    /// A reading as a whole number of beats.
    static func rounded(_ bpm: Double) -> Int { Int(bpm.rounded()) }

    // MARK: - Private

    private static func slice(series: [HRPoint], clock: ClipCaptureClock,
                              renditionStart: Double, renditionEnd: Double,
                              options: ClipHROptions) -> (start: Double, window: HRClipWindow, samples: [HRPoint]) {
        let ext = window(clock: clock, renditionStart: renditionStart, renditionEnd: renditionEnd,
                         leadSec: options.leadSec, tailSec: options.tailSec)
        let samples = HRWindowSlicer.slice(series, start: ext.start, span: ext.window.spanSec,
                                           clampTolerance: options.clampTolerance)
        return (ext.start, ext.window, samples)
    }

    /// The footage's part of the window, when the scope is the footage and the window is wider.
    private static func scoped(samples: [HRPoint], window: HRClipWindow,
                               scope: HRMetricsScope) -> (samples: [HRPoint], span: Double)? {
        guard scope == .clip, window.isExtended else { return nil }
        let inside = HRWindowSlicer.slice(samples, start: window.leadSec, span: window.footageSec)
        return (inside, inside.last?.t ?? window.footageSec)
    }
}
