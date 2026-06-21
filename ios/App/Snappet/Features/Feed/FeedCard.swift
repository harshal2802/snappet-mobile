import Foundation

// MARK: - Recap Feed — pure card value types (F0 keystone)
//
// `FeedCard` is the ephemeral, derive-on-read unit the whole Recap feed renders.
// It is NEVER persisted (the persisted backbone is `FeedActivity`, F0b). It carries
// a discipline-typed `payload` snapshot so a view renders without re-querying the store.
//
// This file is pure value types only — no SwiftData, UIKit, or SwiftUI — so it
// unit-tests without a simulator and the Kotlin port (FA0) mirrors it 1:1.

/// The kind of card. Seeded with the F0 (derive-on-read) set; OPEN for additive
/// extension — F2/F3/F5/F6 add cases + registry entries, never editing the engine.
enum FeedCardKind: String, Codable, Sendable, CaseIterable {
    case a1Session        // a climbing session
    case a2Session        // a workout (gym) session
    case b1GradePR        // a send that set a new all-time hardest grade
    case b3MostClimbs     // a session that set a new most-climbs record
    case b5Streak         // a current activity streak (>= 3 days)
    case c1Pyramid        // the all-time grade pyramid (>= 15 sends, >= 3 grades)
    case d1WeeklyVolume   // weekly send-volume trend (>= 2 non-empty weeks)
    // F2 — HR-deepened (iOS; never composed when hrSeries is absent)
    case e1Effort         // session effort: HR zone bar + Edwards TRIMP
    case e2HardestEffort  // the send aligned to the session's effort peak
    case e3HRTrend        // avg/peak HR trend across recent HR sessions
    // F5 — more milestones
    case a3OnTheBoard     // a board session with lit climbs but no full log
    case b4LiftPR         // a gym est-1RM / weight personal record
    // F6 — cross-session insight menu (pure, all-time / log-scan derived)
    case c2PyramidHealth  // top-heavy pyramid nudge
    case c3Progression    // max-grade progression over months
    case c4ClimbingLevel  // current working grade
    case c5AngleDist      // sends across board angles
    case d2PeriodVsLast   // this period vs last (sends)
    case consistencyMap   // active-days consistency
    case onThisDay        // a send on this date in a prior year (memory)
}

/// Wayfinding category — drives the Lens bar (All · Climbing · Strength · Effort · Milestones).
enum FeedCategory: String, Codable, Sendable, CaseIterable {
    case climbing, strength, effort, milestone, trend, recap, memory
}

/// A reference back to the source object(s) a card derived from — for deep-link + dedup.
struct ActivityRef: Codable, Sendable, Equatable {
    var objectKind: String   // "kilterSession" | "workoutSession" | "climb" | "aggregate"
    var ref: String          // session id / climb uuid / period key

    init(objectKind: String, ref: String) {
        self.objectKind = objectKind
        self.ref = ref
    }
}

/// The suggested share template for a card (used by the F4 ShareComposer).
enum ShareTemplate: String, Codable, Sendable {
    case sendCard, sessionReceipt, gradePRTicket, boardPolaroid, pyramidCard
}

// MARK: - Payload snapshots (Codable; the view renders without re-query)

/// One row of a grade pyramid, mapped from `KilterSessionStats.GradeCount` (Codable copy).
struct PyramidRow: Codable, Sendable, Equatable {
    var grade: String
    var difficulty: Double
    var sends: Int
    var flashes: Int
    var projects: Int
    var attemptsOnly: Int
}

struct ClimbSessionPayload: Codable, Sendable, Equatable {
    var title: String?
    var hardestSendGrade: String?
    var totalClimbs: Int
    var sends: Int
    var projects: Int
    var attemptsOnly: Int
    var totalAttempts: Int
    var durationSec: Double
    var angle: Int
    var pyramid: [PyramidRow]
    /// True when a send in this session set a new all-time hardest grade (drives the PR accent).
    var isPRSession: Bool
}

struct WorkoutSessionPayload: Codable, Sendable, Equatable {
    var title: String
    var disciplineRaw: String
    var totalVolume: Double        // kg (strength): sum(reps × weight)
    var distanceMeters: Double?    // running
    var exerciseCount: Int
    var setCount: Int
    var durationSec: Double
}

struct GradePRPayload: Codable, Sendable, Equatable {
    var newGrade: String
    var newDifficulty: Double
    var previousGrade: String?
    var climbName: String
}

struct MostClimbsPayload: Codable, Sendable, Equatable {
    var count: Int
    var previousRecord: Int?
}

struct StreakPayload: Codable, Sendable, Equatable {
    var days: Int
    var weeks: Int
}

struct PyramidPayload: Codable, Sendable, Equatable {
    var rows: [PyramidRow]
    var totalSends: Int
    var maxGrade: String?
}

struct WeeklyVolumePayload: Codable, Sendable, Equatable {
    struct Bucket: Codable, Sendable, Equatable {
        var label: String
        var sends: Int
    }
    var buckets: [Bucket]
    var deltaVsPrev: Int           // latest week vs previous week
}

// MARK: F2 — HR payloads

/// One stacked slice of the HR zone bar. `zone` is `HeartRateZone.rawValue` (0…5).
struct ZoneSlice: Codable, Sendable, Equatable {
    var zone: Int
    var seconds: Double
}

struct EffortPayload: Codable, Sendable, Equatable {
    var title: String?
    var zones: [ZoneSlice]
    var avgBpm: Int
    var maxBpm: Int
    var trimp: Int
    var redlineSeconds: Double
    var totalSeconds: Double
    var durationSec: Double
}

struct HardestEffortPayload: Codable, Sendable, Equatable {
    var grade: String
    var climbName: String
    var peakBpm: Int
    var peakHRRPercent: Int?     // %HRR if max HR known
    var zoneAtPeak: Int          // HeartRateZone.rawValue
    var sendTimeOffsetSec: Double
}

struct HRTrendPayload: Codable, Sendable, Equatable {
    struct Point: Codable, Sendable, Equatable {
        var date: Date
        var avgBpm: Int
        var maxBpm: Int
    }
    var points: [Point]          // oldest → newest
}

// MARK: F5 — more milestone payloads

struct OnTheBoardPayload: Codable, Sendable, Equatable {
    var litCount: Int
    var hardestGrade: String?
    var gradeSpread: String   // e.g. "V3–V6"
}

struct LiftPRPayload: Codable, Sendable, Equatable {
    var exerciseName: String
    var oneRepMaxKg: Double
    var weightKg: Double
    var reps: Int
    var previousOneRepMaxKg: Double?
}

// MARK: F6 — insight payloads

struct PyramidHealthPayload: Codable, Sendable, Equatable {
    var rows: [PyramidRow]
    var consolidateGrade: String   // the row to shore up
    var note: String
}

struct ProgressionPayload: Codable, Sendable, Equatable {
    struct Point: Codable, Sendable, Equatable { var label: String; var grade: String }
    var points: [Point]            // oldest → newest
    var fromGrade: String
    var toGrade: String
}

struct ClimbingLevelPayload: Codable, Sendable, Equatable {
    var level: String
    var maxGrade: String?
}

struct AngleDistPayload: Codable, Sendable, Equatable {
    struct Slice: Codable, Sendable, Equatable { var angle: Int; var sends: Int }
    var slices: [Slice]            // descending by sends
    var topAngle: Int
}

struct PeriodVsLastPayload: Codable, Sendable, Equatable {
    var currentLabel: String
    var current: Int
    var previous: Int
}

struct ConsistencyPayload: Codable, Sendable, Equatable {
    var activeDays: Int            // distinct active days in the window
    var windowDays: Int
    var perDay: [Int]              // oldest → newest day counts (for a heatmap later)
}

struct OnThisDayPayload: Codable, Sendable, Equatable {
    var yearsAgo: Int
    var grade: String?
    var summary: String
}

/// The discipline-typed payload union. Codable is synthesized (all cases Codable).
enum FeedCardPayload: Codable, Sendable, Equatable {
    case climbSession(ClimbSessionPayload)
    case workoutSession(WorkoutSessionPayload)
    case gradePR(GradePRPayload)
    case mostClimbs(MostClimbsPayload)
    case streak(StreakPayload)
    case pyramid(PyramidPayload)
    case weeklyVolume(WeeklyVolumePayload)
    case effort(EffortPayload)
    case hardestEffort(HardestEffortPayload)
    case hrTrend(HRTrendPayload)
    case onTheBoard(OnTheBoardPayload)
    case liftPR(LiftPRPayload)
    case pyramidHealth(PyramidHealthPayload)
    case progression(ProgressionPayload)
    case climbingLevel(ClimbingLevelPayload)
    case angleDist(AngleDistPayload)
    case periodVsLast(PeriodVsLastPayload)
    case consistency(ConsistencyPayload)
    case onThisDay(OnThisDayPayload)
}

/// The ephemeral feed unit. Pure value; derive-on-read; never persisted.
struct FeedCard: Codable, Sendable, Equatable, Identifiable {
    /// Stable per-render id (kind + primary ref + anchor) — used for SwiftUI diffing, not storage.
    var id: String
    /// The originating activity's UUIDv5 content identity (F0b) — the key reactions/saves attach to.
    /// Empty for aggregate cards with no single source activity.
    var contentId: String = ""
    var kind: FeedCardKind
    var category: FeedCategory
    /// Base importance, independent of time (PR > milestone > trend > routine session).
    var salience: Double
    /// The trigger date. Ordering is recency-bounded: a card never out-floats a strictly-newer trigger.
    var anchorDate: Date
    var sourceRefs: [ActivityRef]
    var payload: FeedCardPayload
    var shareHint: ShareTemplate?
}

// Identity is the (unique) card id (kind + primary ref + anchor) — lets a card be a
// navigationDestination value without making every payload Hashable. `==` and `hash` are both
// keyed on `id` so the Hashable/Equatable contract holds (equal ⇒ equal hash).
extension FeedCard: Hashable {
    static func == (lhs: FeedCard, rhs: FeedCard) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
