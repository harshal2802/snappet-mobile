import XCTest
import SwiftData
@testable import Snappet

/// Prompt 163 — the user's default HR tile + title for Clips: title text rules, tile precedence, design
/// switching, poster ⇄ render geometry, forward-compatible decode, and the backed-up store.
@MainActor
final class ClipOverlayStyleTests: XCTestCase {

    private let values = ClipOverlayStyle.TitleValues(
        name: "Black v6", outcome: "Sent", gradeAngle: "6c/V5 · 40°", attempt: "Attempt 3 · Sent",
        date: "Tue 30 Sep", session: "Tuesday Session")

    /// A stat's on/off in a tile (`entry(for:)` only returns stats that are ON).
    private func isOn(_ t: HRTile, _ m: HROverlayMetric) -> Bool? { t.entries.first { $0.metric == m }?.on }

    private func parts(_ on: [ClipOverlayStyle.TitlePart]) -> [ClipOverlayStyle.PartToggle] {
        ClipOverlayStyle.normalized(on.map { .init(part: $0, on: true) })
    }

    // MARK: title

    /// Built-in = today's poster: name / grade · angle / the attempt as a white chip.
    func testBuiltInTitleIsTodaysLowerThird() {
        let t = ClipOverlayStyle.builtIn.titleText(values)
        XCTAssertEqual(t, .init(primary: "Black v6", secondary: "6c/V5 · 40°", chip: "Attempt 3 · Sent"))
    }

    /// The wireframe's screen 3: name + outcome make the big line; plain look folds the attempt into the
    /// small line, and the attempt drops its "· Sent" so the title doesn't say Sent twice.
    func testHeadlineGroupingPlainLookAndNoDoubleOutcome() {
        var s = ClipOverlayStyle.builtIn
        s.titleLook = .plain
        s.titleParts = parts([.name, .outcome, .gradeAngle, .attempt, .date])
        XCTAssertEqual(s.titleText(values),
                       .init(primary: "Black v6 · Sent", secondary: "6c/V5 · 40° · Attempt 3 · Tue 30 Sep", chip: nil))
    }

    func testReorderBlankPartsAndPromotion() {
        var s = ClipOverlayStyle.builtIn
        s.titleLook = .plain
        s.titleParts = parts([.date, .session])                    // no headline part on
        XCTAssertEqual(s.titleText(values), .init(primary: "Tue 30 Sep · Tuesday Session", secondary: nil, chip: nil))
        var blank = values; blank.gradeAngle = "  "; blank.outcome = nil
        s.titleParts = parts([.outcome, .name, .gradeAngle])        // order respected, blanks dropped
        XCTAssertEqual(s.titleText(blank), .init(primary: "Black v6", secondary: nil, chip: nil))
    }

    func testTitleOffOrEmptySaysNothing() {
        var s = ClipOverlayStyle.builtIn
        s.showTitle = false
        XCTAssertNil(s.titleText(values))
        s.showTitle = true
        s.titleParts = ClipOverlayStyle.normalized([])
        XCTAssertNil(s.titleText(values))
    }

    // MARK: tile

    /// Precedence: a session's Studio tile wins; otherwise the default, with HRR off when there's no
    /// resting HR (the `.feedClipScorebug` rule).
    func testTilePrecedenceAndRestlessHRR() {
        var s = ClipOverlayStyle.builtIn
        s = s.switching(to: .hudPill)
        let studio = HRTile.make(template: .hero)
        XCTAssertEqual(s.tile(sessionTile: studio, restHR: nil), studio)
        XCTAssertEqual(s.tile(sessionTile: nil, restHR: 58).template, .hudPill)
        let scorebug = ClipOverlayStyle.builtIn.tile(sessionTile: nil, restHR: nil)
        XCTAssertEqual(isOn(scorebug, .hrr), false)
        let today = HRTile.feedClipScorebug(restHR: nil)                   // built-in == today's tile (ids differ)
        XCTAssertEqual(scorebug.templateRaw, today.templateRaw)
        XCTAssertEqual(scorebug.entries.map { "\($0.metricRaw)=\($0.on)" }, today.entries.map { "\($0.metricRaw)=\($0.on)" })
        XCTAssertEqual(scorebug.showChart, today.showChart)
    }

    func testSwitchingDesignKeepsStatChoicesAndTransparency() {
        var s = ClipOverlayStyle.builtIn
        s.hrTile.opacity = 0.6
        s.hrTile.entries = s.hrTile.entries.map { var e = $0; if e.metric == .avgHR { e.on = false }; return e }
        let switched = s.switching(to: .chartBanner)
        XCTAssertEqual(switched.hrTile.template, .chartBanner)
        XCTAssertEqual(isOn(switched.hrTile, .avgHR), false)
        XCTAssertEqual(switched.hrTile.opacity, 0.6)
    }

    // MARK: geometry

    func testPosterSizesScaleWithWidthAndBandsFill() {
        let a = ClipOverlayStyle.posterSize(.scorebug, width: 402)
        XCTAssertEqual(a.width / a.height, 4.2, accuracy: 0.001)
        let b = ClipOverlayStyle.posterSize(.hudPill, width: 804)
        let c = ClipOverlayStyle.posterSize(.hudPill, width: 402)
        XCTAssertEqual(b.height, c.height * 2, accuracy: 0.001)              // proportional to width
        XCTAssertEqual(ClipOverlayStyle.hAlign(.hudPill), .trailing)
    }

    /// The title stacks with the tile like the poster: bottom = title ABOVE the tile; top = BELOW it.
    func testTitleOriginStacksWithTheTile() {
        let canvas = CGSize(width: 1080, height: 1920)
        let block = CGSize(width: 400, height: 120)
        let inset = 1080 * ClipOverlayStyle.insetFraction
        var s = ClipOverlayStyle.builtIn                                    // both bottom
        let shared = s.titleOrigin(blockSize: block, canvas: canvas, tileHeight: 240)
        XCTAssertEqual(shared.y, 1920 - inset - (240 + inset * 0.8) - 120, accuracy: 0.5)
        s.hrEdge = .top                                                     // split edges: no push
        XCTAssertEqual(s.titleOrigin(blockSize: block, canvas: canvas, tileHeight: 240).y, 1920 - inset - 120, accuracy: 0.5)
        s.titleEdge = .top                                                  // both top: title under the tile
        XCTAssertEqual(s.titleOrigin(blockSize: block, canvas: canvas, tileHeight: 240).y, inset + 240 + inset * 0.8, accuracy: 0.5)
    }

    // MARK: codable

    /// An older blob missing fields decodes with defaults; a part added later is appended OFF.
    func testForwardCompatibleDecode() throws {
        let json = #"{"hrEdge":"top","titleParts":[{"part":"date","on":true}]}"#
        let s = try JSONDecoder().decode(ClipOverlayStyle.self, from: Data(json.utf8))
        XCTAssertEqual(s.hrEdge, .top)
        XCTAssertEqual(s.titleLook, .chip)
        XCTAssertEqual(s.hrTile.template, .scorebug)
        XCTAssertEqual(s.titleParts.first, .init(part: .date, on: true))
        XCTAssertEqual(s.titleParts.count, ClipOverlayStyle.TitlePart.allCases.count)
        XCTAssertEqual(s.titleParts.filter(\.on).count, 1)
    }

    // MARK: store (backed up)

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(SnappetSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func testStoreSavesOneRowSurvivesBackupAndResets() throws {
        let ctx = try makeContext()
        let store = ClipOverlayStyleStore()
        store.attach(ctx)
        XCTAssertEqual(store.style, .builtIn)
        var s = ClipOverlayStyle.builtIn.switching(to: .hudPill)
        s.hrEdge = .top
        store.save(s)
        store.save(s)                                                       // update in place, not a 2nd row
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ClipOverlayDefaults>()), 1)

        let file = try SnappetBackup.decode(SnappetBackup.encode(SnappetBackup.snapshot(of: ctx)))
        let restored = try makeContext()
        try SnappetBackup.restore(file, into: restored)
        XCTAssertEqual(ClipOverlayDefaults.style(in: restored), s)

        store.reset()
        XCTAssertEqual(store.style, .builtIn)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ClipOverlayDefaults>()), 0)
    }
}
