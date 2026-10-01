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
}

/// Level, Form and streak at a glance, derived from the sessions and routine schedules.
@MainActor
struct ProgressionSnapshot {
    let ledger: Progression.Ledger
    let level: Progression.LevelInfo
    let form: Progression.Form
    let weekStreak: Int

    static func schedules(_ routines: [Routine]) -> [UUID: RoutineSchedule] {
        Dictionary(routines.compactMap { r in r.schedule.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    static func make(sessions: [WorkoutSession], routines: [Routine], now: Date = .now) -> ProgressionSnapshot {
        let schedules = schedules(routines)
        let ledger = Progression.ledger(sessions, schedules: schedules)
        return ProgressionSnapshot(ledger: ledger, level: Progression.levelInfo(totalXP: ledger.totalXP),
                                   form: Progression.form(sessions, schedules: schedules, now: now),
                                   weekStreak: Progression.weekStreak(sessions, now: now))
    }

    var look: BuddyLook { BuddyLook(stage: level.stage, form: form.value) }
}

// MARK: - Home card (wireframe frames 8–9)

/// Top of Home: your buddy as a still, with level, mood and streak. The first time, it's an egg you
/// hatch — your past sessions already count, so it grows straight to the level they earned.
struct BuddyHomeCard: View {
    let snapshot: ProgressionSnapshot

    @AppStorage(BuddyDefaults.hatchedKey, store: BuddyDefaults.store) private var hatched = false
    @State private var hatchingStage: BuddyStage?
    @State private var cheer = 0

    private var shownStage: BuddyStage { hatchingStage ?? (hatched ? snapshot.level.stage : .egg) }

    var body: some View {
        HStack(spacing: 12) {
            BuddyCreatureView(look: BuddyLook(stage: shownStage, form: snapshot.form.value),
                              cheerTrigger: cheer, animated: hatchingStage != nil, interactive: false)
                .frame(width: 118, height: 112)
                .background(LinearGradient(colors: [Color(hue: 0.75, saturation: 0.2, brightness: 0.28), Color(white: 0.1)],
                                           startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if hatched && hatchingStage == nil { status } else { meet }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.2), Color(red: 0.11, green: 0.11, blue: 0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("buddy.homeCard")
    }

    private var status: some View {
        Group {
            Text("\(snapshot.level.stage.title) · Level \(snapshot.level.level)")
                .font(.headline).foregroundStyle(.white)
                .accessibilityIdentifier("buddy.level")
            Text(snapshot.look.mood + (snapshot.weekStreak >= 2 ? " · 🔥 \(snapshot.weekStreak) weeks" : ""))
                .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            ProgressView(value: snapshot.level.fraction).tint(SnappetColor.workout)
            Text("\(snapshot.level.xpToNext) XP to Level \(snapshot.level.level + 1)")
                .font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
        .contentShape(Rectangle())
        .onTapGesture { cheer += 1 }
    }

    private var meet: some View {
        Group {
            Text("Meet your training buddy").font(.headline).foregroundStyle(.white)
            Text("It grows with every session. Your \(snapshot.ledger.sessionCount) so far count — it hatches at **Level \(snapshot.level.level) · \(snapshot.level.stage.title)**.")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button(hatchingStage == nil ? "Hatch" : "Hatching…") { hatch() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(SnappetColor.workout)
                .disabled(hatchingStage != nil)
                .accessibilityIdentifier("buddy.hatch")
        }
    }

    /// Grow through each stage up to the earned one, cheering at each, then remember it's hatched.
    private func hatch() {
        let target = snapshot.level.stage
        Task { @MainActor in
            for stage in BuddyStage.allCases where stage.rawValue <= target.rawValue {
                hatchingStage = stage
                cheer += 1
                try? await Task.sleep(for: .milliseconds(stage == target ? 1_300 : 750))
            }
            hatched = true
            hatchingStage = nil
        }
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

    var body: some View {
        let schedules = ProgressionSnapshot.schedules(routines)
        let ledger = Progression.ledger(completed, including: session, schedules: schedules)
        if let award = ledger.awards[session.id] {
            card(award: award, before: Progression.levelInfo(totalXP: ledger.xp(before: session.id)),
                 after: Progression.levelInfo(totalXP: ledger.totalXP),
                 form: Progression.form(completed + [session], schedules: schedules))
        } else {
            Label("Sessions of 5 minutes or more earn XP for your buddy.", systemImage: "sparkles")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("xp.none")
        }
    }

    private func card(award: Progression.Award, before: Progression.LevelInfo, after: Progression.LevelInfo,
                      form: Progression.Form) -> some View {
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
