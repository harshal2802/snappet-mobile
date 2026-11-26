import Foundation
@testable import Snappet

/// The forms the Studio's heart-rate placement had before prompt 309 (an offset, trims and a map
/// in; a window or samples out), kept for the tests written against them. Each is one call of
/// `ClipHeartRate`, the resolver the Studio now asks directly
/// (`StudioEditorViewModel.clipHeartRate`), so these tests exercise the shipping rule. Test
/// target only: production has no second way in.
struct SampledClipHR: Equatable {
    var samples: [HRPoint]
    var window: HRClipWindow
}

extension StudioHRPlacement {

    static func captureWindow(offset: Double, trimStart: Double, trimEnd: Double?,
                              sourceDuration: Double?,
                              timeMap: BakedTimeMap? = nil) -> (start: Double, span: Double) {
        let range = renditionRange(trimStart: trimStart, trimEnd: trimEnd, sourceDuration: sourceDuration)
        let window = ClipCaptureClock(offsetSec: offset, timeMap: timeMap)
            .captureWindow(renditionStart: range.start, renditionEnd: range.end)
        return (window.start, max(0.001, window.span))
    }

    static func extendedWindow(offset: Double, trimStart: Double, trimEnd: Double?,
                               sourceDuration: Double?, leadSec: Double, tailSec: Double,
                               timeMap: BakedTimeMap? = nil) -> (start: Double, window: HRClipWindow) {
        let range = renditionRange(trimStart: trimStart, trimEnd: trimEnd, sourceDuration: sourceDuration)
        return ClipHeartRate.window(clock: ClipCaptureClock(offsetSec: offset, timeMap: timeMap),
                                    renditionStart: range.start, renditionEnd: range.end,
                                    leadSec: leadSec, tailSec: tailSec)
    }

    static func sample(clips: [TimelineClip], offsets: [UUID: Double],
                       sourceDurations: [UUID: Double], series: [HRPoint],
                       timeMaps: [UUID: BakedTimeMap] = [:],
                       clampTolerance: Double = HRWindowSlicer.defaultClampTolerance) -> [UUID: [HRPoint]] {
        sampleExtended(clips: clips.map { var c = $0; c.hrLeadSec = 0; c.hrTailSec = 0; return c },
                       offsets: offsets, sourceDurations: sourceDurations, series: series,
                       timeMaps: timeMaps, clampTolerance: clampTolerance).mapValues(\.samples)
    }

    static func sampleExtended(clips: [TimelineClip], offsets: [UUID: Double],
                               sourceDurations: [UUID: Double], series: [HRPoint],
                               timeMaps: [UUID: BakedTimeMap] = [:],
                               clampTolerance: Double = HRWindowSlicer.defaultClampTolerance)
        -> [UUID: SampledClipHR] {
        var out: [UUID: SampledClipHR] = [:]
        for clip in clips where !clip.isPhoto {
            guard let offset = offsets[clip.id] else { continue }
            let range = renditionRange(trimStart: clip.trimStart, trimEnd: clip.trimEnd,
                                       sourceDuration: sourceDurations[clip.id])
            var options = ClipHROptions(leadSec: clip.hrWindowLeadSec, tailSec: clip.hrWindowTailSec)
            options.clampTolerance = clampTolerance
            let result = ClipHeartRate.resolve(
                series: series, clock: ClipCaptureClock(offsetSec: offset, timeMap: timeMaps[clip.id]),
                renditionStart: range.start, renditionEnd: range.end, options: options)
            if let hr = result.data { out[clip.id] = SampledClipHR(samples: hr.samples, window: hr.window) }
        }
        return out
    }
}
