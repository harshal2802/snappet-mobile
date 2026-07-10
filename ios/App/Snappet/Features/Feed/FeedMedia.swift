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
    /// Oriented display aspect (width / height) for the Clips feed's adaptive tile sizing (prompt 92);
    /// `nil` until `SessionMedia.aspectRatio` is backfilled. Defaulted so existing `MediaInput(...)` sites
    /// (and the Recap viewer, which doesn't size by aspect) compile unchanged.
    var aspect: Double? = nil
    /// The clip's Studio edit the feed live-reflects — trim + extended-HR-window config (prompt 116).
    /// `nil` (every non-feed construction site, or a clip with no Studio project) = raw playback with
    /// the default HR window; the feed stamps it from the session's `StudioProject` at compose time.
    var edit: ClipStudioEdit? = nil
    /// The Studio baked its edit INTO this asset's pixels ("Save to original", prompt 117): every
    /// surface plays it raw (the trims/filters/overlays/HR tile are the video), draws NO live HR
    /// overlay, and shows a BAKED chip. Populated by `MediaInput.from` for all construction sites.
    var isBaked: Bool = false
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

    /// Peak/avg/zone BPM for a clip's HR window — computed over the **same** sliced window the overlay
    /// draws (`clipHRWindow` → `HRWindowSlicer`), so the still poster's chip and the inline / fullscreen
    /// overlay can never disagree. `nil` when the window resolves no HR (the name-tag-only path).
    static func clipHR(offsetSec: Double, durationSec: Double?, hrSeries: [HRPoint], maxHR: Double) -> MediaClipHR {
        let bpms = clipHRWindow(offsetSec: offsetSec, durationSec: durationSec, hrSeries: hrSeries).map(\.bpm)
        guard !bpms.isEmpty else { return MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil) }
        let peak = bpms.max() ?? 0
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        return MediaClipHR(peakBpm: Int(peak.rounded()), avgBpm: Int(avg.rounded()),
                           zoneRaw: HeartRateZone.forBpm(peak, maxHR: maxHR).rawValue)
    }

    /// The session HR samples inside a clip's `[offsetSec, offsetSec + durationSec]` window, **rebased to
    /// clip-local time** `[0, span]`, routed through the project's ONE hardened slicer (`HRWindowSlicer`) —
    /// the same slicer the Studio editor and the export burn-in (R4) use, so the feed poster, the inline /
    /// fullscreen overlay, the export, and the *playing video* can't drift. (The prior inline strict
    /// `t >= offset && t <= end` filter + crude ±8s fallback re-introduced the "element vanishes / HR
    /// frozen" bug `HRWindowSlicer` exists to kill — decisions.md prompt-29 / prompt-91.)
    ///
    /// Guarantees inherited from `HRWindowSlicer`: **interpolated endpoints** at the window edges, a
    /// **≥2-point** result whenever any HR exists within the window or its ±90s edge-clamp pad (so the
    /// chart never blanks and the playhead `maxT` reaches the window edge), and an honest **empty** `[]`
    /// only when the window is farther than that pad from all data. A photo (`nil` duration) uses
    /// `photoWindowSec`; a 0-duration clip collapses to a degenerate flat line at its instant.
    static func clipHRWindow(offsetSec: Double, durationSec: Double?, hrSeries: [HRPoint]) -> [HRPoint] {
        HRWindowSlicer.slice(hrSeries, start: offsetSec, span: durationSec ?? Self.photoWindowSec)
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
