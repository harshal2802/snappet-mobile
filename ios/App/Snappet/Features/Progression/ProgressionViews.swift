import SwiftUI
import SwiftData

/// The buddy's few saved flags. UI-test launches use a scratch suite, wiped once per launch, so a
/// test can never hatch (or un-hatch) the real buddy on a phone (the prompt-133 rule).
enum BuddyDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uiTest") }),
              let suite = UserDefaults(suiteName: "snappet.uitest.buddy") else { return .standard }
        suite.removePersistentDomain(forName: "snappet.uitest.buddy")
        return suite
    }()
    static let hatchedKey = "buddy.hatched"
    static let styleKey = "buddy.style"
}

/// Level, Form and streak at a glance, derived from the sessions and routine schedules.
@MainActor
struct ProgressionSnapshot {
    let ledger: Progression.Ledger
    let level: Progression.LevelInfo
    let form: Progression.Form
    let streak: Progression.StreakState
    let pause: Progression.Pause?
    var weekStreak: Int { streak.weeks }

    static func schedules(_ routines: [Routine]) -> [UUID: RoutineSchedule] {
        Dictionary(routines.compactMap { r in r.schedule.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    static func make(sessions: [WorkoutSession], routines: [Routine], pauses: [Progression.Pause] = PauseStore.load(),
                     now: Date = .now) -> ProgressionSnapshot {
        let schedules = schedules(routines)
        let ledger = Progression.ledger(sessions, schedules: schedules, pauses: pauses)
        return ProgressionSnapshot(ledger: ledger, level: Progression.levelInfo(totalXP: ledger.totalXP),
                                   form: Progression.form(sessions, schedules: schedules, pauses: pauses, now: now),
                                   streak: Progression.streak(sessions, pauses: pauses, now: now),
                                   pause: Progression.activePause(pauses, now: now))
    }

    var look: BuddyLook { BuddyLook(stage: level.stage, form: form.value, paused: pause != nil) }

    /// "A streak freeze covered last week" — when the most recent frozen week was last week.
    func freezeCoveredLastWeek(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let last = streak.frozenWeeks.last,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) else { return false }
        return calendar.isDate(last, inSameDayAs: lastWeek)
    }
}

// MARK: - Finish screen XP (wireframe frame 1)

/// What this session earned, line by line, and where it leaves your level. Reads all completed
/// sessions itself (the player doesn't thread history through). The session counts even though it
/// isn't saved yet.
struct SessionXPCard: View {
    let session: WorkoutSession

    @Query(filter: #Predicate<WorkoutSession> { $0.completedAt != nil }) private var completed: [WorkoutSession]
    @Query private var routines: [Routine]
    @State private var cheer = 0
    @AppStorage(PauseStore.key, store: BuddyDefaults.store) private var pausesRaw = "[]"

    var body: some View {
        let schedules = ProgressionSnapshot.schedules(routines)
        let pauses = PauseStore.decode(pausesRaw)
        let ledger = Progression.ledger(completed, including: session, schedules: schedules, pauses: pauses)
        if let award = ledger.awards[session.id] {
            card(award: award, before: Progression.levelInfo(totalXP: ledger.xp(before: session.id)),
                 after: Progression.levelInfo(totalXP: ledger.totalXP),
                 form: Progression.form(completed + [session], schedules: schedules, pauses: pauses),
                 pause: Progression.activePause(pauses))
        } else {
            Label("Sessions of 5 minutes or more earn XP for your buddy.", systemImage: "sparkles")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("xp.none")
        }
    }

    private func card(award: Progression.Award, before: Progression.LevelInfo, after: Progression.LevelInfo,
                      form: Progression.Form, pause: Progression.Pause?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hue: BuddyLook(stage: after.stage, form: form.value).hue, saturation: 0.25, brightness: 0.3),
                                        Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
                BuddyCreatureView(look: BuddyLook(stage: after.stage, form: form.value), cheerTrigger: cheer,
                                  interactive: false)
                    .padding(.bottom, 4)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                cheer += 1
            }

            Text("+\(award.total) XP")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(SnappetColor.workout)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("xp.total")

            VStack(spacing: 0) {
                ForEach(Array(award.items.enumerated()), id: \.offset) { _, item in
                    row(item.label, "+\(item.xp)")
                }
                if award.capped {
                    let raw = award.items.reduce(0) { $0 + $1.xp }
                    row("Daily cap · \(Progression.Rules.dailyCap) XP a day", "−\(raw - award.total)", muted: true)
                }
            }
            .padding(.horizontal, 12)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("xp.items")

            levelLine(before: before, after: after)

            // Training while paused still counts — offer to end the pause (wireframe frame 6).
            if pause != nil {
                HStack {
                    Text("You're paused — this still counts.").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("End pause") { PauseStore.endActive(); pausesRaw = PauseStore.encode(PauseStore.load()) }
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("xp.endPause")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, muted: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).lineLimit(1)
            Spacer()
            Text(value).font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(muted ? Color.secondary : SnappetColor.workout)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func levelLine(before: Progression.LevelInfo, after: Progression.LevelInfo) -> some View {
        let leveled = after.level > before.level
        VStack(alignment: .leading, spacing: 5) {
            if leveled {
                Text(after.stage != before.stage
                     ? "Your buddy grew up: \(before.stage.title) → \(after.stage.title)!"
                     : "Level up! Level \(after.level)")
                    .font(.subheadline.weight(.heavy)).foregroundStyle(.green)
                    .accessibilityIdentifier("xp.levelUp")
            }
            HStack {
                Text("Level \(after.level) · \(after.stage.title)").font(.subheadline.weight(.bold))
                Spacer()
                Text("\(after.xpIntoLevel) / \(after.levelCost)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let start = leveled ? 0 : before.fraction
                ZStack(alignment: .leading) {
                    Capsule().fill(SnappetColor.surfaceMuted)
                    Capsule().fill(SnappetColor.workout).frame(width: geo.size.width * start)
                    Capsule().fill(SnappetColor.workout.opacity(0.45))
                        .frame(width: geo.size.width * max(0, after.fraction - start))
                        .offset(x: geo.size.width * start)
                }
            }
            .frame(height: 10)
            Text("\(after.xpToNext) XP to Level \(after.level + 1)").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("xp.level")
    }
}
