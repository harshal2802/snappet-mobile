import Foundation

/// How the time of a BAKED video maps back to the original recording (prompt 305).
///
/// A Studio bake renders a trimmed, sped or joined video into the Photos asset. The video the
/// asset plays afterwards (the **rendition**) no longer runs second for second with the recording
/// that `SessionMedia.offsetSec` describes. This value records the difference, so heart rate can
/// still be read at the moment each frame was filmed.
///
/// **Source time** is seconds into the recording whose first frame was filmed at
/// `SessionMedia.offsetSec`. `nil` on a row means "the rendition is that recording": source time
/// equals rendition time. That is every clip that was never baked, a clip whose bake was reverted
/// in Photos, a bake that changed no timing, and every clip baked before this field existed.
///
/// Foundation only; stored on `SessionMedia` as JSON (`bakeTimeMapData`) and carried in the
/// backup as a nested value.
struct BakedTimeMap: Codable, Sendable, Hashable {

    /// One stretch of the rendition that plays one stretch of the recording at one speed. It runs
    /// from `renditionStartSec` to the next segment's start (the last one to
    /// `renditionDurationSec`).
    struct Segment: Codable, Sendable, Hashable {
        /// Where the stretch starts in the rendition.
        var renditionStartSec: Double
        /// The source time of its first frame.
        var sourceStartSec: Double
        /// Source seconds per rendition second (2 = baked at 2×, 0.5 = baked in slow motion).
        var speed: Double
    }

    /// Ordered by `renditionStartSec`; never empty; the first starts at 0.
    var segments: [Segment]
    /// Where the last segment ends: the planned length of the rendition.
    var renditionDurationSec: Double
    /// `true` for "Save to original": Photos keeps the original, and a "Revert to Original" makes
    /// this map wrong, so it is dropped when the revert is found. `false` for "Replace original":
    /// the asset is a new video with nothing to revert to, and the map stays for the row's life.
    var isRevertible: Bool

    init(segments: [Segment], renditionDurationSec: Double, isRevertible: Bool = true) {
        self.segments = segments
        self.renditionDurationSec = renditionDurationSec
        self.isRevertible = isRevertible
    }

    /// Two times closer than this are the same time (float noise from the timeline math).
    static let tolerance = 1e-6

    // MARK: Rendition time → source time

    /// The index of the segment that plays rendition time `t`. A segment owns its start and not
    /// its end, so a boundary belongs to the segment that begins there. A time before 0 reads the
    /// first segment and a time past the end reads the last (both extended in a straight line).
    func segmentIndex(at t: Double) -> Int {
        segments.lastIndex { $0.renditionStartSec <= t + Self.tolerance } ?? 0
    }

    /// The source time filmed at rendition time `t`.
    func sourceTime(renditionTime t: Double) -> Double {
        guard !segments.isEmpty else { return t }
        let s = segments[segmentIndex(at: t)]
        return s.sourceStartSec + (t - s.renditionStartSec) * s.speed
    }

    /// The end of segment `i` in the rendition.
    func renditionEnd(ofSegment i: Int) -> Double {
        i + 1 < segments.count ? segments[i + 1].renditionStartSec
                               : max(renditionDurationSec, segments[i].renditionStartSec)
    }

    /// The stretches of source time the rendition range `[from, to]` plays, in rendition order.
    /// A range that reaches past the planned end extends the last segment.
    func sourcePieces(from: Double, to: Double) -> [(renditionStart: Double, sourceStart: Double,
                                                      sourceEnd: Double, speed: Double)] {
        guard to - from > Self.tolerance else { return [] }
        var out: [(renditionStart: Double, sourceStart: Double, sourceEnd: Double, speed: Double)] = []
        for (i, s) in segments.enumerated() {
            let isLast = i + 1 == segments.count
            let lo = max(from, i == 0 ? -.infinity : s.renditionStartSec)
            let hi = min(to, isLast ? .infinity : renditionEnd(ofSegment: i))
            guard hi - lo > Self.tolerance else { continue }
            let start = s.sourceStartSec + (lo - s.renditionStartSec) * s.speed
            out.append((lo, start, start + (hi - lo) * s.speed, s.speed))
        }
        return out
    }

    /// The source-time window that holds everything the rendition range `[from, to]` plays: from
    /// the earliest frame in it to the latest. Two joined parts with footage left out between
    /// them give ONE window that includes the left-out seconds (a heart-rate chart is one stretch
    /// of the session, and the effort between two kept parts belongs in it).
    func sourceWindow(from: Double, to: Double) -> (start: Double, end: Double) {
        let pieces = sourcePieces(from: from, to: to)
        guard let lo = pieces.map(\.sourceStart).min(), let hi = pieces.map(\.sourceEnd).max() else {
            let at = sourceTime(renditionTime: from)
            return (at, at)
        }
        return (lo, hi)
    }

    // MARK: Shape

    /// The earliest source time any segment starts at.
    var earliestSourceSec: Double { segments.map(\.sourceStartSec).min() ?? 0 }

    /// One segment from 0 at speed 1: the rendition starts `earliestSourceSec` into the recording
    /// and otherwise runs with it. A plain start trim.
    var isPlainShift: Bool {
        segments.count == 1
            && abs(segments[0].renditionStartSec) <= Self.tolerance
            && abs(segments[0].speed - 1) <= Self.tolerance
    }

    /// The rendition is the recording: nothing to store.
    var isIdentity: Bool { isPlainShift && abs(segments[0].sourceStartSec) <= Self.tolerance }

    /// The same map measured from a recording that starts `seconds` later (every source time
    /// moves earlier by `seconds`). Used when a bake moves `offsetSec` forward by that much.
    func movingSource(earlierBy seconds: Double) -> BakedTimeMap {
        var out = self
        for i in out.segments.indices { out.segments[i].sourceStartSec -= seconds }
        return out
    }

    /// Neighbouring segments that run on without a jump (same speed, the source time continues)
    /// joined into one. A split with nothing removed is then one segment again.
    func joiningContinuousSegments() -> BakedTimeMap {
        var out: [Segment] = []
        for s in segments {
            if let last = out.last {
                let expected = last.sourceStartSec + (s.renditionStartSec - last.renditionStartSec) * last.speed
                if abs(last.speed - s.speed) <= Self.tolerance, abs(expected - s.sourceStartSec) <= 1e-4 {
                    continue
                }
            }
            out.append(s)
        }
        return BakedTimeMap(segments: out, renditionDurationSec: renditionDurationSec,
                            isRevertible: isRevertible)
    }

    // MARK: Storage

    /// The stored form (`SessionMedia.bakeTimeMapData`). An unreadable value is `nil`: the clip
    /// then behaves as one that has no map.
    static func decode(_ data: Data?) -> BakedTimeMap? {
        guard let data, let map = try? JSONDecoder().decode(BakedTimeMap.self, from: data),
              !map.segments.isEmpty else { return nil }
        return map
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }
}

/// **The one rule for when a frame of a clip was filmed** (prompt 305). Every surface that reads
/// heart rate for a clip goes through it: the Studio's preview tile, the HR-window sliders, the
/// export (`StudioHRPlacement` → `StudioComposer.placedHR`), the feed overlay and "Share with
/// heart rate" (`ClipHROverlay`), the poster's peak / average chip (`FeedMedia.clipHR`), the
/// activity pages' average (`ActivityMediaIndex.averageBPM`) and the reel maker's clip start
/// (`captureStartSec`).
///
/// How the two stored values combine, and the only place they are combined:
///
///     capture time = offsetSec + (timeMap?.sourceTime(renditionTime) ?? renditionTime)
///
/// - `offsetSec` is when source time 0 was filmed, in seconds from the session's start.
/// - `timeMap` turns a time in the video the asset plays now into source time. `nil` = they are
///   the same.
///
/// A bake changes exactly one of them for a given shift, never both:
/// - "Save to original" never moves `offsetSec` (Photos can bring the original back). All of the
///   bake's timing goes in the map.
/// - "Replace original" moves `offsetSec` forward to the earliest footage that was kept, and
///   stores a map only for what a moved offset cannot say (a speed change, joined parts), with
///   that same shift taken out of the map (`ClipBakePlan.replacedMediaUpdate`).
struct ClipCaptureClock: Sendable, Equatable {
    var offsetSec: Double
    var timeMap: BakedTimeMap?

    init(offsetSec: Double, timeMap: BakedTimeMap? = nil) {
        self.offsetSec = offsetSec
        self.timeMap = timeMap
    }

    /// When the frame at `renditionTime` (seconds into the video the asset plays now) was filmed,
    /// in seconds from the session's start.
    func captureTime(renditionTime t: Double) -> Double {
        offsetSec + (timeMap?.sourceTime(renditionTime: t) ?? t)
    }

    /// The session-time window filmed by the rendition range `[renditionStart, renditionEnd]`:
    /// what a heart-rate resolver slices. Without a map it is the range moved by `offsetSec`.
    /// With one it is `BakedTimeMap.sourceWindow` moved by `offsetSec`, so a baked 2× clip of 4 s
    /// reads 8 s of heart rate, and two joined parts read from the first kept frame to the last.
    func captureWindow(renditionStart: Double, renditionEnd: Double) -> (start: Double, span: Double) {
        let end = max(renditionStart, renditionEnd)
        guard let timeMap else { return (offsetSec + renditionStart, end - renditionStart) }
        let w = timeMap.sourceWindow(from: renditionStart, to: end)
        return (offsetSec + w.start, w.end - w.start)
    }

    /// When the first frame of the video the asset plays now was filmed. The reel maker's clip
    /// start (its planner knows a start and a length only).
    var captureStartSec: Double { captureTime(renditionTime: 0) }
}
