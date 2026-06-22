import Foundation

// MARK: - Recap Feed — pure Story composition + rail eligibility (F6)
//
// Maps the period-scoped FeedComposer output into ordered Story scenes (cover + highlights), clamped
// 3 (sparse) … 8 (rich), in the Year-in-Climb arc order. Plus the Stories-rail eligibility rule
// (degrade-by-absence). Pure (Foundation only) + unit-tested; the view just renders + plays.

// `StoryAccent` is now `typealias StoryAccent = FeedAccent` (defined in FeedCardDisplay.swift) so the
// accent vocabulary is shared with the rest of the Recap feed. The existing `.kilter`/`.workout`/`.brand`/
// `.effort` literals keep resolving; `FeedAccent` adds `.recovery`/`.aerobic` (the descriptor emits those
// for the fitness-gain / HRV-recovery / rest-nudge insight kinds).

struct StoryScene: Identifiable, Sendable, Equatable {
    let id: String
    var kick: String
    var big: String
    var small: String
    var accent: StoryAccent
    /// Source card for per-scene Share (nil for the synthetic cover / closer).
    var card: FeedCard?
}

enum StoryComposition {
    static let minScenes = 3
    static let maxScenes = 8

    /// Period-scoped cards → ordered scenes. cover + highlights (arc order), clamped to [3, 8].
    /// `unit` (default `.km`) is threaded into the run hero so a story honors the user's km/mi choice.
    static func scenes(periodTitle: String, sessionCount: Int, cards: [FeedCard],
                       unit: DistanceUnit = .km) -> [StoryScene] {
        var scenes: [StoryScene] = [
            StoryScene(id: "cover", kick: periodTitle, big: "\(sessionCount)",
                       small: sessionCount == 1 ? "session logged" : "sessions logged", accent: .kilter, card: nil)
        ]
        let highlights = cards
            .filter { !isSession($0.kind) }
            .sorted { a, b in
                let (ra, rb) = (arcRank(a.kind), arcRank(b.kind))
                if ra != rb { return ra < rb }
                return a.salience > b.salience
            }
        for c in highlights { scenes.append(scene(for: c, unit: unit)) }

        scenes = Array(scenes.prefix(maxScenes))               // <= 8
        var pad = 0
        while scenes.count < minScenes {                       // >= 3
            scenes.append(StoryScene(id: "closer-\(pad)", kick: "Keep going", big: "Log more",
                                     small: "to unlock your \(periodTitle.lowercased()) story", accent: .workout, card: nil))
            pad += 1
        }
        return scenes
    }

    /// Which period covers are eligible to show in the rail (degrade-by-absence).
    /// week: >=1 session this week · month: >=1 this month · year: >=6 months of history.
    static func eligiblePeriods(sessionDates: [Date], now: Date, calendar: Calendar = .current) -> Set<StoryPeriod> {
        guard !sessionDates.isEmpty else { return [] }
        var out: Set<StoryPeriod> = []
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), sessionDates.contains(where: { week.contains($0) }) { out.insert(.week) }
        if let month = calendar.dateInterval(of: .month, for: now), sessionDates.contains(where: { month.contains($0) }) { out.insert(.month) }
        if let earliest = sessionDates.min() {
            let months = calendar.dateComponents([.month], from: earliest, to: now).month ?? 0
            if months >= 6 { out.insert(.year) }
        }
        return out
    }

    // MARK: helpers

    private static func isSession(_ k: FeedCardKind) -> Bool { k == .a1Session || k == .a2Session || k == .a3OnTheBoard }

    /// Year-in-Climb canonical arc: PR → progression → pyramid → most-climbs → volume/trend → angle → streak → effort → memory.
    private static func arcRank(_ k: FeedCardKind) -> Int {
        switch k {
        // PR tier
        case .b1GradePR, .g1ProjectSent: return 0
        case .b4LiftPR, .b2FirstAtGrade: return 1
        // progression / pyramid
        case .c3Progression, .c4ClimbingLevel: return 2
        case .c1Pyramid, .c2PyramidHealth: return 3
        // most-climbs / volume / trend
        case .b3MostClimbs: return 4
        case .d1WeeklyVolume, .d2PeriodVsLast, .d3DisciplineSplit, .d4TrendArrows: return 5
        case .c5AngleDist: return 6
        // streak / consistency
        case .b5Streak, .consistencyMap: return 7
        // effort
        case .e1Effort, .e2HardestEffort, .e4EffortEfficiency, .e5HRVRecovery, .restNudge: return 8
        case .e3HRTrend: return 9
        // memory (last)
        case .onThisDay: return 10
        // sessions never reach here (filtered out before arc ranking)
        case .a1Session, .a2Session, .a3OnTheBoard: return 11
        }
    }

    /// ONE scene = the shared `FeedCardDisplay` descriptor, projected to the story's kick + one big + one
    /// small line. The story leads its small line with the descriptor's `primaryLine` (the most-informative
    /// supporting fact — e.g. "8 sends", "up from V6", "past best 12"), falling back to `heroCaption` when
    /// there's no primary. This is the SAME wording the list/share/wall show — no parallel switch.
    private static func scene(for card: FeedCard, unit: DistanceUnit = .km) -> StoryScene {
        let d = card.display(unit: unit)
        let small = d.primaryLine ?? d.heroCaption
        return StoryScene(id: card.id, kick: d.kicker, big: d.hero, small: small, accent: d.accent, card: card)
    }
}
