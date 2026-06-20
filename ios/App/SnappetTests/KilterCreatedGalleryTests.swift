import XCTest
@testable import Snappet

/// Unit coverage for the pure "Your Climbs" gallery engine (`KilterCreatedGallery`, P2): it's global
/// across layouts (NOT the old layout-scoped Mine), segments Draft/Saved/All, sorts three ways, joins the
/// user's OWN logbook status (Sent/Project/Untried — never community signals), and filters by name +
/// facets. All pure — no simulator, no device, no catalog (hand-built rows).
final class KilterCreatedGalleryTests: XCTestCase {

    private typealias G = KilterCreatedGallery

    // Distinct, ascending timestamps so "newest first" is unambiguous.
    private func t(_ i: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60) }

    private func row(_ uuid: String, name: String = "Climb", setter: String = "You", layoutId: Int = 1,
                     angle: Int = 40, grade: Double? = 17, source: String = "manual", valid: Bool = true,
                     at i: Int = 0) -> G.CreatedRow {
        G.CreatedRow(uuid: uuid, name: name, setterUsername: setter, layoutId: layoutId, angle: angle,
                     predictedGrade: grade, source: source, isValid: valid, createdAt: t(i))
    }

    private func log(_ uuid: String, _ status: KilterAscentStatus) -> G.LogRow {
        G.LogRow(climbUUID: uuid, status: status)
    }

    // MARK: - Global across layouts (the headline change from Mine)

    func testGlobalAcrossLayoutsByDefault() {
        let created = [row("a", layoutId: 1, at: 0), row("b", layoutId: 7, at: 1), row("c", layoutId: 99, at: 2)]
        let items = G.items(created: created, logs: [])
        XCTAssertEqual(Set(items.map(\.uuid)), ["a", "b", "c"],
                       "climbs on every layout show — a board/layout facet, not a gate (unlike Mine)")
    }

    func testLayoutFacetRestrictsWhenSet() {
        let created = [row("a", layoutId: 1, at: 0), row("b", layoutId: 7, at: 1)]
        let items = G.items(created: created, logs: [], layoutId: 7)
        XCTAssertEqual(items.map(\.uuid), ["b"], "an explicit layout facet narrows to that layout only")
    }

    // MARK: - Status segmentation (Draft / Saved / All)

    func testStatusSegmentation() {
        let created = [row("valid1", valid: true, at: 0),
                       row("draft1", valid: false, at: 1),
                       row("valid2", valid: true, at: 2),
                       row("draft2", valid: false, at: 3)]
        XCTAssertEqual(Set(G.items(created: created, logs: [], segment: .all).map(\.uuid)),
                       ["valid1", "draft1", "valid2", "draft2"])
        XCTAssertEqual(Set(G.items(created: created, logs: [], segment: .saved).map(\.uuid)),
                       ["valid1", "valid2"], "Saved = complete/valid climbs only")
        XCTAssertEqual(Set(G.items(created: created, logs: [], segment: .drafts).map(\.uuid)),
                       ["draft1", "draft2"], "Drafts = the invalid (incomplete) climbs")
    }

    func testItemCarriesDraftFlag() {
        let created = [row("d", valid: false, at: 0)]
        XCTAssertTrue(G.items(created: created, logs: []).first?.isDraft == true)
    }

    // MARK: - Sort orders

    func testRecentlySetSortIsDefaultNewestFirst() {
        let created = [row("old", at: 0), row("mid", at: 1), row("new", at: 2)]
        let items = G.items(created: created, logs: [])
        XCTAssertEqual(items.map(\.uuid), ["new", "mid", "old"])
    }

    func testGradeSortHardestFirstWithUngradedLast() {
        let created = [row("v5", grade: 13, at: 0),
                       row("v9", grade: 21, at: 1),
                       row("ungraded", grade: nil, at: 2),
                       row("v7", grade: 17, at: 3)]
        let items = G.items(created: created, logs: [], sort: .grade)
        XCTAssertEqual(items.map(\.uuid), ["v9", "v7", "v5", "ungraded"],
                       "hardest first; ungraded sinks below every graded climb")
    }

    func testMostClimbedSortBySendCountNotAllLogRows() {
        // "manyAttempts" has 4 log rows but ZERO sends; "oneSend" has a single send. Ranking by SENDS
        // (F4) must put the real send first — a never-sent climb with many attempts can't outrank it.
        // (manyAttempts is the NEWEST, so under the old all-log-rows rank it would have led.)
        let created = [row("oneSend", at: 0), row("manyAttempts", at: 1)]
        let logs = [log("manyAttempts", .attempt), log("manyAttempts", .attempt),
                    log("manyAttempts", .attempt), log("manyAttempts", .project),
                    log("oneSend", .sent)]
        let items = G.items(created: created, logs: logs, sort: .mostClimbed)
        XCTAssertEqual(items.map(\.uuid), ["oneSend", "manyAttempts"],
                       "rank key is SEND count, not every log row — the sent climb leads despite fewer rows")
        XCTAssertEqual(items.map(\.sendCount), [1, 0])
        // logCount display is unchanged — it still counts all log rows.
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.uuid, $0.logCount) })["manyAttempts"], 4)
    }

    func testMostClimbedRanksByMoreSends() {
        let created = [row("oneSend", at: 0), row("twoSends", at: 1)]
        let logs = [log("oneSend", .sent),
                    log("twoSends", .sent), log("twoSends", .flash)]
        let items = G.items(created: created, logs: logs, sort: .mostClimbed)
        XCTAssertEqual(items.map(\.uuid), ["twoSends", "oneSend"], "flash + sent both count as sends")
        XCTAssertEqual(items.map(\.sendCount), [2, 1])
    }

    func testMostClimbedTieBreaksOnRecency() {
        let created = [row("older", at: 0), row("newer", at: 1)]   // both 0 sends
        let items = G.items(created: created, logs: [], sort: .mostClimbed)
        XCTAssertEqual(items.map(\.uuid), ["newer", "older"], "equal send counts fall back to newest-first")
    }

    // MARK: - Own status join (Sent / Project / Untried) — never community

    func testOwnStatusSentWhenAnySend() {
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt), log("x", .sent)]), .sent)
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .flash)]), .sent, "flash counts as a send")
    }

    func testOwnStatusProjectWhenProjectLoggedButNoSend() {
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt), log("x", .project)]), .project,
                       "any explicit .project (no send) → Project")
    }

    func testOwnStatusProjectOnlyNoAttempt() {
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .project)]), .project)
    }

    func testOwnStatusAttemptWhenOnlyAttempts() {
        // Explicit, future-proof precedence (F7): only attempts (no send, no project) → Attempt, NOT
        // the old "non-empty && not-send ⇒ Project" lump.
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt)]), .attempt)
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt), log("x", .attempt)]), .attempt)
    }

    func testOwnStatusPrecedenceSendBeatsProjectBeatsAttempt() {
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt), log("x", .project), log("x", .sent)]), .sent)
        XCTAssertEqual(G.ownStatus(forLogs: [log("x", .attempt), log("x", .project)]), .project)
    }

    func testOwnStatusUntriedWhenNoLogs() {
        XCTAssertEqual(G.ownStatus(forLogs: []), .untried)
    }

    func testOwnStatusIsJoinedPerCard() {
        let created = [row("sent", at: 0), row("proj", at: 1), row("att", at: 2), row("untried", at: 3)]
        let logs = [log("sent", .sent), log("proj", .project), log("att", .attempt)]
        let byUUID = Dictionary(uniqueKeysWithValues: G.items(created: created, logs: logs).map { ($0.uuid, $0.ownStatus) })
        XCTAssertEqual(byUUID["sent"], .sent)
        XCTAssertEqual(byUUID["proj"], .project)
        XCTAssertEqual(byUUID["att"], .attempt)
        XCTAssertEqual(byUUID["untried"], .untried)
    }

    /// A log row pointing at some OTHER climb must not bleed into this climb's own status.
    func testOwnStatusIgnoresUnrelatedLogs() {
        let created = [row("mine", at: 0)]
        let logs = [log("someone-elses-uuid", .sent)]
        XCTAssertEqual(G.items(created: created, logs: logs).first?.ownStatus, .untried)
    }

    /// F3: the climbUUID join is normalized (trim + lowercased) on BOTH sides, so a log uuid that differs
    /// from the climb uuid only in case / surrounding whitespace still resolves — never silently Untried.
    func testOwnStatusJoinNormalizesCaseAndWhitespace() {
        let created = [row("ABC-123", at: 0)]
        let logs = [log("  abc-123  ", .sent)]   // padded + lowercased — same climb
        let item = G.items(created: created, logs: logs).first
        XCTAssertEqual(item?.ownStatus, .sent, "case/whitespace-only differences still join")
        XCTAssertEqual(item?.logCount, 1)
        XCTAssertEqual(item?.sendCount, 1)
    }

    func testMostClimbedJoinIsNormalized() {
        // The send rank must also see the normalized join (an upper-case climb uuid vs lower-case log).
        let created = [row("Climb-UP", at: 0), row("untried", at: 1)]
        let logs = [log("climb-up", .sent)]
        let items = G.items(created: created, logs: logs, sort: .mostClimbed)
        XCTAssertEqual(items.map(\.uuid), ["Climb-UP", "untried"])
        XCTAssertEqual(items.first?.sendCount, 1)
    }

    // MARK: - Search + facet filters

    func testSearchFiltersByNameCaseInsensitive() {
        let created = [row("a", name: "Crimp Ladder", at: 0),
                       row("b", name: "Sloper Highway", at: 1),
                       row("c", name: "Crimpy Traverse", at: 2)]
        let items = G.items(created: created, logs: [], search: "  CRIMP ")
        XCTAssertEqual(Set(items.map(\.uuid)), ["a", "c"], "matches name substring, trimmed + case-insensitive")
    }

    /// F6: search matches name OR setterUsername (legacy Mine filter parity), not name only.
    func testSearchMatchesSetterName() {
        let created = [row("a", name: "Crimp Ladder", setter: "Alice", at: 0),
                       row("b", name: "Sloper Highway", setter: "Bob", at: 1),
                       row("c", name: "Pinch Wall", setter: "Alice", at: 2)]
        XCTAssertEqual(Set(G.items(created: created, logs: [], search: "alice").map(\.uuid)), ["a", "c"],
                       "matches the setter name, case-insensitively")
        // A term that's only in a name still matches; a term in neither matches nothing.
        XCTAssertEqual(Set(G.items(created: created, logs: [], search: "sloper").map(\.uuid)), ["b"])
        XCTAssertTrue(G.items(created: created, logs: [], search: "zzz").isEmpty)
    }

    /// F5: the angle facet options come from the climbs' OWN distinct angles (global across layouts),
    /// ascending — not the installed catalog, so an off-catalog angle stays reachable.
    func testAngleFacetsAreDistinctClimbAnglesAscending() {
        let created = [row("a", angle: 45, at: 0), row("b", angle: 25, at: 1),
                       row("c", angle: 45, at: 2), row("d", angle: 60, at: 3)]
        XCTAssertEqual(G.angleFacets(created: created), [25, 45, 60], "distinct + ascending")
        XCTAssertTrue(G.angleFacets(created: []).isEmpty)
    }

    func testAngleAndSourceFacets() {
        let created = [row("a", angle: 40, source: "manual", at: 0),
                       row("b", angle: 25, source: "generated", at: 1),
                       row("c", angle: 40, source: "generated", at: 2)]
        XCTAssertEqual(Set(G.items(created: created, logs: [], angle: 40).map(\.uuid)), ["a", "c"])
        XCTAssertEqual(Set(G.items(created: created, logs: [], source: "generated").map(\.uuid)), ["b", "c"])
        XCTAssertEqual(G.items(created: created, logs: [], angle: 40, source: "generated").map(\.uuid), ["c"])
    }

    func testProvenanceDerivedFromSource() {
        let created = [row("h", source: "manual", at: 0), row("g", source: "generated", at: 1)]
        let byUUID = Dictionary(uniqueKeysWithValues: G.items(created: created, logs: []).map { ($0.uuid, $0.provenance) })
        XCTAssertEqual(byUUID["h"], .handSet)
        XCTAssertEqual(byUUID["g"], .generated)
    }

    func testEmptyWhenNoCreatedClimbs() {
        XCTAssertTrue(G.items(created: [], logs: [log("x", .sent)]).isEmpty)
    }
}
