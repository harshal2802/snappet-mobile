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
    /// Non-nil = this clip is a POSTED HIGHLIGHT REEL (highlights P2) and the value is its feed
    /// title. The composer gives it its own ✦ REEL post; like `isBaked`, it plays raw (the HR
    /// scorebug is burned into the pixels) so no live overlay is drawn on top.
    var reelTitle: String? = nil
    /// The asset's `SessionMedia.bakeTimeMap` (prompt 305): how a baked video's time maps back to
    /// the recording `offsetSec` describes. `nil` for a clip with no map. Populated by
    /// `MediaInput.from`; read only through `captureClock`.
    var timeMap: BakedTimeMap? = nil

    /// When each frame of this clip was filmed: the one rule every heart-rate reader uses.
    var captureClock: ClipCaptureClock { ClipCaptureClock(offsetSec: offsetSec, timeMap: timeMap) }

    /// A posted highlight reel — `reelTitle` is the marker AND the title (mirrors `SessionMedia`).
    var isReel: Bool { reelTitle != nil }
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

    /// The peak / average chip of a still poster (Recap carousel, media browser): the PEAK and AVG
    /// the clip's overlay shows, from `ClipHeartRate`, the one resolver (prompt 309), asked exactly
    /// as the overlay asks (`ClipHROverlay.summary`): the kept footage, read where its frames were
    /// filmed, over the clip's own HR window. All `nil` when there is no heart rate near the clip
    /// (the name-tag-only path). The zone is the peak's, against `maxHR`.
    ///
    /// Before prompt 309 the chip was worked out here over the footage alone, so it could show
    /// "peak 95" on a poster whose viewer then showed "PEAK 110".
    static func clipHR(for clip: MediaInput, hrSeries: [HRPoint], maxHR: Double) -> MediaClipHR {
        guard let summary = ClipHROverlay.summary(clip: clip, hrSeries: hrSeries) else {
            return MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil)
        }
        return MediaClipHR(peakBpm: summary.peak, avgBpm: summary.average,
                           zoneRaw: summary.peakZone(maxHR: maxHR).rawValue)
    }

    /// The footage length (seconds) assumed for a video whose length is not known.
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
