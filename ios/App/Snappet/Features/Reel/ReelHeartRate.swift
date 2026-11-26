import Foundation
import HighlightEngine

/// The heart rate a reel's scorebug shows (prompt 309). Pure.
///
/// A reel is a row of clip segments. Each segment's heart rate comes from `ClipHeartRate`, the
/// resolver every other surface uses, with the footage-only options: the segment's stretch of its
/// video, read at the moments its frames were filmed. The segments' readings are laid end to end
/// in reel time. So the number over a clip in a reel is the number the feed shows over the same
/// frame of that clip.
///
/// (Before prompt 309 the scorebug was the whole session's series stretched over the reel: the
/// reading over a clip had nothing to do with when the clip was filmed.)
///
/// What the reel maker still cannot say exactly is listed in
/// `pdd/prompts/features/studio-review/309-ios-one-heart-rate-resolver.md`.
enum ReelHeartRate {

    /// A reel's heart rate in reel time (`t` = seconds into the reel).
    struct Track: Sendable, Equatable {
        /// The readings: each segment's footage samples, end to end. Peak and average are taken
        /// over these.
        var samples: [HRPoint]
        /// The series the live number and the preview's line are read from: each segment's own
        /// display series, end to end (not smoothed again across a cut).
        var chart: [HRPoint]
        var totalDuration: Double
        /// The segments that had no heart rate (the line runs straight across them).
        var segmentsWithoutData: [String]

        /// A scorebug needs two readings to draw.
        var hasData: Bool { samples.count >= 2 }

        static let empty = Track(samples: [], chart: [], totalDuration: 0, segmentsWithoutData: [])
    }

    /// When each frame of a reel's media item was filmed. The reel planner knows an item by the
    /// moment its first frame was filmed (`MediaItem.startOffset`) and its length; a baked clip's
    /// time map (`SessionMedia.bakeTimeMap`) says how the rest of its frames map back.
    static func clock(for media: MediaItem, timeMap: BakedTimeMap?) -> ClipCaptureClock {
        guard let timeMap else { return ClipCaptureClock(offsetSec: media.startOffset) }
        return ClipCaptureClock(offsetSec: media.startOffset - timeMap.sourceTime(renditionTime: 0),
                                timeMap: timeMap)
    }

    /// The reel's heart rate. `series` is on the same timeline as `media` (one session's seconds,
    /// or the weekly reel's stitched week). `timeMaps` is keyed by media id (the Photos
    /// identifier) and holds the baked clips' maps.
    static func track(plan: ReelPlan, media: [MediaItem], series: [HRPoint],
                      timeMaps: [String: BakedTimeMap] = [:]) -> Track {
        let timeline = ReelTimelineMap(plan: plan)
        let segments = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var track = Track(samples: [], chart: [], totalDuration: timeline.totalDuration, segmentsWithoutData: [])

        for entry in timeline.entries {
            guard let segment = segments[entry.segmentID], let item = items[segment.mediaItemId] else {
                track.segmentsWithoutData.append(entry.segmentID)
                continue
            }
            let isPhoto = segment.kind == .photo
            let from = isPhoto ? 0 : segment.startWithinMedia
            let to = isPhoto ? 0 : segment.endWithinMedia
            let result = ClipHeartRate.resolve(series: series,
                                               clock: clock(for: item, timeMap: timeMaps[item.id]),
                                               renditionStart: from, renditionEnd: to,
                                               options: .footageOnly)
            guard let hr = result.data else {
                track.segmentsWithoutData.append(entry.segmentID)
                continue
            }
            if isPhoto {
                // A photo is one moment: its reading, held for as long as the photo is shown.
                let bpm = hr.samples.first?.bpm ?? 0
                let held = [HRPoint(t: entry.start, bpm: bpm), HRPoint(t: entry.start + entry.duration, bpm: bpm)]
                append(held, to: &track.samples)
                append(held, to: &track.chart)
            } else {
                let shift = entry.start - from
                append(hr.renditionSamples.map { HRPoint(t: $0.t + shift, bpm: $0.bpm) }, to: &track.samples)
                append(hr.renditionChartSamples.map { HRPoint(t: $0.t + shift, bpm: $0.bpm) }, to: &track.chart)
            }
        }
        anchor(&track.samples, to: track.totalDuration)
        anchor(&track.chart, to: track.totalDuration)
        return track
    }

    /// The values the reel's scorebug is drawn from, in the preview and in the export.
    static func values(track: Track, durationSec: Double, maxHR: Double?, restHR: Double?) -> HROverlayValues {
        HROverlayValues(samples: track.samples, durationSec: durationSec, maxHR: maxHR, restHR: restHR,
                        chartSamples: track.chart)
    }

    // MARK: - Private

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

    /// The series runs over the whole reel, so a time in the reel is the same fraction of the
    /// chart: a segment without heart rate at either end holds the nearest reading.
    private static func anchor(_ points: inout [HRPoint], to totalDuration: Double) {
        guard let first = points.first, let last = points.last else { return }
        if first.t > cutGapSec { points.insert(HRPoint(t: 0, bpm: first.bpm), at: 0) }
        if last.t < totalDuration - cutGapSec { points.append(HRPoint(t: totalDuration, bpm: last.bpm)) }
    }
}
