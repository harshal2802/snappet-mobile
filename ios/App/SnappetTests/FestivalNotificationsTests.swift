import XCTest
@testable import Snappet

/// The pure reminder-plan + notification copy (festival prompt 04, wireframe frame 7). The
/// `UNUserNotificationCenter` edge is thin; everything asserted here is device-free.
final class FestivalNotificationsTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    private let now = FestivalFixtures.date("2026-06-27T19:00")

    private func plan(_ artists: String...) -> FestivalPlan {
        FestivalPlan(starredSetIDs: Set(artists.map { FestivalFixtures.set(named: $0, in: pack).id }))
    }

    // MARK: - Reminder plan

    func testReminderPlanSchedulesFutureStarsAtTheLeadTime() {
        let scheduled = FestivalNotifications.reminderPlan(plan: plan("Fred again.."), pack: pack,
                                                           leadMinutes: 15, now: now)
        XCTAssertEqual(scheduled.count, 1)
        // Fred again.. starts 22:15; 15 min lead → fires 22:00.
        XCTAssertEqual(scheduled.first?.fireDate, FestivalFixtures.date("2026-06-27T22:00"))
        XCTAssertEqual(scheduled.first?.title, "★ Fred again.. in 15 min")
        XCTAssertTrue(scheduled.first?.body.hasPrefix("Pyramid Stage, 22:15.") == true)
    }

    func testReminderPlanDropsSetsWhoseLeadAlreadyPassed() {
        // now is 22:20 — after Fred's 22:00 lead, before Overmono's 23:15 lead.
        let late = FestivalFixtures.date("2026-06-27T22:20")
        let scheduled = FestivalNotifications.reminderPlan(plan: plan("Fred again..", "Overmono"),
                                                           pack: pack, leadMinutes: 15, now: late)
        XCTAssertEqual(scheduled.map { $0.title }, ["★ Overmono in 15 min"],
                       "a lead already in the past is dropped")
    }

    func testWalkHintAppearsOnlyWhenThePriorStarIsOnAnotherStage() {
        // Star Little Simz (Pyramid, ends 21:15) then Overmono (West Holts, 23:30) — different stage.
        let cross = FestivalNotifications.reminderPlan(plan: plan("Little Simz", "Overmono"),
                                                       pack: pack, leadMinutes: 15, now: now)
        let overmono = cross.first { $0.title.contains("Overmono") }
        XCTAssertTrue(overmono?.body.contains("walk from Pyramid Stage") == true,
                      "a cross-stage prior star adds the walk hint")

        // Star two Pyramid sets — no walk hint between same-stage sets.
        let same = FestivalNotifications.reminderPlan(plan: plan("Little Simz", "Fred again.."),
                                                      pack: pack, leadMinutes: 15, now: now)
        let fred = same.first { $0.title.contains("Fred") }
        XCTAssertFalse(fred?.body.contains("walk from") == true)
    }

    // MARK: - Clash copy

    func testClashContentReadsLikeTheWireframe() {
        // Overmono 23:30–01:00 overlaps Eric Prydz 23:00–00:30.
        let p = plan("Overmono", "Eric Prydz")
        let clash = p.clashes(in: pack).first!
        let (title, body) = FestivalNotifications.clashContent(clash, offsetSeconds: pack.utcOffsetSeconds)
        XCTAssertEqual(title, "Two stars clash at 23:30")
        XCTAssertTrue(body.contains("★"))
        XCTAssertTrue(body.contains("(Arcadia)"))
        XCTAssertTrue(body.contains("(West Holts)"))
        XCTAssertTrue(body.contains("by 60 min"))
    }

    // MARK: - Lead label

    func testLeadLabelFormats() {
        XCTAssertEqual(FestivalNotifications.leadLabel(15), "15 min")
        XCTAssertEqual(FestivalNotifications.leadLabel(60), "1 hr")
        XCTAssertEqual(FestivalNotifications.leadLabel(90), "1 hr 30 min")
    }
}
