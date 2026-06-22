import Foundation

// MARK: - Recap Feed — session-media grouping + per-clip HR (F3b, pure)
//
// Groups a session's media by exercise / climb / session and computes each clip's HR overlay window
// (peak/avg BPM aligned via SessionMedia.offsetSec to the HR series). Pure + testable — the actual
// PHAsset thumbnail/video load and the inline AVPlayer/clip export are the device-only edge (F3/F4).

struct MediaInput: Sendable, Equatable, Identifiable {
    var id: UUID
    var kind: String                 // "photo" | "video"
    var offsetSec: Double
    var durationSec: Double?
    var exerciseId: UUID?
    var setIndex: Int?
    var climbUUID: String?
    var localIdentifier: String
}

struct MediaClipHR: Sendable, Equatable {
    var peakBpm: Int?
    var avgBpm: Int?
    var zoneRaw: Int?                 // HeartRateZone.rawValue at peak
}

enum FeedMedia {

    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case byExercise = "By exercise", bySession = "By session", all = "All"
        var id: String { rawValue }
    }

    struct Group: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        var items: [MediaInput]
    }

    /// Canonical clip ordering — by `offsetSec`, ties broken by id for stability. Shared by the in-card
    /// carousel, the browser's flat index space, and the fullscreen pager so all three agree on order.
    static func ordered(_ media: [MediaInput]) -> [MediaInput] {
        media.sorted { $0.offsetSec == $1.offsetSec ? $0.id.uuidString < $1.id.uuidString : $0.offsetSec < $1.offsetSec }
    }

    /// The group key for a clip: its exercise, else its climb, else "general". One source of truth for
    /// both `groups(by:)` bucketing and the per-clip name tag.
    static func groupKey(_ m: MediaInput) -> String {
        m.exerciseId?.uuidString ?? m.climbUUID ?? "general"
    }

    /// The display name tag for a clip — `nameFor` applied to its `groupKey`.
    static func tagName(_ m: MediaInput, nameFor: (String) -> String) -> String {
        nameFor(groupKey(m))
    }

    /// Peak/avg BPM within a clip's [offset, offset+duration] window from the session HR series.
    static func clipHR(offsetSec: Double, durationSec: Double?, hrSeries: [HRPoint], maxHR: Double) -> MediaClipHR {
        guard !hrSeries.isEmpty else { return MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil) }
        let end = offsetSec + (durationSec ?? 6)
        let inWindow = hrSeries.filter { $0.t >= offsetSec && $0.t <= end }
        // Fall back to the nearest samples if the exact window is empty (sparse series).
        let window = inWindow.isEmpty ? hrSeries.filter { abs($0.t - offsetSec) <= 8 } : inWindow
        let bpms = window.map(\.bpm)
        guard !bpms.isEmpty else { return MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil) }
        let peak = bpms.max() ?? 0
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        return MediaClipHR(peakBpm: Int(peak.rounded()), avgBpm: Int(avg.rounded()),
                           zoneRaw: HeartRateZone.forBpm(peak, maxHR: maxHR).rawValue)
    }

    /// The session HR samples that fall inside a clip's `[offsetSec, offsetSec + durationSec]` window,
    /// **rebased to clip-local time** (`t - offsetSec`, clamped at 0). This is the pure input the
    /// fullscreen viewer feeds to the editor's `HROverlayValues` (single HR source of truth) — so the
    /// per-clip overlay slices the SAME series the export burn-in (R4) reads, and preview == burn.
    ///
    /// - A photo (`durationSec == nil`) gets a small default window so a still poster still resolves an
    ///   overlay if HR exists at that moment; a zero-duration clip collapses to the samples AT `offsetSec`.
    /// - When the exact window holds no samples (sparse series), falls back to the nearest samples within
    ///   ±8s of `offsetSec` — the SAME tolerance the poster chip's `clipHR` uses — so the carousel poster
    ///   and the fullscreen overlay agree (both show HR, or both show name-tag-only). The fallback
    ///   samples are still rebased to clip-local time (`t - offsetSec`, clamped at 0).
    /// - Returns `[]` only when even that ±8s neighbourhood is empty (window entirely before/after the
    ///   series, no fabricated samples) — the caller then degrades to the name tag only, never an empty chart.
    static func clipHRWindow(offsetSec: Double, durationSec: Double?, hrSeries: [HRPoint]) -> [HRPoint] {
        guard !hrSeries.isEmpty else { return [] }
        let dur = durationSec ?? Self.photoWindowSec
        let end = offsetSec + max(0, dur)
        let inWindow = hrSeries.filter { $0.t >= offsetSec && $0.t <= end }
        // Mirror `clipHR`'s nearest-sample fallback (±8s) so poster chip and viewer overlay agree.
        let window = inWindow.isEmpty ? hrSeries.filter { abs($0.t - offsetSec) <= 8 } : inWindow
        return window
            .map { HRPoint(t: max(0, $0.t - offsetSec), bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
    }

    /// The default window (seconds) used for a photo / nil-duration clip when slicing HR.
    static let photoWindowSec: Double = 6

    /// Re-bucket the same clips by the chosen grouping. `nameFor` resolves a group key to a label.
    static func groups(_ media: [MediaInput], by grouping: Grouping, nameFor: (String) -> String) -> [Group] {
        let sorted = media.sorted { $0.offsetSec < $1.offsetSec }
        switch grouping {
        case .all:
            return sorted.isEmpty ? [] : [Group(id: "all", title: "All clips", items: sorted)]
        case .bySession:
            return sorted.isEmpty ? [] : [Group(id: "session", title: "This session", items: sorted)]
        case .byExercise:
            var order: [String] = []
            var map: [String: [MediaInput]] = [:]
            for m in sorted {
                let key = groupKey(m)
                if map[key] == nil { order.append(key) }
                map[key, default: []].append(m)
            }
            return order.map { Group(id: $0, title: nameFor($0), items: map[$0] ?? []) }
        }
    }
}
