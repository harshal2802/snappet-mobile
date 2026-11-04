import SwiftUI
import SwiftData

/// The installed festival's day schedule (wireframe frame 4): day tabs, stage-grouped set rows with
/// past / **NOW** / upcoming state, ★ stars (the plan), ⚠︎ clash marks, and the one CTA — **I'm
/// here** — which starts (or annotates) a dance-discipline `WorkoutSession` and opens the live
/// sheet. All derivation is the pure `FestivalSchedule`; this view renders values and owns the thin
/// SwiftData / live-services edge (the `WorkoutHomeView` lifecycle precedent).
struct FestivalScheduleView: View {
    let lineup: FestivalLineup

    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    @Environment(SuiteRouter.self) private var router

    @Query private var stars: [FestivalStar]
    @Query private var attendance: [FestivalAttendance]
    /// Break / walking / arriving stretches (prompt 232) — observed so the bar follows them.
    @Query private var stretches: [FestivalNightStretch]
    /// Unfiltered — the getting-started banner counts lineups/stars across the whole module (prompt 07).
    @Query private var allLineups: [FestivalLineup]
    @Query private var allStars: [FestivalStar]

    // Guided getting-started banner (festival prompt 07) — the two plain `@AppStorage` flags the root
    // owns; the banner reads them so it collapses/dismisses consistently with the checklist.
    @AppStorage("festival.tourSeen") private var tourSeen = false
    @AppStorage("festival.gettingStartedDismissed") private var checklistDismissed = false
    @State private var remindersEnabled = false

    @State private var pack: FestivalPack?
    @State private var selectedDay: String?
    @State private var showingLive = false
    @State private var showingForYou = false
    /// The dance session the open attendance rides — resolved when the sheet opens/claims.
    @State private var liveSession: WorkoutSession?
    /// "Where are you now?" / "What's next?" (prompt 232) + its copy.
    @State private var showingWhere = false
    @State private var whereTitle = "Where are you now?"
    @State private var whereSubtitle: String?
    /// Set by the live sheet's End this set / Switch, presented once that sheet has gone (the
    /// one-mutation two-sheet race — stash + promote in `onDismiss`).
    @State private var pendingWhere = false
    @State private var showingEditLineup = false
    /// Tag review sheet (festival prompt 03). The recap is a value-typed push (`FestivalRecapRoute`)
    /// — the `WeeklyReelRoute` pattern; an `isPresented` destination on this often-invalidated
    /// view (30 s TimelineView + @Query writes) failed to push under XCUITest.
    @State private var showingReview = false
    /// The share sheet (festival prompt 05, wireframe frame 12) + which tab it opens on.
    @State private var showingShare = false
    @State private var shareStart: FestivalShareView.Start = .plan

    @AppStorage(FestivalNotifications.leadStorageKey)
    private var leadMinutes = FestivalNotifications.defaultLeadMinutes
    private let notifications = FestivalNotifications()

    init(lineup: FestivalLineup) {
        self.lineup = lineup
        let packID = lineup.packID
        _stars = Query(filter: #Predicate<FestivalStar> { $0.packID == packID })
        _attendance = Query(filter: #Predicate<FestivalAttendance> { $0.packID == packID })
        _stretches = Query(filter: #Predicate<FestivalNightStretch> { $0.packID == packID })
    }

    private func night(_ pack: FestivalPack) -> FestivalNightController {
        FestivalNightController(lineup: lineup, pack: pack, context: context, app: app, core: core)
    }

    private var starredIDs: Set<UUID> { Set(stars.map(\.setID)) }
    private var openAttendance: FestivalAttendance? { attendance.first { $0.isOpen } }

    /// The pure onboarding decision (prompt 07) — the schedule shows the collapsed banner while it
    /// resolves to `.banner`.
    private var onboarding: FestivalGettingStarted {
        FestivalGettingStarted(tourSeen: tourSeen, checklistDismissed: checklistDismissed,
                               lineupCount: allLineups.count, starCount: allStars.count,
                               remindersEnabled: remindersEnabled)
    }

    var body: some View {
        Group {
            if let pack {
                // 30 s cadence keeps NOW/countdowns honest without per-second re-renders of the list.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    schedule(pack: pack, now: timeline.date)
                }
            } else {
                ContentUnavailableView("This lineup couldn't be read",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Remove it and install the festival again."))
            }
        }
        .navigationTitle(lineup.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Prompt 04's For-You entry.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingForYou = true
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SnappetColor.festival)
                }
                .accessibilityLabel("For you")
                .accessibilityIdentifier("festival.forYou")
            }
            // Prompt 03's two payoff entries: the tag-review sheet and the recap push.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingReview = true
                } label: {
                    Label("Review tags", systemImage: "sparkles.rectangle.stack")
                }
                .accessibilityIdentifier("festival.reviewTags")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: FestivalRecapRoute()) {
                    Label("Recap", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("festival.recap")
            }
            // Prompt 05's share/scan entry (wireframe frame 12's ⋯ menu).
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Prompt 232: fix times, add / remove sets, delay a stage or the whole day.
                    Button {
                        showingEditLineup = true
                    } label: { Label("Edit lineup", systemImage: "pencil") }
                    .accessibilityIdentifier("festival.editLineup")
                    Button {
                        shareStart = .plan; showingShare = true
                    } label: { Label("Share my plan", systemImage: "star") }
                    Button {
                        shareStart = .lineup; showingShare = true
                    } label: { Label("Share this lineup", systemImage: "music.mic") }
                    Button {
                        shareStart = .scan; showingShare = true
                    } label: { Label("Scan a code", systemImage: "qrcode.viewfinder") }
                } label: {
                    Label("Share", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("festival.share.menu")
            }
        }
        .task {
            // Keep the getting-started banner's reminders step honest (prompt 07 / 04).
            remindersEnabled = await notifications.authorizationGranted()
            guard pack == nil else { return }
            pack = lineup.pack()
            if let pack { reconcileNight(pack) }
            if let pack, selectedDay == nil {
                selectedDay = FestivalSchedule.defaultDayDate(in: pack, now: .now)
            }
            // Bring pending reminders in line with the stored plan (a star toggled last session, or
            // this lineup was reinstalled). Silent — no permission prompt here (festival prompt 04).
            if let pack { rescheduleReminders(pack: pack) }
            // One silent tagging pass on arrival (festival prompt 03): retroactive — everything
            // already danced/filmed tags itself the first time this screen opens after a night.
            if let pack {
                await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                              mediaService: app.sessionMedia)
            }
        }
        // Re-read authorization after the For-You sheet (where reminders are turned on) closes, so
        // the getting-started banner's step-3 ticks and it retires the moment all three are done.
        .onChange(of: showingForYou) { _, showing in
            if !showing { Task { remindersEnabled = await notifications.authorizationGranted() } }
        }
        // A set row pushes its detail (frame 6); recap's artist rows reuse the same registration.
        .navigationDestination(for: FestivalSet.self) { set in
            if let pack {
                FestivalSetDetailView(lineup: lineup, pack: pack, set: set)
            }
        }
        .navigationDestination(for: FestivalRecapRoute.self) { _ in
            if let pack {
                FestivalRecapView(lineup: lineup, pack: pack)
            }
        }
        .sheet(isPresented: $showingReview) {
            if let pack {
                FestivalTagReviewView(lineup: lineup, pack: pack, initialDay: selectedDay)
                    .presentationDetents([.large])
            }
        }
        // Edits change set times — re-read the pack and re-plan reminders (prompt 232).
        .onChange(of: lineup.editsData) { _, _ in
            pack = lineup.pack()
            if let pack { rescheduleReminders(pack: pack) }
        }
        .sheet(isPresented: $showingLive, onDismiss: {
            if pendingWhere { pendingWhere = false; showingWhere = true }
        }) {
            if let pack, let open = openAttendance {
                FestivalLiveSheet(pack: pack,
                                  attendance: open,
                                  session: liveSession,
                                  onSwitch: {
                                      whereTitle = "Where are you now?"
                                      whereSubtitle = nil
                                      pendingWhere = true
                                  },
                                  onEndSet: {
                                      let artist = open.artist
                                      night(pack).endSet()
                                      whereTitle = "What's next?"
                                      whereSubtitle = "You left \(artist)"
                                      pendingWhere = true
                                  },
                                  onEnd: { endNight(in: pack) })
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showingWhere) {
            if let pack {
                FestivalWhereSheet(pack: pack, starred: starredIDs,
                                   currentSetID: openAttendance?.setID,
                                   title: whereTitle, subtitle: whereSubtitle,
                                   nightOn: night(pack).status().isOn,
                                   onPick: { pick($0, in: pack) })
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showingEditLineup) {
            FestivalLineupEditView(lineup: lineup)
        }
        .sheet(isPresented: $showingForYou) {
            if let pack {
                FestivalForYouView(lineup: lineup, pack: pack)
            }
        }
        .sheet(isPresented: $showingShare) {
            if let pack {
                FestivalShareView(pack: pack, lineupName: lineup.name, starredSetIDs: starredIDs,
                                  start: shareStart,
                                  // An in-app scan routes through the shell one-shot: pop to the
                                  // Festival root, which owns the import-confirm + installer.
                                  onScan: { shared in
                                      router.pendingFestivalImport = shared
                                      router.open(module: FestivalModule.id)
                                  })
            }
        }
    }

    // MARK: - Schedule

    private func schedule(pack: FestivalPack, now: Date) -> some View {
        VStack(spacing: 0) {
            if onboarding.checklist == .banner {
                FestivalGettingStartedBanner(
                    state: onboarding,
                    onTapNudge: { step in
                        // Reminders is the only step not reachable right here on the schedule; the
                        // For-You sheet owns the lead-time control + the auth request (prompt 04).
                        if step == .enableReminders { showingForYou = true }
                    },
                    onDismiss: { checklistDismissed = true })
                    .padding(.horizontal).padding(.top, 8)
            }
            dayTabs(pack: pack)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(FestivalSchedule.stageGroups(for: selectedDay ?? "", in: pack,
                                                         starred: starredIDs, now: now)) { group in
                        stageSection(group, pack: pack)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            FestivalNightBar(status: nightStatus(pack),
                             pack: pack,
                             liveSet: FestivalSchedule.liveSet(in: pack, starred: starredIDs, now: now),
                             openAttendance: openAttendance,
                             now: now,
                             onOpenLive: { if let open = openAttendance { reopenLive(open, in: pack) } },
                             onClaim: { set in
                                 let controller = night(pack)
                                 controller.claim(set)
                                 if let open = controller.openAttendance { reopenLive(open, in: pack) }
                             },
                             onStartNight: { night(pack).startNight() },
                             onWhere: { askWhere(subtitle: nil) },
                             onConfirmAutoMove: { night(pack).confirmAutoMove() })
        }
        // The Halloween fix: every tick, a claim whose set has ended moves on or asks.
        .onChange(of: now) { _, _ in reconcileNight(pack) }
    }

    private func dayTabs(pack: FestivalPack) -> some View {
        HStack(spacing: 8) {
            ForEach(FestivalSchedule.dayTabs(for: pack)) { tab in
                let on = tab.date == selectedDay
                Button {
                    selectedDay = tab.date
                } label: {
                    VStack(spacing: 1) {
                        Text(tab.weekday).font(.caption2.weight(.bold))
                            .foregroundStyle(on ? .white : SnappetColor.textSecondary)
                        Text(tab.dayNumber).font(.headline)
                            .foregroundStyle(on ? .white : SnappetColor.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? AnyShapeStyle(SnappetColor.festival)
                                   : AnyShapeStyle(SnappetColor.surfaceMuted),
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("festival.day.\(tab.date)")
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func stageSection(_ group: FestivalSchedule.StageGroup, pack: FestivalPack) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.stage.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.textSecondary)
                .kerning(1)
            ForEach(group.rows) { row in
                setRow(row, pack: pack)
            }
        }
    }

    /// One set row. NOT collapsed into a single accessibility element and no identifier on the
    /// container — a container id flattens the child ★ button out of the XCUITest tree (the
    /// highlights-P5 gotcha); the star carries its own id instead.
    private func setRow(_ row: FestivalSchedule.Row, pack: FestivalPack) -> some View {
        HStack(spacing: 10) {
            // The time/artist area pushes SET DETAIL (frame 6, prompt 03) — a NavigationLink
            // around just this area, NOT the whole row, so the ★ button beside it keeps its own
            // hit target (and its own XCUITest id — the container-id gotcha).
            NavigationLink(value: row.set) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(FestivalSchedule.timeLabel(row.set.start, offsetSeconds: pack.utcOffsetSeconds))
                        Text(FestivalSchedule.timeLabel(row.set.end, offsetSeconds: pack.utcOffsetSeconds))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(width: 44, alignment: .leading)

                    Text(row.set.artist)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(row.state == .past ? SnappetColor.textSecondary : SnappetColor.ink)

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("festival.set.\(row.set.artist)")

            badges(for: row)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: SnappetRadius.md)
                .fill(row.isNow ? SnappetColor.festival.opacity(0.14) : Color.clear)
                .background(SnappetColor.surface,
                            in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SnappetRadius.md)
                .strokeBorder(row.isNow ? SnappetColor.festival : SnappetColor.hairline,
                              lineWidth: row.isNow ? 1.5 : 1)
        )
    }

    @ViewBuilder private func badges(for row: FestivalSchedule.Row) -> some View {
        if case .now(let remaining) = row.state {
            Text("NOW · \(FestivalSchedule.remainingLabel(remaining))")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(SnappetColor.festival, in: Capsule())
                .foregroundStyle(.white)
        } else if case .upcoming(let startsIn) = row.state,
                  let label = FestivalSchedule.startsInLabel(startsIn) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SnappetColor.textSecondary)
        }
        if row.clashing {
            Text("⚠︎ clash")
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.perfModerate)
                .accessibilityIdentifier("festival.clash.\(row.set.artist)")
        }
        Button {
            toggleStar(row.set)
        } label: {
            Image(systemName: row.starred ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(row.starred ? SnappetColor.festival : SnappetColor.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.starred ? "Unstar \(row.set.artist)" : "Star \(row.set.artist)")
        .accessibilityIdentifier("festival.star.\(row.set.artist)")
    }

    // MARK: - Stars

    private func toggleStar(_ set: FestivalSet) {
        let adding = !stars.contains { $0.setID == set.id }
        if let existing = stars.first(where: { $0.setID == set.id }) {
            context.delete(existing)
        } else {
            context.insert(FestivalStar(packID: lineup.packID, setID: set.id))
            core.log(module: FestivalModule.id, action: "star",
                     summary: "Starred \(set.artist) at \(lineup.name)")
        }
        try? context.save()

        guard let pack else { return }
        let newStarred = adding ? starredIDs.union([set.id]) : starredIDs.subtracting([set.id])
        // Surface a clash to the lock screen the moment the new star overlaps an existing one
        // (frame 7's "Two stars clash at 23:30"). Only when adding — unstarring can only clear a
        // clash. The in-app ⚠︎ marks (prompt 02) already flag both rows.
        if adding, let clash = FestivalPlan(starredSetIDs: newStarred)
            .clashes(in: pack).first(where: { $0.first.id == set.id || $0.second.id == set.id }) {
            notifications.postClashAlert(clash, pack: pack)
        }
        rescheduleReminders(pack: pack, starred: newStarred)
    }

    /// Bring pending local reminders in line with the current (or just-changed) plan. Silent — the
    /// permission prompt is owned by the For-You sheet, a deliberate surface.
    private func rescheduleReminders(pack: FestivalPack, starred: Set<UUID>? = nil) {
        notifications.reschedule(plan: FestivalPlan(starredSetIDs: starred ?? starredIDs),
                                 pack: pack, leadMinutes: leadMinutes)
    }

    // MARK: - The night (prompt 232 — all through `FestivalNightController`)

    /// Re-derived on every render; the `@Query`s above make it follow claims and stretches.
    private func nightStatus(_ pack: FestivalPack) -> FestivalNight.Status {
        _ = attendance.count + stretches.count
        return night(pack).status()
    }

    /// Bring the claim up to date with the clock; when the night is now asking, open the picker
    /// (only if nothing else is presented — the bar's "Where are you now?" covers the rest).
    private func reconcileNight(_ pack: FestivalPack) {
        let wasAsking: Bool = { if case .between = night(pack).status() { return true }; return false }()
        let ended = openAttendance.flatMap { pack.setsByID[$0.setID] }
        let asking = night(pack).reconcile()
        if asking, !wasAsking, !showingLive, !showingWhere, !showingReview, !showingShare,
           !showingForYou, !showingEditLineup {
            askWhere(subtitle: ended.map {
                "\($0.artist) ended at \(FestivalSchedule.timeLabel($0.end, offsetSeconds: pack.utcOffsetSeconds))"
            })
        }
    }

    private func askWhere(subtitle: String?) {
        whereTitle = "Where are you now?"
        whereSubtitle = subtitle
        showingWhere = true
    }

    private func pick(_ choice: FestivalWhereSheet.Choice, in pack: FestivalPack) {
        switch choice {
        case .set(let set): night(pack).claim(set)
        case .stretch(let kind): night(pack).startStretch(kind)
        case .endNight: endNight(in: pack)
        }
    }

    /// Re-open the live sheet for an existing claim (including after a relaunch: re-resolve the
    /// session and restart HR/Live Activity if nothing is streaming — the `resume` precedent).
    private func reopenLive(_ open: FestivalAttendance, in pack: FestivalPack) {
        let controller = night(pack)
        liveSession = controller.session(id: open.sessionID)
        if let session = liveSession {
            controller.resumeLiveServicesIfNeeded(for: session, label: open.artist)
        }
        showingLive = true
    }

    private func endNight(in pack: FestivalPack) {
        showingLive = false
        night(pack).endNight()
        liveSession = nil
    }
}
