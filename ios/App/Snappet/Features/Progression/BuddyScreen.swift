import SwiftUI
import SwiftData

/// Your buddy's own screen (progression P2, prompt 149; wireframe frame 4): the live 3D buddy, level and
/// the next growth, Form and the week streak with freezes, pause mode, how XP works, style, recent XP.
struct BuddyScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<WorkoutSession> { $0.completedAt != nil }) private var sessions: [WorkoutSession]
    @Query private var routines: [Routine]
    @AppStorage(PauseStore.key, store: BuddyDefaults.store) private var pausesRaw = "[]"
    @AppStorage(BuddyDefaults.styleKey, store: BuddyDefaults.store) private var style = BuddyStyle.creature.rawValue

    @State private var sheet: Sheet?
    private enum Sheet: String, Identifiable { case form, pause, rules, style; var id: String { rawValue } }

    var body: some View {
        let snap = ProgressionSnapshot.make(sessions: sessions, routines: routines, pauses: PauseStore.decode(pausesRaw))
        ScrollView {
            VStack(spacing: 14) {
                hero(snap)
                tiles(snap)
                rows(snap)
                recent(snap)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(SnappetColor.paper.ignoresSafeArea())
        .navigationTitle("Your buddy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { which in
            switch which {
            case .form: FormSheet(form: snap.form, pause: snap.pause)
            case .pause: PauseSheet { replan() }
            case .rules: XPRulesSheet()
            case .style: BuddyStyleSheet(style: $style)
            }
        }
    }

    // MARK: Sections

    private func hero(_ snap: ProgressionSnapshot) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hue: snap.look.hue, saturation: 0.25, brightness: snap.pause == nil ? 0.32 : 0.24),
                                        Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                BuddyCreatureView(look: snap.look)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                Text("\(snap.level.stage.title) · Level \(snap.level.level)").font(.title3.weight(.heavy))
                    .accessibilityIdentifier("buddyScreen.level")
                Spacer()
                Text(snap.look.mood).font(.subheadline.weight(.semibold))
                    .foregroundStyle(snap.pause != nil ? .blue : snap.form.value >= 0.45 ? .green : .orange)
                    .accessibilityIdentifier("buddyScreen.mood")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(snap.level.xpIntoLevel) / \(snap.level.levelCost) XP").font(.caption.monospacedDigit())
                    Spacer()
                    if let next = Progression.nextStageLevel(after: snap.level.level) {
                        Text("\(Progression.stage(forLevel: next).title) at Level \(next)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(snap.ledger.totalXP.formatted()) XP all-time").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: snap.level.fraction).tint(SnappetColor.workout)
            }
        }
    }

    private func tiles(_ snap: ProgressionSnapshot) -> some View {
        HStack(spacing: 10) {
            Button { sheet = .form } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FORM").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                    Text("\(Int((snap.form.value * 100).rounded()))%").font(.title2.weight(.heavy))
                        .foregroundStyle(snap.form.value >= 0.45 ? .green : .orange)
                    ProgressView(value: snap.form.value).tint(snap.form.value >= 0.45 ? .green : .orange)
                    Text(snap.form.held ? "Held while paused" : snap.form.summary)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("buddyScreen.form")

            VStack(alignment: .leading, spacing: 3) {
                Text("WEEK STREAK").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                Text("🔥 \(snap.streak.weeks)").font(.title2.weight(.heavy))
                Text(snap.streak.freezes > 0 ? "❄︎ \(snap.streak.freezes) freeze\(snap.streak.freezes == 1 ? "" : "s") saved"
                     : "No freezes saved").font(.caption2).foregroundStyle(.secondary)
                Text(snap.streak.freezes >= Progression.Streaks.maxFreezes ? "Freezes full"
                     : "Next freeze in \(snap.streak.nextFreezeIn) wk").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("buddyScreen.streak")
        }
    }

    private func rows(_ snap: ProgressionSnapshot) -> some View {
        VStack(spacing: 0) {
            if let p = snap.pause {
                row(icon: "pause.circle.fill", tint: .blue, title: "Paused · \(p.reason.title)",
                    value: p.plannedEnd.map { "until \($0.formatted(.dateTime.weekday(.abbreviated).day().month()))" } ?? "until you're back",
                    id: "buddyScreen.pause", chevron: false) { }
                Divider()
                Button {
                    PauseStore.endActive()
                    pausesRaw = PauseStore.encode(PauseStore.load())
                    replan()
                } label: {
                    Label("I'm back — end pause", systemImage: "play.circle.fill").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .accessibilityIdentifier("buddyScreen.endPause")
            } else {
                row(icon: "pause.circle.fill", tint: .blue, title: "Pause mode", value: "Off", id: "buddyScreen.pause") { sheet = .pause }
            }
            Divider()
            row(icon: "sparkles", tint: SnappetColor.workout, title: "How XP works", value: "", id: "buddyScreen.rules") { sheet = .rules }
            Divider()
            row(icon: "circle.lefthalf.filled", tint: .green, title: "Style",
                value: BuddyStyle(rawValue: style)?.title ?? "Creature", id: "buddyScreen.style") { sheet = .style }
        }
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(icon: String, tint: Color, title: String, value: String, id: String, chevron: Bool = true,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                if chevron { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func recent(_ snap: ProgressionSnapshot) -> some View {
        let earned = sessions.filter { snap.ledger.awards[$0.id] != nil }.sorted { $0.startedAt > $1.startedAt }.prefix(8)
        if !earned.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT XP").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(earned)) { s in
                        HStack {
                            Text(s.routineName).lineLimit(1)
                            Text(s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month()))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("+\(snap.ledger.awards[s.id]?.total ?? 0)")
                                .font(.subheadline.weight(.heavy).monospacedDigit()).foregroundStyle(SnappetColor.workout)
                        }
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        if s.id != earned.last?.id { Divider() }
                    }
                }
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("buddyScreen.recent")
        }
    }

    private func replan() {
        RoutineScheduleSync.replan(context: context, reminders: app.routineReminders)
    }
}

/// The buddy's art style. Only Creature exists today; the others arrive as 3D model packs.
enum BuddyStyle: String, CaseIterable, Identifiable {
    case creature, companion, athlete
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var available: Bool { self == .creature }
    var icon: String {
        switch self {
        case .creature: "sparkles"
        case .companion: "pawprint.fill"
        case .athlete: "figure.strengthtraining.traditional"
        }
    }
}

// MARK: - Sheets

/// Form, explained (wireframe frame 5).
struct FormSheet: View {
    let form: Progression.Form
    let pause: Progression.Pause?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 2) {
                        Text("\(Int((form.value * 100).rounded()))%").font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(form.value >= 0.45 ? .green : .orange)
                        Text(pause != nil ? "Resting — Form is held" : BuddyLook(stage: .adult, form: form.value).mood)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("How it's worked out") {
                    switch form.basis {
                    case .plan(let d, let p):
                        Text("Sessions you **planned** in the last 4 weeks that you **did**: \(d) of \(p). A skipped day doesn't count against you, and neither does a paused one.")
                    case .usual(let r, let u):
                        Text("No schedule to compare with, so it compares your last 4 weeks (\(String(format: "%.1f", r)) a week) with your usual week (\(String(format: "%.1f", u))).")
                    case .new:
                        Text("Train for a couple of weeks and your Form appears here.")
                    }
                    if form.held { Text("You're paused, so Form stays where it was when the pause began.") }
                }
                Section("What it changes") {
                    Text("Only your buddy's mood — colour, glow, energy, sparks. **Never your level or XP.**")
                }
                Section("Moods") {
                    LabeledContent("Fired up", value: "75–100%")
                    LabeledContent("Steady", value: "45–74%")
                    LabeledContent("Tired", value: "20–44%")
                    LabeledContent("Sleepy", value: "under 20%")
                }
            }
            .navigationTitle("Form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Start a pause (wireframe frame 6).
struct PauseSheet: View {
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: Progression.Pause.Reason = .rest
    @State private var weeks: Int? = 1
    @State private var muteReminders = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Why") {
                    Picker("Why", selection: $reason) {
                        ForEach(Progression.Pause.Reason.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pause.reason")
                }
                Section("For") {
                    Picker("For", selection: $weeks) {
                        Text("1 week").tag(Int?.some(1))
                        Text("2 weeks").tag(Int?.some(2))
                        Text("4 weeks").tag(Int?.some(4))
                        Text("Until I'm back").tag(Int?.none)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pause.length")
                }
                Section {
                    LabeledContent("Form and streak", value: "Held")
                    Toggle("Quiet routine reminders", isOn: $muteReminders)
                        .accessibilityIdentifier("pause.mute")
                    LabeledContent("Your buddy", value: "Sleeps 💤")
                } footer: {
                    Text("Training while paused still earns XP. You can end the pause any time.")
                }
            }
            .navigationTitle("Pause")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        PauseStore.start(reason: reason, weeks: weeks, muteReminders: muteReminders)
                        onChange()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("pause.start")
                }
            }
        }
    }
}

/// The XP rules, straight from `Progression.Rules`.
struct XPRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private typealias R = Progression.Rules

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Finishing a session", value: "+\(R.finish)")
                    LabeledContent("Each active minute", value: "+\(R.perMinute) (up to \(R.minuteCap))")
                    LabeledContent("On plan", value: "+\(R.onPlan)")
                    LabeledContent("Each record", value: "+\(R.record) (up to \(R.recordMax))")
                    LabeledContent("Milestone (10th, 25th…)", value: "+\(R.milestone)")
                    LabeledContent("Week streak", value: "+\(R.streakPerWeek) × weeks (up to \(R.streakCap))")
                    LabeledContent("Apple Health workout", value: "+\(R.healthImport)")
                } header: { Text("Per session") } footer: {
                    Text("Sessions of 5 minutes or more with something completed count. Up to \(R.dailyCap) XP a day.")
                }
                Section("Levels") {
                    Text("Your level never goes down. Each level costs a little more than the last (100 + 50 × level).")
                    LabeledContent("Egg", value: "Level 1")
                    LabeledContent("Hatchling", value: "Levels 2–4")
                    LabeledContent("Sprout", value: "Levels 5–9")
                    LabeledContent("Adult", value: "Levels 10–19")
                    LabeledContent("Legend", value: "Level 20+")
                }
                Section("Streak freezes") {
                    Text("Every \(Progression.Streaks.freezeEvery) weeks of streak earns a freeze (hold up to \(Progression.Streaks.maxFreezes)). A week you miss uses one automatically, so the streak lives on.")
                }
            }
            .navigationTitle("How XP works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Pick a style — switch any time; your level and progress belong to you, not the style.
struct BuddyStyleSheet: View {
    @Binding var style: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(BuddyStyle.allCases) { s in
                        Button {
                            if s.available { style = s.rawValue }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: s.available ? s.icon : "lock.fill").font(.title2)
                                Text(s.title).font(.caption.weight(.bold))
                                if !s.available { Text("Coming soon").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 86)
                            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(style == s.rawValue ? SnappetColor.workout : .clear, lineWidth: 2))
                            .opacity(s.available ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("buddyStyle.\(s.rawValue)")
                    }
                }
                Text("Your level, Form and streak belong to you, not the style — switch any time and nothing changes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
