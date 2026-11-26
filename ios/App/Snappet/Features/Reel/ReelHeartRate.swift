import Foundation
import HighlightEngine

/// The heart rate a reel's scorebug shows (prompt 309). Pure.
///
/// A reel is a row of clip segments. Each segment's heart rate comes from `ClipHeartRate`, the
/// resolver every other surface uses, with the footage-only options: the segment's stretch of its
/// video, read at the moments its frames were filmed, from the heart rate of the SESSION THE CLIP
/// BELONGS TO and no other. So the number over a clip in a reel is the number the feed shows over
/// the same frame of that clip.
///
/// The segments' readings are laid end to end in reel time, in **runs**: a run is a stretch of
/// neighbouring segments of one session that all have heart rate. A segment with none (its
/// session wore no band, or the clip was filmed far from the recording) belongs to no run, and
/// the scorebug is not shown while it plays: no number is made up for it, and no line is drawn
/// across it.
///
/// (Before prompt 309 the scorebug was the whole session's series stretched over the reel: the
/// reading over a clip had nothing to do with when the clip was filmed.)
///
/// What the reel maker still cannot say exactly is listed in
/// `pdd/prompts/features/studio-review/309-ios-one-heart-rate-resolver.md`.
enum ReelHeartRate {

    // MARK: What a reel is made from

    /// One session's heart rate, and where that session sits on the timeline the reel's media
    /// offsets are in. A session reel has one, at 0. A weekly, month, picked-clips or festival
    /// reel has one per session, each at the second its session starts on the stitched timeline
    /// (`WeeklyHighlights.stitchedWorkout`).
    struct Session: Sendable, Equatable {
        /// The media-timeline second this session's own second 0 is at.
        var originSec: Double = 0
        /// The session's heart rate, in the session's own seconds.
        var series: [HRPoint]
        var maxHR: Double?
        var restHR: Double?
        /// The media items that belong to this session. `nil` = every item (a one-session reel).
        var mediaIDs: Set<String>? = nil
    }

    /// Everything the scorebug needs next to the plan.
    struct Input: Sendable, Equatable {
        var media: [MediaItem]
        var sessions: [Session]
        /// The baked clips' time maps, keyed by media id (the Photos identifier).
        var timeMaps: [String: BakedTimeMap] = [:]

        /// A reel of one session: its workout as the planner got it.
        static func oneSession(_ workout: Workout, timeMaps: [String: BakedTimeMap] = [:]) -> Input {
            Input(media: workout.media,
                  sessions: [Session(series: workout.hr.map { HRPoint(t: $0.t, bpm: $0.bpm) },
                                     maxHR: workout.maxBpm, restHR: workout.restBpm)],
                  timeMaps: timeMaps)
        }

        func sessionIndex(ofMedia id: String) -> Int? {
            sessions.firstIndex { $0.mediaIDs?.contains(id) ?? true }
        }
    }

    /// One segment's place in the reel: which stretch of which item plays from `start` for
    /// `duration` seconds of the reel.
    struct Slot: Sendable, Equatable {
        var mediaItemId: String
        var isPhoto: Bool
        var startWithinMedia: Double
        var endWithinMedia: Double
        var start: Double
        var duration: Double
    }

    /// The plan's segments on the reel's timeline as PLANNED (`ReelTimelineMap`): the preview.
    static func slots(plan: ReelPlan) -> [Slot] {
        let segments = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ReelTimelineMap(plan: plan).entries.compactMap { entry in
            segments[entry.segmentID].map { slot($0, start: entry.start, duration: entry.duration) }
        }
    }

    /// The plan's segments where the exporter actually PUT them (`ReelExporter.PlacedComposition`).
    /// A segment whose asset failed to load is skipped by the exporter and everything after it
    /// moves up, so the burned scorebug is timed from the placements, as the captions are, not
    /// from the plan. Placements are in plan order; each is matched to the next plan segment of
    /// the same media item.
    static func slots(plan: ReelPlan, placements: [ActivityProgressReel.Placement]) -> [Slot] {
        var remaining = plan.segments[...]
        var out: [Slot] = []
        for placement in placements {
            guard let index = remaining.firstIndex(where: { $0.mediaItemId == placement.mediaItemId })
            else { continue }
            out.append(slot(remaining[index], start: placement.startSec, duration: placement.durationSec))
            remaining = remaining[(index + 1)...]
        }
        return out
    }

    private static func slot(_ segment: ReelPlan.Segment, start: Double, duration: Double) -> Slot {
        Slot(mediaItemId: segment.mediaItemId, isPhoto: segment.kind == .photo,
             startWithinMedia: segment.startWithinMedia, endWithinMedia: segment.endWithinMedia,
             start: start, duration: duration)
    }

    // MARK: The reel's heart rate

    /// A stretch of the reel with heart rate: neighbouring segments of one session.
    struct Run: Sendable {
        /// Where the run is in the reel (seconds).
        var start: Double
        var end: Double
        /// The readings, `t` from 0 at `start`: each segment's footage samples, end to end.
        var samples: [HRPoint]
        /// The text, colours and chart the scorebug is drawn from while this run plays. The live
        /// number and the line are this run's. AVG and PEAK are over every reading in the reel
        /// that comes from this run's session, so they do not change from one clip of a session
        /// to the next. Zones are against this session's own maximum.
        var values: HROverlayValues
        var restHR: Double?

        var duration: Double { end - start }
    }

    /// A reel's heart rate in reel time.
    struct Track: Sendable {
        var runs: [Run]
        var totalDuration: Double

        var hasData: Bool { !runs.isEmpty }

        static let none = Track(runs: [], totalDuration: 0)

        /// The run playing at `time` seconds into the reel, and how far through it the playhead
        /// is (0…1). `nil` while a segment without heart rate plays: the scorebug is hidden.
        func run(at time: Double) -> (run: Run, fraction: Double)? {
            for run in runs {
                // The reel's very last instant belongs to the run that ends the reel.
                let endsTheReel = run.end >= totalDuration - 0.001
                guard time >= run.start, time < run.end || (endsTheReel && time <= run.end + 0.001) else { continue }
                return (run, run.duration > 0 ? min(1, max(0, (time - run.start) / run.duration)) : 0)
            }
            return nil
        }
    }

    /// When each frame of a reel's media item was filmed, in its own session's seconds. The reel
    /// planner knows an item by the moment its first frame was filmed (`MediaItem.startOffset`,
    /// on the reel's media timeline) and its length; a baked clip's time map
    /// (`SessionMedia.bakeTimeMap`) says how the rest of its frames map back.
    static func clock(for media: MediaItem, timeMap: BakedTimeMap?, originSec: Double = 0) -> ClipCaptureClock {
        let firstFrame = media.startOffset - originSec
        guard let timeMap else { return ClipCaptureClock(offsetSec: firstFrame) }
        return ClipCaptureClock(offsetSec: firstFrame - timeMap.sourceTime(renditionTime: 0),
                                timeMap: timeMap)
    }

    /// The preview's heart rate: the plan as planned.
    static func track(plan: ReelPlan, input: Input) -> Track {
        let slots = slots(plan: plan)
        return track(slots: slots, totalDuration: slots.last.map { $0.start + $0.duration } ?? 0, input: input)
    }

    /// The reel's heart rate over `slots`.
    static func track(slots: [Slot], totalDuration: Double, input: Input) -> Track {
        let items = Dictionary(input.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Each slot's readings, from its own session, in reel time. `nil` = no heart rate.
        var pieces: [Piece] = []
        for slot in slots {
            guard let item = items[slot.mediaItemId],
                  let sessionIndex = input.sessionIndex(ofMedia: item.id),
                  let piece = piece(slot: slot, item: item, sessionIndex: sessionIndex,
                                    session: input.sessions[sessionIndex],
                                    timeMap: input.timeMaps[item.id]) else { continue }
            pieces.append(piece)
        }

        // 2. Every reading of one session in the reel: what its AVG and PEAK are over.
        var counted: [Int: [HRPoint]] = [:]
        for piece in pieces { append(piece.samples, to: &counted[piece.sessionIndex, default: []]) }

        // 3. Neighbouring pieces of one session make a run.
        var runs: [Run] = []
        var open: (pieces: [Piece], sessionIndex: Int)?
        func close() {
            guard let group = open, let first = group.pieces.first, let last = group.pieces.last else { return }
            let session = input.sessions[group.sessionIndex]
            var samples: [HRPoint] = [], chart: [HRPoint] = []
            for piece in group.pieces {
                append(piece.samples.map { HRPoint(t: $0.t - first.start, bpm: $0.bpm) }, to: &samples)
                append(piece.chart.map { HRPoint(t: $0.t - first.start, bpm: $0.bpm) }, to: &chart)
            }
            let duration = last.end - first.start
            anchor(&samples, to: duration)
            anchor(&chart, to: duration)
            guard samples.count >= 2 else { return }
            runs.append(Run(start: first.start, end: last.end, samples: samples,
                            values: HROverlayValues(samples: samples, durationSec: duration,
                                                    maxHR: session.maxHR, restHR: session.restHR,
                                                    chartSamples: chart,
                                                    countedSamples: counted[group.sessionIndex]),
                            restHR: session.restHR))
        }
        for piece in pieces {
            if let group = open, group.sessionIndex == piece.sessionIndex,
               let last = group.pieces.last, abs(last.end - piece.start) < 0.01 {
                open?.pieces.append(piece)
            } else {
                close()
                open = ([piece], piece.sessionIndex)
            }
        }
        close()
        return Track(runs: runs, totalDuration: totalDuration)
    }

    // MARK: - Private

    private struct Piece {
        var start: Double
        var end: Double
        var sessionIndex: Int
        /// Reel-time readings, and the series the line and the live number are read from.
        var samples: [HRPoint]
        var chart: [HRPoint]
    }

    private static func piece(slot: Slot, item: MediaItem, sessionIndex: Int, session: Session,
                              timeMap: BakedTimeMap?) -> Piece? {
        guard slot.duration > 0 else { return nil }
        let from = slot.isPhoto ? 0 : slot.startWithinMedia
        let to = slot.isPhoto ? 0 : slot.endWithinMedia
        let result = ClipHeartRate.resolve(series: session.series,
                                           clock: clock(for: item, timeMap: timeMap, originSec: session.originSec),
                                           renditionStart: from, renditionEnd: to, options: .footageOnly)
        guard let hr = result.data else { return nil }
        let end = slot.start + slot.duration
        if slot.isPhoto || to <= from {
            // A photo is one moment: its reading, held for as long as the photo is shown.
            let bpm = hr.samples.first?.bpm ?? 0
            let held = [HRPoint(t: slot.start, bpm: bpm), HRPoint(t: end, bpm: bpm)]
            return Piece(start: slot.start, end: end, sessionIndex: sessionIndex, samples: held, chart: held)
        }
        // Seconds of the video → seconds of the reel (the slot is this stretch of the video).
        let scale = slot.duration / (to - from)
        func placed(_ points: [HRPoint]) -> [HRPoint] {
            points.map { HRPoint(t: slot.start + ($0.t - from) * scale, bpm: $0.bpm) }
        }
        return Piece(start: slot.start, end: end, sessionIndex: sessionIndex,
                     samples: placed(hr.renditionSamples), chart: placed(hr.renditionChartSamples))
    }

    /// Two readings never share a time: the first reading of a segment sits just after the last
    /// reading of the segment before it.
    private static let cutGapSec = 0.001

    private static func append(_ points: [HRPoint], to out: inout [HRPoint]) {
        for point in points {
            if let last = out.last, point.t <= last.t {
                out.append(HRPoint(t: last.t + cutGapSec, bpm: point.bpm))
            } else {
                out.append(point)
            }
        }
    }

    /// A run's series covers the run exactly, so a time in the run is the same fraction of its
    /// chart.
    private static func anchor(_ points: inout [HRPoint], to duration: Double) {
        guard let first = points.first, let last = points.last else { return }
        if first.t > cutGapSec { points.insert(HRPoint(t: 0, bpm: first.bpm), at: 0) }
        if last.t < duration - cutGapSec { points.append(HRPoint(t: duration, bpm: last.bpm)) }
    }
}
