import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local pre-set reminders and clash alerts for the festival plan (festival prompt 04, wireframe
/// frame 7). Starred sets fire a configurable lead before they start — scheduled ON-DEVICE from the
/// pack's set times, so it works in an airplane-mode field: **no push service, no network**. Built
/// on `FestivalPlan.reminderDates` / `.clashes` (prompt 01's pure interval math).
///
/// **Layering** (the `WorkoutNotifications` precedent): the only festival file that touches
/// `UserNotifications`. Every entry point no-ops where notifications are unauthorized or the
/// framework is unavailable, so the plan never depends on it. The notification *copy* and the
/// *reschedule plan* are built by pure, testable functions with no `UserNotifications` types.
@MainActor
final class FestivalNotifications {

    /// Reminder identifiers are keyed by `packID` + set id, so rescheduling replaces a set's prior
    /// reminder rather than stacking, and a lineup's reminders can be cleared as a group.
    nonisolated static func reminderID(packID: String, setID: UUID) -> String {
        "snappet.festival.reminder.\(packID).\(setID.uuidString)"
    }
    nonisolated static func clashID(packID: String) -> String { "snappet.festival.clash.\(packID)" }

    /// Lead-time choices offered in the settings row (minutes before a set starts).
    static let leadOptions: [Int] = [5, 10, 15, 30, 60]
    static let defaultLeadMinutes = 15
    /// `@AppStorage` key for the chosen lead time (a plain preference — not a persisted model).
    static let leadStorageKey = "festival.reminderLeadMinutes"
    /// Nominal cross-stage walk (shared with `SetRecommender`); there's no geo in the pack.
    nonisolated static let stageWalkMinutes = SetRecommender.Config.default.stageWalkMinutes

    init() {}

    /// Ask for notification permission once (best-effort). Called from a **deliberate** surface (the
    /// For-You sheet / enabling reminders), not on every schedule appearance, so it never surprises
    /// the user mid-scroll. Safe to call repeatedly; a denied user is respected. No-op where
    /// `UserNotifications` is unavailable.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Reschedule every future starred set's reminder for `pack`: clear this lineup's prior reminders
    /// (so a star toggle or a reinstall never stacks or strands one), then add one per set the
    /// `reminderPlan` keeps. Idempotent. `add` doesn't prompt, so this is safe to call on any star
    /// change without a permission dialog — an unauthorized user simply sees nothing, and authorizes
    /// later from the For-You sheet. No-op where `UserNotifications` is unavailable.
    func reschedule(plan: FestivalPlan, pack: FestivalPack, leadMinutes: Int, now: Date = .now) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        // Clear any reminder for THIS pack's sets (pending or delivered).
        let ids = pack.allSets.map { Self.reminderID(packID: pack.id, setID: $0.id) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)

        for item in Self.reminderPlan(plan: plan, pack: pack, leadMinutes: leadMinutes, now: now) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let seconds = item.fireDate.timeIntervalSince(now)
            guard seconds > 0 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            center.add(request)
        }
        #endif
    }

    /// Fire a clash alert to the lock screen the moment two stars overlap (wireframe frame 7's "Two
    /// stars clash at 23:30"). Immediate (a short trigger) and single-slot per lineup, so the latest
    /// clash replaces the last. Complements the in-app alert the schedule shows; no-op where
    /// unavailable.
    func postClashAlert(_ clash: FestivalPlan.Clash, pack: FestivalPack) {
        #if canImport(UserNotifications)
        let (title, body) = Self.clashContent(clash, offsetSeconds: pack.utcOffsetSeconds)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Self.clashID(packID: pack.id),
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Clear every reminder + clash alert for `pack` (e.g. on lineup removal), so stale nudges don't
    /// linger after a festival is deleted.
    func clear(pack: FestivalPack) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        var ids = pack.allSets.map { Self.reminderID(packID: pack.id, setID: $0.id) }
        ids.append(Self.clashID(packID: pack.id))
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        #endif
    }

    // MARK: - Pure planning + copy (no `UserNotifications` — unit-tested without a device)

    /// One reminder to actually schedule: its identifier, when it fires, and its copy.
    struct Scheduled: Sendable, Equatable {
        let id: String
        let fireDate: Date
        let title: String
        let body: String
    }

    /// Which starred sets get a reminder and what each says — future sets only (a lead that already
    /// passed is dropped). The walk-hint line appears when the immediately-preceding star is on a
    /// DIFFERENT stage (so there's a walk to make). Pure → the whole plan is unit-tested.
    nonisolated static func reminderPlan(plan: FestivalPlan, pack: FestivalPack,
                                         leadMinutes: Int, now: Date) -> [Scheduled] {
        let lead = TimeInterval(max(0, leadMinutes) * 60)
        let starred = plan.starredSets(in: pack)
        return plan.reminderDates(in: pack, lead: lead).compactMap { reminder -> Scheduled? in
            guard reminder.fireDate > now else { return nil }
            // The star that ends most recently before this one starts — the stage you're walking FROM.
            let priorStage = starred
                .filter { $0.id != reminder.set.id && $0.end <= reminder.set.start }
                .max { $0.end < $1.end }?
                .stage
            let (title, body) = reminderContent(set: reminder.set, pack: pack,
                                                leadMinutes: leadMinutes, priorStage: priorStage)
            return Scheduled(id: reminderID(packID: pack.id, setID: reminder.set.id),
                             fireDate: reminder.fireDate, title: title, body: body)
        }
    }

    /// Reminder copy: "★ Fred again.. in 15 min" / "Pyramid Stage, 22:15. ~8-min walk from West
    /// Holts — leave after this set." The walk clause is present only when `priorStage` differs.
    nonisolated static func reminderContent(set: FestivalSet, pack: FestivalPack,
                                            leadMinutes: Int, priorStage: String?) -> (title: String, body: String) {
        let time = FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds)
        let title = "★ \(set.artist) in \(leadMinutes) min"
        var body = "\(set.stage), \(time)."
        if let from = priorStage, from != set.stage {
            body += " ~\(stageWalkMinutes)-min walk from \(from) — leave after this set."
        }
        return (title, body)
    }

    /// Clash copy: "Two stars clash at 23:30" / "Overmono ★ (West Holts) overlaps Eric Prydz ★
    /// (Arcadia) by 60 min. Pick a side in your plan."
    nonisolated static func clashContent(_ clash: FestivalPlan.Clash,
                                         offsetSeconds: Int) -> (title: String, body: String) {
        let at = FestivalSchedule.timeLabel(clash.overlap.start, offsetSeconds: offsetSeconds)
        let mins = Int((clash.overlap.duration / 60).rounded())
        let title = "Two stars clash at \(at)"
        let body = "\(clash.first.artist) ★ (\(clash.first.stage)) overlaps "
            + "\(clash.second.artist) ★ (\(clash.second.stage)) by \(mins) min. Pick a side in your plan."
        return (title, body)
    }

    /// "15 min" / "1 hr" — the lead-time menu label.
    nonisolated static func leadLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
        }
        return "\(minutes) min"
    }
}
