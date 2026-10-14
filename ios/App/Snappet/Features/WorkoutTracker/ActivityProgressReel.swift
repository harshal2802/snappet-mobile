import Foundation
import CoreGraphics

/// **Pure** progress moments + progress-reel planning (activity progress P3, prompt 180).
///
/// - `badges`: which sessions were a FIRST (the first time the activity was done) or a PR (the hero metric beat
///   every earlier session) — the ★ badges on clips and the "PRs" filter.
/// - `pick`: which clips a progress reel uses (PRs only · one per month · all), oldest → newest, videos only.
/// - `caption`: the burned caption per clip ("15 Sep · 60 kg × 8").
/// - `captionOverlays`: those captions as timed text overlays over the exported composition, placed from what the
///   exporter ACTUALLY inserted (a clip that fails to load is skipped there, so plan-based timing would drift).
enum ActivityProgressReel {

    enum Badge: String, Sendable, Equatable {
        case first, pr
        var label: String { self == .first ? "FIRST" : "PR" }
    }

    enum Rule: String, CaseIterable, Identifiable, Sendable {
        case prs, monthly, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .prs: return "PRs only"
            case .monthly: return "One per month"
            case .all: return "All"
            }
        }
    }

    /// FIRST for the oldest point; PR for each later point strictly better than every point before it.
    static func badges(_ dashboard: ActivityDashboard) -> [UUID: Badge] {
        var out: [UUID: Badge] = [:]
        var best: Double?
        for p in dashboard.points {
            if let b = best {
                let better = dashboard.metric.higherIsBetter ? p.value > b : p.value < b
                if better { out[p.sessionID] = .pr; best = p.value }
            } else {
                out[p.sessionID] = .first
                best = p.value
            }
        }
        return out
    }

    /// The clips a progress reel uses, oldest → newest. Videos only (a reel is motion). `.prs` takes the first
    /// video of each badged session; `.monthly` the LAST video of each calendar month (the month's best form);
    /// `.all` every video.
    static func pick(_ clips: [ActivityClip], rule: Rule, badges: [UUID: Badge],
                     calendar: Calendar = .current) -> [ActivityClip] {
        let videos = clips.filter { $0.media.kindRaw == "video" }
            .sorted { ($0.sessionDate, $0.media.offsetSec) < ($1.sessionDate, $1.media.offsetSec) }
        switch rule {
        case .all:
            return videos
        case .prs:
            var seen = Set<UUID>()
            return videos.filter { badges[$0.sessionID] != nil && seen.insert($0.sessionID).inserted }
        case .monthly:
            var lastPerMonth: [DateComponents: ActivityClip] = [:]
            for v in videos { lastPerMonth[calendar.dateComponents([.year, .month], from: v.sessionDate)] = v }
            return videos.filter { v in lastPerMonth.values.contains { $0.id == v.id } }
        }
    }

    /// "15 Sep · 60 kg × 8" (or just the date when the clip isn't tied to a set).
    static func caption(_ clip: ActivityClip, calendar: Calendar = .current) -> String {
        let date = clip.sessionDate.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits))
        guard let s = clip.setSummary else { return date }
        return "\(date) · \(s)"
    }

    /// The reel route for these picks: their ids + a caption per `localIdentifier`.
    static func scope(for picks: [ActivityClip], title: String) -> ClipsReelScope {
        .progress(Set(picks.map(\.media.id)), title: title,
                  captions: Dictionary(picks.map { ($0.media.localIdentifier, caption($0)) },
                                       uniquingKeysWith: { a, _ in a }))
    }

    /// One inserted segment of an exported composition: its media id and where it sits on the output timeline.
    struct Placement: Equatable, Sendable {
        let mediaItemId: String
        let startSec: Double
        let durationSec: Double
    }

    /// Timed text overlays for the burned captions — one per placed segment that has a caption, shown for the
    /// segment's span, near the top so it clears the bottom HR scorebug.
    static func captionOverlays(placements: [Placement], captions: [String: String]) -> [OverlayItem] {
        placements.compactMap { p in
            guard let text = captions[p.mediaItemId], !text.isEmpty, p.durationSec > 0 else { return nil }
            return OverlayItem(kind: .text, content: text, startSec: p.startSec,
                               endSec: p.startSec + p.durationSec,
                               position: CGPoint(x: 0.5, y: 0.1), scale: 0.9,
                               highlightHex: "#000000")
        }
    }
}
