import Foundation

// MARK: - Recap Feed — pure Story composition + rail eligibility (F6)
//
// Maps the period-scoped FeedComposer output into ordered Story scenes (cover + highlights), clamped
// 3 (sparse) … 8 (rich), in the Year-in-Climb arc order. Plus the Stories-rail eligibility rule
// (degrade-by-absence). Pure (Foundation only) + unit-tested; the view just renders + plays.

/// A discipline-accent token (kept platform-free; the view maps it to a SnappetColor).
enum StoryAccent: Sendable, Equatable { case kilter, workout, brand, effort }

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
    static func scenes(periodTitle: String, sessionCount: Int, cards: [FeedCard]) -> [StoryScene] {
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
        for c in highlights { scenes.append(scene(for: c)) }

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
        case .b1GradePR: return 0
        case .b4LiftPR: return 1
        case .c1Pyramid: return 2
        case .b3MostClimbs: return 3
        case .d1WeeklyVolume: return 4
        case .b5Streak: return 5
        case .e1Effort, .e2HardestEffort: return 6
        case .e3HRTrend: return 7
        default: return 8
        }
    }

    private static func scene(for card: FeedCard) -> StoryScene {
        switch card.payload {
        case .gradePR(let p):
            return s(card, "New hardest ever", p.newGrade, p.previousGrade.map { "up from \($0)" } ?? "your first peak", .brand)
        case .liftPR(let p):
            return s(card, "Lift PR", "\(Int(p.oneRepMaxKg.rounded())) kg", "\(p.exerciseName) est. 1RM", .brand)
        case .pyramid(let p):
            return s(card, "Your pyramid", p.maxGrade ?? "—", "\(p.totalSends) sends", .kilter)
        case .mostClimbs(let p):
            return s(card, "Biggest session", "\(p.count)", "climbs in one go", .kilter)
        case .weeklyVolume(let p):
            return s(card, "Volume", "\(p.buckets.last?.sends ?? 0)", "sends this week", .kilter)
        case .streak(let p):
            return s(card, "On a roll", "\(p.days)", "days in a row", .kilter)
        case .effort(let p):
            return s(card, "Effort", "\(p.maxBpm)", "peak BPM · \(p.trimp) TRIMP", .effort)
        case .hardestEffort(let p):
            return s(card, "Hardest-effort send", p.grade, "\(p.peakBpm) bpm at the top", .effort)
        case .hrTrend(let p):
            return s(card, "HR trend", "\(p.points.last?.avgBpm ?? 0)", "recent avg BPM", .workout)
        case .onTheBoard(let p):
            return s(card, "On the board", "\(p.litCount)", "climbs lit", .kilter)
        case .climbSession(let p):
            return s(card, "Session", p.hardestSendGrade ?? "—", "\(p.sends) sends", .kilter)
        case .workoutSession(let p):
            return s(card, "Workout", "\(p.setCount)", "sets", .workout)
        case .pyramidHealth(let p):
            return s(card, "Pyramid health", p.consolidateGrade, "consolidate", .kilter)
        case .progression(let p):
            return s(card, "Progression", "\(p.fromGrade) → \(p.toGrade)", "this period", .kilter)
        case .climbingLevel(let p):
            return s(card, "Climbing level", p.level, "working grade", .kilter)
        case .angleDist(let p):
            return s(card, "Angles", "\(p.topAngle)°", "most sends", .kilter)
        case .periodVsLast(let p):
            return s(card, "This period", "\(p.current)", "sends", .kilter)
        case .consistency(let p):
            return s(card, "Consistency", "\(p.activeDays)", "active days", .kilter)
        case .onThisDay(let p):
            return s(card, "On this day", p.grade ?? "—", "\(p.yearsAgo) yr ago", .kilter)
        }
    }

    private static func s(_ card: FeedCard, _ kick: String, _ big: String, _ small: String, _ accent: StoryAccent) -> StoryScene {
        StoryScene(id: card.id, kick: kick, big: big, small: small, accent: accent, card: card)
    }
}
