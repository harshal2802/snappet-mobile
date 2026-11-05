import SwiftUI
import SwiftData

// MARK: - The schedule's bottom bar (prompt 232)

/// Where you are, at the bottom of the schedule: I'm here / Start the night before anything's
/// claimed, On the floor while at a set (with the auto-move confirm above it), the break / walking /
/// arriving bar, and "Where are you now?" between things. Ids: `festival.imHere` stays on the
/// claim/on-the-floor button the UI tests already drive.
struct FestivalNightBar: View {
    let status: FestivalNight.Status
    let pack: FestivalPack
    /// The "I'm here" candidate (live by the schedule, starred first).
    let liveSet: FestivalSet?
    let openAttendance: FestivalAttendance?
    let now: Date
    var onOpenLive: () -> Void
    var onClaim: (FestivalSet) -> Void
    var onStartNight: () -> Void
    var onWhere: () -> Void
    var onConfirmAutoMove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let open = openAttendance, open.autoMoved {
                autoMovedCard(open)
            }
            switch status {
            case .off:
                if let liveSet {
                    primary("I'm here — \(liveSet.artist)", symbol: "smallcircle.filled.circle",
                            id: "festival.imHere") { onClaim(liveSet) }
                    Button("Not at a set yet? Start the night") { onStartNight() }
                        .font(.footnote)
                        .tint(SnappetColor.brand)
                        .accessibilityIdentifier("festival.startNight")
                } else {
                    Text("Nothing on yet — start tracking when you head in")
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                    primary("Start the night", symbol: "play.fill", id: "festival.startNight") {
                        onStartNight()
                    }
                }
            case .atSet:
                primary("On the floor — \(openAttendance?.artist ?? "")", symbol: "waveform",
                        id: "festival.imHere") { onOpenLive() }
            case .stretch(let kind, let since):
                nightLine(since: since, kind: kind)
                primary(kind == .rest ? "\(kind.title) · Back on the floor ›" : "\(kind.title) · I'm here now ›",
                        symbol: kind.symbol, id: "festival.whereNow") { onWhere() }
            case .between(let since):
                primary(FestivalNight.isStillOut(status, now: now) ? "Still out? Say where you are ›"
                                                                    : "Where are you now? ›",
                        symbol: "mappin.and.ellipse", id: "festival.whereNow") { onWhere() }
                    .accessibilityHint("Ended \(FestivalSchedule.timeLabel(since, offsetSeconds: pack.utcOffsetSeconds))")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .padding(.top, 6)
        .background(.bar)
    }

    private func primary(_ title: String, symbol: String, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).lineLimit(1)
        }
        .buttonStyle(SnappetWidePrimaryStyle())
        .accessibilityIdentifier(id)
    }

    private func nightLine(since: Date, kind: FestivalNight.StretchKind) -> some View {
        HStack {
            Text("\(kind.title) · \(FestivalSchedule.elapsedLabel(since: since, now: now))")
            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(SnappetColor.textSecondary)
    }

    private func autoMovedCard(_ open: FestivalAttendance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Moved you to your next starred set")
                .font(.caption)
                .foregroundStyle(SnappetColor.brand)
            Text("\(open.artist) · \(open.stage)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SnappetColor.ink)
            HStack(spacing: 8) {
                Button("Not there? Change") { onWhere() }
                    .font(.subheadline)
                    .foregroundStyle(SnappetColor.ink)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .pagerOutline()
                    .accessibilityIdentifier("festival.autoMoved.change")
                Button("Got it") { onConfirmAutoMove() }
                    .font(.subheadline)
                    .foregroundStyle(SnappetColor.brand)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .overlay(Capsule().strokeBorder(SnappetColor.brand, lineWidth: 1))
                    .contentShape(Capsule())
                    .accessibilityIdentifier("festival.autoMoved.ok")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md).strokeBorder(SnappetColor.brand))
    }
}

// MARK: - The Festival home card (prompt 232)

/// "Where am I", at the top of the Festival home: while a night is on — the festival, how long the
/// night's been on, live ♥, where you are and time left, with **Change where I am** and **Break**;
/// on a festival day with no night on — "<festival> is on today · Start the night". Renders nothing
/// otherwise. Self-contained: decodes its own pack and drives the shared `FestivalNightController`.
struct FestivalNightCard: View {
    let lineup: FestivalLineup

    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app

    /// Observed so the card re-renders on every claim / stretch change, wherever it happened.
    @Query private var attendance: [FestivalAttendance]
    @Query private var stretches: [FestivalNightStretch]
    @Query private var stars: [FestivalStar]
    @State private var pack: FestivalPack?
    @State private var showingWhere = false
    @State private var whereTitle = "Where are you now?"

    init(lineup: FestivalLineup) {
        self.lineup = lineup
        let packID = lineup.packID
        _attendance = Query(filter: #Predicate<FestivalAttendance> { $0.packID == packID })
        _stretches = Query(filter: #Predicate<FestivalNightStretch> { $0.packID == packID })
        _stars = Query(filter: #Predicate<FestivalStar> { $0.packID == packID })
    }

    var body: some View {
        // A real (zero-height) view even before the pack loads: an EMPTY list row is never
        // created, so its `.task` would never run and the card would never appear.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let pack {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    card(pack: pack, now: timeline.date)
                }
            }
        }
        .task(id: lineup.editsData) { pack = lineup.pack() }
        .sheet(isPresented: $showingWhere) {
            if let pack {
                let controller = controller(pack)
                FestivalWhereSheet(pack: pack, starred: Set(stars.map(\.setID)),
                                   currentSetID: controller.openAttendance?.setID,
                                   title: whereTitle, subtitle: nil,
                                   nightOn: controller.status().isOn,
                                   onPick: { apply($0, controller: controller) })
                    .presentationDetents([.large])
            }
        }
    }

    private func controller(_ pack: FestivalPack) -> FestivalNightController {
        FestivalNightController(lineup: lineup, pack: pack, context: context, app: app, core: core)
    }

    @ViewBuilder private func card(pack: FestivalPack, now: Date) -> some View {
        let controller = controller(pack)
        let status = controller.status()
        if status.isOn || festivalIsOn(pack, now: now) {
            VStack(alignment: .leading, spacing: 8) {
                header(status: status, controller: controller, now: now)
                switch status {
                case .off:
                    Text("\(lineup.name) is on today")
                        .font(.headline)
                        .foregroundStyle(SnappetColor.ink)
                    Button {
                        controller.startNight(now: .now)
                    } label: {
                        Label("Start the night", systemImage: "play.fill")
                    }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .accessibilityIdentifier("festival.home.startNight")
                case .atSet(let setID):
                    let set = pack.setsByID[setID]
                    Text("You're at").font(.caption).foregroundStyle(SnappetColor.brand)
                    Text(controller.openAttendance?.artist ?? set?.artist ?? "")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SnappetColor.ink)
                        .accessibilityIdentifier("festival.home.at")
                    if let set {
                        Text(endsLine(set, now: now))
                            .font(.caption)
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    actions(primary: "Change where I am", secondary: ("Break", "cup.and.saucer"),
                            controller: controller, secondaryAction: { controller.startStretch(.rest) })
                case .stretch(let kind, let since):
                    Text("\(kind.title) · \(FestivalSchedule.elapsedLabel(since: since, now: now))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(SnappetColor.ink)
                    actions(primary: kind == .rest ? "Back on the floor" : "I'm here now",
                            secondary: ("End the night", "moon"), controller: controller,
                            secondaryAction: { controller.endNight() })
                case .between:
                    Text(FestivalNight.isStillOut(status, now: now) ? "Still out?" : "Where are you now?")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SnappetColor.ink)
                    actions(primary: "Pick where", secondary: ("End the night", "moon"),
                            controller: controller, secondaryAction: { controller.endNight() })
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.lg)
                .strokeBorder(status.isOn ? SnappetColor.brand : SnappetColor.hairline))
            .onAppear { controller.reconcile() }
            .onChange(of: now) { _, _ in controller.reconcile() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("festival.home.night.\(lineup.packID)")
        }
    }

    private func header(status: FestivalNight.Status, controller: FestivalNightController,
                        now: Date) -> some View {
        HStack {
            if status.isOn, let session = controller.nightSession() {
                Text("\(lineup.name) · night on \(FestivalSchedule.elapsedLabel(since: session.startedAt, now: now))")
                    .monospacedDigit()
            } else {
                Text(lineup.name)
            }
            Spacer()
            if status.isOn, let bpm = app.liveWorkout.latestHR {
                Label("\(Int(bpm.rounded()))", systemImage: "heart.fill")
                    .foregroundStyle(SnappetColor.perfHard)
            }
        }
        .font(.caption)
        .foregroundStyle(SnappetColor.textSecondary)
        .lineLimit(1)
    }

    private func actions(primary: String, secondary: (String, String),
                         controller: FestivalNightController,
                         secondaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button {
                whereTitle = primary == "Change where I am" ? "Where are you now?" : "What's next?"
                showingWhere = true
            } label: {
                Text(primary)
            }
            .buttonStyle(SnappetWidePrimaryStyle())
            .accessibilityIdentifier("festival.home.where")
            Button(action: secondaryAction) {
                Label(secondary.0, systemImage: secondary.1)
                    .font(.system(size: 15))
                    .foregroundStyle(SnappetColor.ink)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .pagerOutline()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("festival.home.secondary")
        }
    }

    private func endsLine(_ set: FestivalSet, now: Date) -> String {
        let end = FestivalSchedule.timeLabel(set.end, offsetSeconds: pack?.utcOffsetSeconds ?? 0)
        guard now < set.end else { return "\(set.stage) · running past \(end)" }
        return "\(set.stage) · ends \(end) · \(FestivalSchedule.remainingLabel(set.end.timeIntervalSince(now)))"
    }

    /// A festival day's window contains now (rollover-aware — 01:00 still counts as tonight).
    private func festivalIsOn(_ pack: FestivalPack, now: Date) -> Bool {
        pack.day(containing: now) != nil
    }

    private func apply(_ choice: FestivalWhereSheet.Choice, controller: FestivalNightController) {
        switch choice {
        case .set(let set): controller.claim(set)
        case .stretch(let kind): controller.startStretch(kind)
        case .endNight: controller.endNight()
        }
    }
}
