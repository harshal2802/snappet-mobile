import XCTest
import SwiftData
@testable import Snappet

/// Pure-logic coverage for **On the Board** (Kilter Improvement P5): the per-climb-per-session dedup, the
/// day/session grouping + roll-ups, the status join (lit-only vs attempt vs sent, by normalized uuid), and
/// the recent-rail ordering. No SwiftData / no simulator — the dedup/grouping/join all live in the pure
/// `KilterOnTheBoard` helper.
final class KilterOnTheBoardTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let session = UUID()

    private func litEvent(_ uuid: String, name: String = "Climb", grade: String = "6a/V3",
                          angle: Int = 40, layout: Int = 1, size: Int = 10,
                          at t: TimeInterval, connected: Bool = true,
                          session: UUID? = nil) -> KilterOnTheBoard.LitEvent {
        KilterOnTheBoard.LitEvent(climbUUID: uuid, climbName: name, gradeLabel: grade, angle: angle,
                                  layoutId: layout, sizeId: size,
                                  litAt: Date(timeIntervalSince1970: t),
                                  wasConnected: connected, sessionId: session)
    }

    private func log(_ uuid: String, status: KilterAscentStatus, at t: TimeInterval,
                     grade: String = "6a/V3") -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: "Climb", gradeLabel: grade, difficulty: 18,
                       status: status, attempts: 1, loggedAt: Date(timeIntervalSince1970: t))
    }

    // MARK: - Dedup (same climb + session → one row)

    func testDedupCollapsesSameClimbSameSessionToOneRowKeepingNewestLitAt() {
        let events = [
            litEvent("abc", at: 100, session: session),
            litEvent("abc", at: 300, session: session),   // newest light
            litEvent("abc", at: 200, session: session),
        ]
        let deduped = KilterOnTheBoard.deduped(events)
        XCTAssertEqual(deduped.count, 1, "one climb lit thrice in a session is ONE row")
        XCTAssertEqual(deduped.first?.litAt, Date(timeIntervalSince1970: 300),
                       "the surviving row carries the newest light time")
    }

    func testDedupKeepsSameClimbInDifferentSessionsAsSeparateRows() {
        let other = UUID()
        let events = [
            litEvent("abc", at: 100, session: session),
            litEvent("abc", at: 200, session: other),
            litEvent("abc", at: 300, session: nil),   // out-of-session light is its own bucket
        ]
        XCTAssertEqual(KilterOnTheBoard.deduped(events).count, 3,
                       "the same climb across sessions stays separate rows")
    }

    func testDedupNormalizesUUIDForKey() {
        let events = [
            litEvent("ABC ", at: 100, session: session),
            litEvent("abc", at: 200, session: session),
        ]
        XCTAssertEqual(KilterOnTheBoard.deduped(events).count, 1,
                       "casing/whitespace must not split one climb into two")
    }

    /// F2 (pure mirror): an out-of-session climb lit repeatedly (`sessionId == nil`) collapses to ONE row.
    /// The `nil == nil` bucket match the in-memory upsert relies on — a `#Predicate { sessionId == nil }`
    /// compiles to SQL where `NULL == NULL` is never true, so the dedup is done in-memory on both sides.
    func testDedupCollapsesRepeatedNoSessionLightsToOneRow() {
        let events = [
            litEvent("abc", at: 100, session: nil),
            litEvent("abc", at: 300, session: nil),   // newest no-session light
            litEvent("abc", at: 200, session: nil),
        ]
        let deduped = KilterOnTheBoard.deduped(events)
        XCTAssertEqual(deduped.count, 1, "repeated no-session lights of one climb are ONE row (nil==nil)")
        XCTAssertEqual(deduped.first?.litAt, Date(timeIntervalSince1970: 300),
                       "the surviving no-session row carries the newest light time")
    }

    // MARK: - F7 deterministic tie-break (identical litAt in the same climb+session bucket)

    /// Two events for the SAME climb+session at the IDENTICAL instant must resolve to ONE deterministic
    /// survivor regardless of input order: `wasConnected` wins (a real on-the-wall light beats an
    /// intent-only tap). Without the tie-break the value `id` collides (same climb/session/instant), so the
    /// surviving row was whichever the dictionary happened to keep — order-dependent.
    func testTieBreakOnIdenticalLitAtPrefersConnectedDeterministically() {
        let connected = litEvent("abc", at: 100, connected: true, session: session)
        let intentOnly = litEvent("abc", at: 100, connected: false, session: session)
        // Either input order yields the connected row — a total, input-order-independent order.
        XCTAssertEqual(KilterOnTheBoard.deduped([intentOnly, connected]).first?.wasConnected, true)
        XCTAssertEqual(KilterOnTheBoard.deduped([connected, intentOnly]).first?.wasConnected, true)
    }

    /// With `wasConnected` equal, the tie-break falls to the steeper angle (then climbUUID, then sizeId) —
    /// still a total order, so the recent-rail / group sort is stable across re-queries and round-trips.
    func testTieBreakOnIdenticalLitAtAndConnectedFallsToSteeperAngle() {
        // Distinct climbs at the same instant — recent() orders them by the tie-break, not input order.
        let steep = litEvent("steep", angle: 50, at: 100, connected: true, session: session)
        let shallow = litEvent("shallow", angle: 30, at: 100, connected: true, session: session)
        XCTAssertEqual(KilterOnTheBoard.recent([shallow, steep]).map(\.event.climbUUID),
                       ["steep", "shallow"], "steeper angle sorts first on an identical instant")
        XCTAssertEqual(KilterOnTheBoard.recent([steep, shallow]).map(\.event.climbUUID),
                       ["steep", "shallow"], "…and the order is input-independent")
    }

    // MARK: - Status join

    func testStatusJoinSentBeatsAttemptBeatsLit() {
        let logs = [
            log("sent-climb", status: .sent, at: 10),
            log("attempt-climb", status: .attempt, at: 10),
            log("project-climb", status: .project, at: 10),
        ]
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "sent-climb", logs: logs), .sent)
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "attempt-climb", logs: logs), .attempt)
        // A project-only climb reads as "lit" (worked on the wall, not sent, not a plain attempt).
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "project-climb", logs: logs), .lit)
        // A lit-only climb with no log at all is "lit".
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "never-logged", logs: logs), .lit)
    }

    func testStatusJoinFlashCountsAsSentAndIsUUIDNormalized() {
        let logs = [log("ABC", status: .flash, at: 10)]
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "abc ", logs: logs), .sent,
                       "a flash is a send; the join normalizes the uuid")
    }

    func testStatusJoinSendStickyAcrossManyAttempts() {
        let logs = [
            log("abc", status: .attempt, at: 10),
            log("abc", status: .attempt, at: 20),
            log("abc", status: .sent, at: 30),
        ]
        XCTAssertEqual(KilterOnTheBoard.status(forClimb: "abc", logs: logs), .sent,
                       "any send anywhere on the climb wins over earlier attempts")
    }

    // MARK: - Grouping + roll-ups

    func testGroupingBucketsByDayAndSessionWithRollups() {
        let now = Date(timeIntervalSince1970: 1_000_000)   // a fixed clock
        let dayA = now.timeIntervalSince1970
        let dayB = dayA - 86_400                            // the day before
        let sA = UUID(), sB = UUID()
        let events = [
            litEvent("a1", at: dayA, session: sA),
            litEvent("a2", at: dayA + 60, session: sA),
            litEvent("b1", at: dayB, session: sB),
        ]
        let logs = [log("a1", status: .sent, at: dayA)]
        let model = KilterOnTheBoard.build(events: events, logs: logs, now: now, calendar: cal)

        XCTAssertEqual(model.groups.count, 2, "two day/session buckets")
        // Newest group first (today's session A).
        let today = model.groups[0]
        XCTAssertEqual(today.rows.count, 2)
        XCTAssertEqual(today.summary, "2 lit · 1 sent", "roll-up counts climbs worked + sends")
        // Rows within a group are newest-first.
        XCTAssertEqual(today.rows.first?.event.climbUUID, "a2")
    }

    func testGroupHeadlinePrefersBoardNameElseAngle() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let events = [litEvent("a1", angle: 45, layout: 7, at: now.timeIntervalSince1970, session: session)]
        // With a layout name resolver → "Today · <board>".
        let named = KilterOnTheBoard.build(events: events, logs: [], now: now, calendar: cal,
                                           layoutName: { $0 == 7 ? "BetaBoulders" : nil })
        XCTAssertEqual(named.groups.first?.headline, "Today · BetaBoulders")
        // Without a resolver → falls back to the dominant angle.
        let unnamed = KilterOnTheBoard.build(events: events, logs: [], now: now, calendar: cal)
        XCTAssertEqual(unnamed.groups.first?.headline, "Today · 45°")
    }

    func testHeroCountsDistinctClimbsOverDedupedSet() {
        let events = [
            litEvent("a", at: 100, session: session),
            litEvent("a", at: 200, session: session),   // same climb, deduped away from the count
            litEvent("b", at: 300, session: session),
        ]
        let model = KilterOnTheBoard.build(events: events, logs: [], now: Date(timeIntervalSince1970: 400),
                                           calendar: cal)
        XCTAssertEqual(model.climbsWorked, 2, "hero counts distinct climbs, not lit events")
    }

    // MARK: - Filtering

    func testStatusFacetFilterNarrowsRows() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let t = now.timeIntervalSince1970
        let events = [
            litEvent("sent", at: t, session: session),
            litEvent("lit", at: t - 10, session: session),
        ]
        let logs = [log("sent", status: .sent, at: t)]
        let model = KilterOnTheBoard.build(
            events: events, logs: logs,
            selections: [.status: KilterOnTheBoard.statusToken(.sent)], now: now, calendar: cal)
        let allRows = model.groups.flatMap(\.rows)
        XCTAssertEqual(allRows.map(\.event.climbUUID), ["sent"], "only the sent row survives the filter")
        // The facet rail still shows BOTH status chips (built pre-filter).
        XCTAssertEqual(Set(model.facetValues[.status] ?? []),
                       Set([KilterOnTheBoard.statusToken(.lit), KilterOnTheBoard.statusToken(.sent)]))
    }

    // MARK: - Recent rail ordering

    func testRecentRailIsDedupedNewestFirstAndCapped() {
        let events = [
            litEvent("a", at: 100, session: session),
            litEvent("a", at: 500, session: session),   // dedups; newest light 500
            litEvent("b", at: 300, session: session),
            litEvent("c", at: 400, session: session),
        ]
        let rail = KilterOnTheBoard.recent(events, limit: 2)
        XCTAssertEqual(rail.map(\.event.climbUUID), ["a", "c"],
                       "deduped, newest-first (a@500, c@400), capped at the limit")
    }

    func testRecentRailJoinsStatus() {
        let events = [litEvent("a", at: 100, session: session)]
        let logs = [log("a", status: .sent, at: 90)]
        XCTAssertEqual(KilterOnTheBoard.recent(events, logs: logs).first?.status, .sent)
    }
}

/// Store-level coverage for the shared `upsertLitEvent` capture path — the SwiftData edge behind the
/// detail-screen "Light up this climb" tap (F2) AND both re-light buttons (F3). Runs against an in-memory
/// `ModelContainer` (no UI, no device): the in-memory `nil == nil` session match (which a `#Predicate`
/// can't express) and the "re-light records into the CURRENT session" rule are exactly the bits a pure
/// test can't reach.
@MainActor
final class KilterLitEventUpsertTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() { container = nil; super.tearDown() }

    private func litEvents() throws -> [KilterLitEvent] {
        try context.fetch(FetchDescriptor<KilterLitEvent>())
    }

    private func upsert(_ uuid: String = "abc", session: UUID?, connected: Bool = true,
                        angle: Int = 40, size: Int = 10, at t: TimeInterval) {
        upsertLitEvent(climbUUID: uuid, climbName: "Climb", layoutId: 1, angle: angle, sizeId: size,
                       gradeLabel: "6a/V3", sessionId: session, wasConnected: connected,
                       at: Date(timeIntervalSince1970: t), in: context)
    }

    // MARK: - F2: no-session upsert dedups to ONE row (nil == nil in memory)

    /// Lighting the same climb repeatedly with NO live session must keep exactly ONE row (bumping `litAt`),
    /// not insert an unbounded new row each time. A `#Predicate { sessionId == nil }` would compile to SQL
    /// where `NULL == NULL` is never true — so the no-session row could never be found and every light
    /// inserted afresh. `upsertLitEvent` matches the session in memory, where `nil == nil` holds.
    func testNoSessionUpsertDedupsToOneRowAndBumpsLitAt() throws {
        upsert(session: nil, at: 100)
        upsert(session: nil, at: 200)
        upsert(session: nil, at: 300)
        let rows = try litEvents()
        XCTAssertEqual(rows.count, 1, "repeated no-session lights of one climb upsert to ONE row")
        XCTAssertEqual(rows.first?.litAt, Date(timeIntervalSince1970: 300), "litAt bumps to the latest")
        XCTAssertNil(rows.first?.sessionId)
    }

    /// The uuid side of the match is normalized too (trim + lowercase), so a differently-cased uuid still
    /// upserts the existing no-session row rather than splitting it (F2 + F6 share the one normalizer).
    func testNoSessionUpsertNormalizesUUID() throws {
        upsert("ABC ", session: nil, at: 100)
        upsert("abc", session: nil, at: 200)
        XCTAssertEqual(try litEvents().count, 1, "casing/whitespace must not split the no-session row")
    }

    // MARK: - F3: re-light records into the CURRENT session (never mutates an old row)

    /// Re-lighting a climb in a DIFFERENT (current) session must INSERT a fresh row for that session and
    /// leave the originating session's row untouched — the old bug bumped the newest row across ALL
    /// sessions, corrupting a different session's `litAt`.
    func testRelightInNewSessionInsertsFreshRowAndPreservesOldSession() throws {
        let s1 = UUID(), s2 = UUID()
        upsert(session: s1, at: 100)            // first lit in session 1
        upsert(session: s2, at: 500)            // re-lit later in session 2 (the current one)

        let rows = try litEvents().sorted { $0.litAt < $1.litAt }
        XCTAssertEqual(rows.count, 2, "a re-light in a new session is its own row")
        XCTAssertEqual(rows.map(\.sessionId), [s1, s2])
        XCTAssertEqual(rows.first?.litAt, Date(timeIntervalSince1970: 100),
                       "the original session's litAt is NOT corrupted by the later re-light")
        XCTAssertEqual(rows.last?.litAt, Date(timeIntervalSince1970: 500))
    }

    /// Re-lighting WITHIN the same current session upserts the one row (bumping `litAt` + the snapshot
    /// facts), so a project worked ten times in a session stays ONE bounded row.
    func testRelightWithinSameSessionUpsertsOneRow() throws {
        let s = UUID()
        upsert(session: s, angle: 40, at: 100)
        upsert(session: s, angle: 45, size: 12, at: 400)   // re-lit in the same session, picker moved
        let rows = try litEvents()
        XCTAssertEqual(rows.count, 1, "re-lighting within the session is ONE row")
        XCTAssertEqual(rows.first?.litAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(rows.first?.angle, 45, "the snapshot facts refresh to the current angle")
        XCTAssertEqual(rows.first?.sizeId, 12, "…and size")
    }
}
