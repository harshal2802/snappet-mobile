import SwiftUI

/// What the house pet shows, worked out once per render (household prompt 03).
struct HousePetState {
    let name: String
    let level: Progression.LevelInfo
    let mood: Double
    let paused: Bool
    let streak: Int
    let moodTitle: String
    let moodDetail: String?

    var look: BuddyLook { BuddyLook(stage: level.stage, form: mood, paused: paused) }

    @MainActor
    init(store: HouseholdStore, now: Date = .now) {
        let board = store.board
        name = store.petName
        level = Progression.levelInfo(totalXP: HouseholdInsights.houseXP(board, xp: Progression.Rules.choreXP))
        paused = board.isPaused(at: now)
        mood = HouseholdInsights.mood(board, now: now)
        streak = HouseholdInsights.streak(board, now: now)
        moodTitle = HouseholdInsights.moodTitle(mood, paused: paused)
        moodDetail = paused ? "The house is paused, so nothing's overdue." : HouseholdInsights.moodDetail(board, now: now)
    }
}

/// Today's hero (frame 1): the shared pet with the house goal underneath. Tap the pet for its screen.
struct HouseholdPetCard: View {
    let store: HouseholdStore
    var service: HouseholdPeerService?
    let setGoal: () -> Void
    let openPet: () -> Void
    @Binding var cheer: Int
    /// The pet's own screen is on top: drop this 3D view so only one creature renders at a time.
    var covered = false

    var body: some View {
        let pet = HousePetState(store: store)
        let board = store.board
        let now = Date.now
        let start = ChoreSchedule.weekStart(now)
        let done = board.roundsByDay(weekStart: start).reduce(0, +)
        let goal = board.goal(now: now)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openPet) {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(hue: pet.look.hue, saturation: 0.3, brightness: 0.32), Color(white: 0.1)],
                                   startPoint: .top, endPoint: .bottom)
                    Group {
                        if covered { Color.clear } else { BuddyCreatureView(look: pet.look, cheerTrigger: cheer, interactive: false) }
                    }
                        .frame(height: 150)
                        .padding(.top, 18)
                        .allowsHitTesting(false)   // the whole card opens the pet's screen
                        .accessibilityHidden(true)
                    HStack {
                        chip(now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        Spacer()
                        if store.isShared, let service { HouseholdSyncPill(store: store, service: service) }
                        else if pet.streak > 1 { chip("🔥 \(pet.streak) weeks") }
                    }
                    .padding(10)
                }
                .frame(height: 170)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("household.pet")
            .accessibilityLabel("\(pet.name), house level \(pet.level.level), \(pet.moodTitle)")

            Button(action: setGoal) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(pet.name) · House Lv \(pet.level.level)").font(.headline).foregroundStyle(.white)
                    Text(pet.moodTitle).font(.caption.weight(.semibold))
                        .foregroundStyle(pet.mood >= 0.5 || pet.paused ? Color(hex: 0x8CE09F) : Color(hex: 0xE6C55C))
                    HStack {
                        if let goal, goal.target > 0 {
                            Text("House goal \(done) / \(goal.target) this week")
                            Spacer()
                            if !goal.reward.isEmpty { Text(goal.reward) }
                        } else {
                            Text(done == 1 ? "1 chore done this week" : "\(done) chores done this week")
                            Spacer()
                            Text("Set a goal ›")
                        }
                    }
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
                    ProgressView(value: Double(min(done, max(1, goal?.target ?? done))), total: Double(max(1, goal?.target ?? max(done, 1))))
                        .tint(SnappetColor.household)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.bottom, 11).padding(.top, 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("household.goal.card")
            .accessibilityElement(children: .combine)
        }
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.vertical, 4)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.35), in: Capsule())
    }
}

/// The pet's own screen (frame 9): mood, what would cheer it up, streak, pause, name.
struct HouseholdPetScreen: View {
    let store: HouseholdStore
    @State private var name = ""
    @State private var cheer = 0

    var body: some View {
        let pet = HousePetState(store: store)
        let late = HouseholdInsights.overdue(store.board, now: .now)
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    ZStack {
                        LinearGradient(colors: [Color(hue: pet.look.hue, saturation: 0.3, brightness: 0.32), Color(white: 0.08)],
                                       startPoint: .top, endPoint: .bottom)
                        // Not draggable: in a scroll view the drag belongs to scrolling (the buddy's own rule).
                        BuddyCreatureView(look: pet.look, cheerTrigger: cheer, interactive: false)
                            .accessibilityLabel("\(pet.name), the house pet, \(pet.moodTitle)")
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text(pet.moodTitle).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                        .accessibilityIdentifier("household.pet.mood")
                    if let detail = pet.moodDetail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 14) {
                        Label("House Lv \(pet.level.level) · \(pet.level.stage.title)", systemImage: "house.fill")
                        if pet.streak > 0 { Label("\(pet.streak) week\(pet.streak == 1 ? "" : "s")", systemImage: "flame.fill") }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.household)
                    ProgressView(value: pet.level.fraction).tint(SnappetColor.household)
                    Text("\(pet.level.xpToNext) house XP to Level \(pet.level.level + 1)")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !late.isEmpty, !pet.paused {
                    card(title: "What would cheer \(pet.name) up") {
                        ForEach(late, id: \.chore.id) { item in
                            HStack(spacing: 12) {
                                Text(item.chore.emoji).font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.chore.name).font(.body.weight(.semibold))
                                    Text(item.days == 1 ? "1 day over" : "\(item.days) days over")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("I'll do it") { store.complete(item.chore); cheer += 1 }
                                    .buttonStyle(.bordered).tint(SnappetColor.household).font(.caption.weight(.bold))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                card(title: nil) {
                    Toggle("Pause the house (holiday)", isOn: Binding(
                        get: { store.board.isPaused(at: .now) },
                        set: { $0 ? store.pauseHouse() : store.resumeHouse() }))
                        .accessibilityIdentifier("household.pet.pause")
                    Divider()
                    LabeledContent("Name") {
                        TextField("Pet name", text: $name)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { store.namePet(name) }
                            .accessibilityIdentifier("household.pet.name")
                    }
                }
                Text("\(pet.name) grows with every chore anyone does, and its mood follows how the house is doing. While the house is paused, nothing counts as overdue and the streak waits for you.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(SnappetColor.paper)
        .navigationTitle(pet.name)
        .onAppear { name = store.petName }
    }

    private func card(title: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Fair share (frame 2): balance, not ranking.
struct HouseholdFairShareCard: View {
    let store: HouseholdStore

    var body: some View {
        let shares = HouseholdInsights.fairShare(store.board, weekStart: ChoreSchedule.weekStart(.now))
        let balance = HouseholdInsights.balance(shares)
        let tints: [Color] = [SnappetColor.workout, SnappetColor.budget, SnappetColor.journal, SnappetColor.household,
                              SnappetColor.wardrobe, SnappetColor.tip]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fair share").font(.headline)
                Spacer()
                if let balance {
                    Text(balance.rawValue).font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background((balance == .balanced ? SnappetColor.household : SnappetColor.perfModerate).opacity(0.18),
                                    in: Capsule())
                        .foregroundStyle(balance == .balanced ? SnappetColor.household : SnappetColor.perfModerate)
                        .accessibilityIdentifier("household.fairShare.balance")
                }
            }
            Text("Effort this week (S 1 · M 2 · L 3), not a ranking").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(shares.enumerated()), id: \.element.member.id) { i, share in
                        Rectangle().fill(tints[i % tints.count])
                            .frame(width: geo.size.width * (shares.allSatisfy { $0.points == 0 } ? 1 / Double(shares.count) : share.fraction))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            FlowLegend(items: shares.enumerated().map { i, s in
                (tints[i % tints.count], "\(s.member.id == store.me ? "You" : s.member.name) \(s.points)")
            })
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FlowLegend: View {
    let items: [(Color, String)]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(item.0).frame(width: 9, height: 9)
                    Text(item.1).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Someone asked for a hand (frames 2, 9). Mine show a "take it back" instead.
struct HouseholdHelpCard: View {
    let store: HouseholdStore
    let request: HelpRequest

    var body: some View {
        let chore = store.board.chores[request.chore]
        let mine = request.member == store.me
        HStack(spacing: 10) {
            Text("🤝").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(mine ? "You asked for a hand" : "\(store.board.name(of: request.member)) asked for a hand")
                    .font(.subheadline.weight(.semibold))
                Text([chore.map { "\($0.name) · \($0.effort.label)" }, request.note.isEmpty ? nil : request.note]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if mine {
                Button("Take back") { store.retractHelp(request) }
                    .font(.caption.weight(.bold)).buttonStyle(.bordered)
            } else if let chore {
                Button("Take it") { store.claim(chore) }
                    .font(.caption.weight(.bold)).buttonStyle(.bordered).tint(SnappetColor.household)
                    .accessibilityIdentifier("household.help.take")
            }
        }
    }
}

/// "Ask for a hand" with an optional note.
struct HouseholdAskHelpSheet: View {
    let chore: Chore
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(chore.emoji) \(chore.name)").font(.headline)
                } footer: {
                    Text("Everyone in the household sees it, and anyone can take it. It closes when the chore's done.")
                }
                Section("Note (optional)") {
                    TextField("e.g. Away till Tuesday", text: $note)
                        .accessibilityIdentifier("household.help.note")
                }
            }
            .navigationTitle("Ask for a hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") { send(note); dismiss() }.accessibilityIdentifier("household.help.send")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Week in the house (frame 8): a celebration, not a ranking.
struct HouseholdRecapSheet: View {
    let store: HouseholdStore
    let weekStart: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let recap = HouseholdInsights.recap(store.board, weekStart: weekStart, xp: Progression.Rules.choreXP,
                                            level: { Progression.levelInfo(totalXP: $0).level })
        NavigationStack {
            ScrollView {
                HouseholdRecapCard(store: store, recap: recap)
                    .padding()
            }
            .background(SnappetColor.paper)
            .navigationTitle("Week in the house")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("household.recap.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let image = ImageRenderer(content: HouseholdRecapCard(store: store, recap: recap)
                        .frame(width: 360).padding().background(Color(white: 0.08))).uiImage {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Week in the house", image: Image(uiImage: image)))
                    }
                }
            }
        }
    }
}

struct HouseholdRecapCard: View {
    let store: HouseholdStore
    let recap: HouseholdInsights.Recap

    var body: some View {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: recap.weekStart) ?? recap.weekStart
        VStack(alignment: .leading, spacing: 10) {
            Text("\(recap.weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))".uppercased())
                .font(.caption.weight(.heavy)).kerning(1).foregroundStyle(Color(hex: 0x8CE09F))
            Text(recap.rounds == 1 ? "1 chore" : "\(recap.rounds) chores")
                .font(.system(size: 40, weight: .black)).foregroundStyle(.white)
                .accessibilityIdentifier("household.recap.total")
            if let goal = recap.goal, goal.target > 0 {
                Text(recap.goalMet ? "Goal smashed\(goal.reward.isEmpty ? "" : ": \(goal.reward) unlocked") 🎉"
                                   : "\(recap.rounds) of \(goal.target) towards the goal")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            } else if recap.rounds == 0 {
                Text("A quiet week. \(store.petName) is ready when you are.").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            if recap.levelAfter > recap.levelBefore {
                Text("\(store.petName) grew to House Lv \(recap.levelAfter)").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x8CE09F))
            }
            if !recap.lines.isEmpty || !recap.thanks.isEmpty || recap.balanced {
                Text("THANK-YOUS").font(.caption.weight(.heavy)).kerning(1).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
            }
            ForEach(recap.lines, id: \.member.id) { line in
                row(MemberAvatar(name: line.member.id == store.me ? store.myName : line.member.name, id: line.member.id),
                    Text("**\(line.member.id == store.me ? "You" : line.member.name)** \(line.text)"))
            }
            ForEach(recap.thanks, id: \.opID) { t in
                let chore = t.chore.flatMap { store.board.chores[$0]?.name.lowercased() }
                row(Text("👏"), Text("**\(t.by == store.me ? "You" : store.board.name(of: t.by))** thanked \(t.member == store.me ? "you" : store.board.name(of: t.member))\(chore.map { " for the \($0)" } ?? "")"))
            }
            if recap.balanced {
                row(Text("⚖️"), Text("Everyone's share stayed close"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: 0x2A3B33), Color(hex: 0x1A1C22)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ icon: some View, _ text: Text) -> some View {
        HStack(spacing: 8) {
            icon
            text.font(.subheadline).foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Power hour (household prompt 04, frame 7)

/// Today's power-hour row: a live banner while one runs (anyone's), otherwise a way to start one.
struct HouseholdPowerHourRow: View {
    let store: HouseholdStore
    @State private var starting = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let hour = store.board.powerHour(at: context.date) {
                banner(hour, now: context.date)
            } else {
                Button { starting = true } label: {
                    Label("Start a power hour", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("household.powerHour.start")
            }
        }
        .sheet(isPresented: $starting) {
            PowerHourStartSheet { minutes, target in store.startPowerHour(minutes: minutes, target: target) }
        }
    }

    private func banner(_ hour: PowerHour, now: Date) -> some View {
        let progress = store.board.powerHourProgress(hour, now: now)
        let left = max(0, Int(hour.end.timeIntervalSince(now)))
        let who = progress.members.map { $0 == store.me ? "you" : store.board.name(of: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Power hour", systemImage: "sparkles").font(.headline).foregroundStyle(SnappetColor.household)
                Spacer()
                Text("\(left / 60):\(String(format: "%02d", left % 60)) left").font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text(hour.target > 0 ? "\(progress.done) of \(hour.target) chores" : "\(progress.done) chores so far")
                .font(.subheadline)
                .accessibilityIdentifier("household.powerHour.count")
            ProgressView(value: Double(min(progress.done, max(1, hour.target))), total: Double(max(1, hour.target)))
                .tint(SnappetColor.household)
            HStack {
                Text(who.isEmpty ? "Tick something to get it going" : "In: \(who.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("End", role: .destructive) { store.endPowerHour() }
                    .font(.caption.weight(.bold)).buttonStyle(.bordered)
                    .accessibilityIdentifier("household.powerHour.end")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("household.powerHour.banner")
    }
}

struct PowerHourStartSheet: View {
    let start: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30
    @State private var target = 10

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How long", selection: $minutes) {
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("How long")
                } footer: {
                    Text("Everyone's phone shows the countdown on the Lock Screen. The count catches up whenever phones sync.")
                }
                Section("Aim for") {
                    Stepper("\(target) chores", value: $target, in: 1...100)
                        .accessibilityIdentifier("household.powerHour.target")
                }
            }
            .navigationTitle("Power hour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { start(minutes, target); dismiss() }
                        .accessibilityIdentifier("household.powerHour.go")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
