import SwiftUI
import SwiftData

/// The Festival root — installed lineups, or the catalog empty state when there are none (wireframe
/// frames 2–3). Pushed into the App Library's `NavigationStack` (no stack of its own, per the
/// suite rule); the hosted-catalog browse is a sheet with its own stack. Tapping a lineup pushes
/// its day schedule.
struct FestivalRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \FestivalLineup.installedAt, order: .reverse) private var lineups: [FestivalLineup]
    /// Unfiltered — the getting-started state counts every star across every lineup (prompt 07).
    @Query private var allStars: [FestivalStar]

    // Guided getting-started (festival prompt 07). Two plain `@AppStorage` flags (NO SwiftData /
    // backup change — the prompt-04 lead-time precedent); the other three inputs are DERIVED.
    @AppStorage("festival.tourSeen") private var tourSeen = false
    @AppStorage("festival.gettingStartedDismissed") private var checklistDismissed = false
    /// Prompt 04's "reminders on" = notification authorization granted; read at the thin edge.
    @State private var remindersEnabled = false

    @State private var installer = FestivalLineupInstaller()
    @State private var showingBrowse = false
    @State private var showingScan = false
    @State private var showingPosterScan = false
    /// A poster-scanned draft awaiting the review editor (festival prompt 06).
    @State private var posterDraft: FestivalDraft?
    /// Holds the built draft while the capture sheet dismisses; promoted to `posterDraft` in the
    /// capture sheet's `onDismiss`. SwiftUI can't reliably dismiss one sheet and present another in the
    /// same state mutation, so the review editor is presented only AFTER the capture sheet is gone.
    @State private var pendingPosterDraft: FestivalDraft?
    /// A scanned/opened `snappet://festival/…` value awaiting the import-confirm (festival prompt 05).
    /// Fed from the shell's one-shot (`SuiteRouter.pendingFestivalImport`) and from an in-app scan.
    @State private var incoming: SharedLineup?
    /// Holds an in-app-scanned value while the scanner sheet dismisses; promoted to `incoming` in the
    /// scanner sheet's `onDismiss`. Same one-mutation two-sheet race as `pendingPosterDraft` — SwiftUI
    /// can't dismiss the scanner and present the import-confirm in one state mutation, so the confirm is
    /// presented only AFTER the scanner sheet is gone.
    @State private var pendingIncoming: SharedLineup?

    /// The pure onboarding decision — derived from the two flags + the live counts (prompt 07).
    private var onboarding: FestivalGettingStarted {
        FestivalGettingStarted(tourSeen: tourSeen, checklistDismissed: checklistDismissed,
                               lineupCount: lineups.count, starCount: allStars.count,
                               remindersEnabled: remindersEnabled)
    }

    var body: some View {
        Group {
            if onboarding.showTour {
                // The value tour rides once on first open, before the empty screen (frames 1–4).
                FestivalTourView(onFinish: { tourSeen = true })
            } else if lineups.isEmpty {
                if onboarding.checklist == .full {
                    // The guided checklist stands in for the blank empty state (frame 5).
                    FestivalSetupChecklistView(state: onboarding,
                                               onBrowse: { showingBrowse = true },
                                               onScanPoster: { showingPosterScan = true },
                                               onScan: { showingScan = true },
                                               onDismiss: { checklistDismissed = true })
                } else {
                    FestivalEmptyStateView(installer: installer, onBrowse: { showingBrowse = true },
                                           onScan: { showingScan = true },
                                           onScanPoster: { showingPosterScan = true })
                }
            } else {
                lineupList
            }
        }
        // Full-bleed the tour — its own "How it works" chrome is the only chrome while it shows.
        .toolbar(onboarding.showTour ? .hidden : .visible, for: .navigationBar)
        .navigationTitle("Festival")
        .navigationBarTitleDisplayMode(.inline)
        .task { remindersEnabled = await FestivalNotifications().authorizationGranted() }
        .sheet(isPresented: $showingBrowse) {
            FestivalCatalogBrowseView(installer: installer)
        }
        .sheet(isPresented: $showingScan, onDismiss: {
            // Present the import-confirm only once the scanner sheet has actually dismissed —
            // dismissing + presenting two sheets in one mutation drops the second presentation.
            if let shared = pendingIncoming {
                pendingIncoming = nil
                incoming = shared
            }
        }) {
            FestivalScanView(onScan: { present($0) })
        }
        .sheet(isPresented: $showingPosterScan, onDismiss: {
            // Present the review editor only once the capture sheet has actually dismissed —
            // dismissing + presenting two sheets in one mutation drops the second presentation.
            if let draft = pendingPosterDraft {
                pendingPosterDraft = nil
                posterDraft = draft
            }
        }) {
            FestivalPosterScanView(onDraft: { draft in
                pendingPosterDraft = draft
                showingPosterScan = false
            })
        }
        .sheet(item: $posterDraft) { draft in
            FestivalPosterDraftView(draft: draft, installer: installer,
                                    onInstalled: { pack in
                                        core.log(module: FestivalModule.id, action: "installPoster",
                                                 summary: "Built lineup from a poster: \(pack.name)",
                                                 metric: Double(pack.allSets.count))
                                    })
        }
        .sheet(item: $incoming) { shared in
            FestivalImportSheet(shared: shared,
                                installedPackIDs: Set(lineups.map(\.packID)),
                                onConfirm: { receive(shared) })
        }
        // Consume the shell's one-shot import intent (an external `onOpenURL` code, or an in-app scan
        // that routed through the shell): stage the import-confirm, then clear (self-clearing, the
        // `pendingKilterClimb` pattern — `initial: true` survives the cold-start window).
        .onChange(of: router.pendingFestivalImport, initial: true) { _, pending in
            if let pending { incoming = pending; router.pendingFestivalImport = nil }
        }
        .navigationDestination(for: FestivalLineup.self) { lineup in
            FestivalScheduleView(lineup: lineup)
        }
    }

    private var lineupList: some View {
        List {
            Section {
                ForEach(lineups) { lineup in
                    NavigationLink(value: lineup) {
                        lineupRow(lineup)
                    }
                    .accessibilityIdentifier("festival.lineup.\(lineup.packID)")
                }
                .onDelete(perform: deleteLineups)
            } header: {
                Text("Your festivals")
            } footer: {
                Text("Lineups live on this device and work offline. Reinstalling a festival "
                     + "picks up lineup revisions — your stars survive.")
            }

            Section {
                Button {
                    showingBrowse = true
                } label: {
                    Label("Get more lineups", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("festival.catalog.browse")
                Button {
                    showingPosterScan = true
                } label: {
                    Label("Scan a lineup poster", systemImage: "camera.viewfinder")
                }
                .accessibilityIdentifier("festival.poster.scan")
                Button {
                    showingScan = true
                } label: {
                    Label("Scan a friend's QR", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("festival.scan")
                if case .failed(let message) = installer.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("festival.catalog.error")
                }
            }
        }
    }

    private func lineupRow(_ lineup: FestivalLineup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.mic")
                .font(.title3)
                .foregroundStyle(SnappetColor.festival)
                .frame(width: 40, height: 40)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(lineup.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(FestivalBrowse.metaLine(startDate: lineup.startDate, endDate: lineup.endDate,
                                             stages: lineup.stageCount, sets: lineup.setCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Receiving a shared lineup / plan (festival prompt 05)

    /// Stage a decoded value for the import-confirm (from an in-app scan). Stash it and dismiss the
    /// scanner; the scanner sheet's `onDismiss` promotes it to `incoming` so the import-confirm presents
    /// only after the scanner is gone (SwiftUI can't dismiss one sheet and present another in one
    /// mutation — the poster-scan `pendingPosterDraft` race, generalized to the QR-import path).
    private func present(_ shared: SharedLineup) {
        pendingIncoming = shared
        showingScan = false
    }

    /// Run the confirmed import — the pure `SharedLineup.receiveAction` decides WHAT, this executes it
    /// against the store/installer. Never silent: only reached from the import-confirm CTA.
    private func receive(_ shared: SharedLineup) {
        switch shared.receiveAction(installedPackIDs: Set(lineups.map(\.packID))) {
        case .installLineup:
            if let pack = shared.carriedPack {
                installer.install(pack: pack, sourceLabel: "Shared code", into: context)
                logInstall(pack)
            }
        case .installPlan(let packID):
            // Install the carried subset as a lineup, then star every set it carried.
            if let pack = shared.carriedPack {
                installer.install(pack: pack, sourceLabel: "Shared plan", into: context)
                star(setIDs: pack.allSets.map(\.id), packID: packID)
                logInstall(pack)
            }
        case .applyPlan(let packID, let setIDs):
            star(setIDs: setIDs, packID: packID)
            core.log(module: FestivalModule.id, action: "importPlan",
                     summary: "Added \(setIDs.count) sets to \(shared.carriedPack?.name ?? packID)")
        case .fetchInstall(let packID, let host):
            // The install-link fallback: fetch the hosted pack once, then install (offline forever after).
            let entry = FestivalLineupEntry(id: packID, name: shared.title, location: "",
                                            startDate: "", endDate: "", file: "\(packID).fpack",
                                            url: nil, stages: 0, sets: 0, sizeBytes: nil, updatedAt: nil)
            Task {
                let provider = HostedFestivalPackProvider(entry: entry, baseURL: host)
                if let lineup = await installer.install(using: provider, entryID: packID, into: context) {
                    core.log(module: FestivalModule.id, action: "importLineup",
                             summary: "Installed \(lineup.name) from a shared link")
                }
            }
        }
    }

    /// Star the given content set-ids on `packID`, skipping any already starred (idempotent — a
    /// re-scan can't double-star). Content ids, so they match the installed lineup's sets exactly.
    private func star(setIDs: [UUID], packID: String) {
        let existing = Set(((try? context.fetch(FetchDescriptor<FestivalStar>(
            predicate: #Predicate { $0.packID == packID }))) ?? []).map(\.setID))
        for setID in setIDs where !existing.contains(setID) {
            context.insert(FestivalStar(packID: packID, setID: setID))
        }
        try? context.save()
    }

    private func logInstall(_ pack: FestivalPack) {
        core.log(module: FestivalModule.id, action: "importLineup",
                 summary: "Installed \(pack.name) from a shared code")
    }

    /// Remove a lineup and everything hanging off its `packID` (stars, attendance claims). The
    /// dance `WorkoutSession`s stay — they're the user's workout history, owned by the spine.
    private func deleteLineups(at offsets: IndexSet) {
        let notifications = FestivalNotifications()
        for index in offsets {
            let lineup = lineups[index]
            let packID = lineup.packID
            if let pack = lineup.pack() { notifications.clear(pack: pack) }
            let stars = (try? context.fetch(FetchDescriptor<FestivalStar>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            stars.forEach { context.delete($0) }
            let attendance = (try? context.fetch(FetchDescriptor<FestivalAttendance>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            attendance.forEach { context.delete($0) }
            let tags = (try? context.fetch(FetchDescriptor<FestivalClipTag>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            tags.forEach { context.delete($0) }
            context.delete(lineup)
            core.log(module: FestivalModule.id, action: "remove",
                     summary: "Removed lineup: \(lineup.name)")
        }
        try? context.save()
    }
}

/// A bare receive-only scanner (festival prompt 05): the "Scan a friend's QR" entry from the root /
/// empty state, when there's no lineup to share back. Reuses the shared `SnappetScannerView` +
/// `SharedLineup` decode; the host routes the decoded value to the import-confirm.
struct FestivalScanView: View {
    let onScan: (SharedLineup) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SnappetScannerView(
                prompt: "Point at a friend's Snappet lineup QR code.",
                foreignHint: "That isn't a Snappet lineup code.",
                decode: { SharedLineup(decoding: $0) },
                onScan: { decoded in onScan(decoded); dismiss() })
                .padding(.top, 8)
                .accessibilityIdentifier("festival.scanner")
                .navigationTitle("Scan a lineup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    // UI-test seam: the sim has no camera, so feed a canned decoded value through the
                    // real `onScan` path (identical to a live scan) to make the scan → import-confirm
                    // presentation a deterministic regression guard. Gated on the launch arg, so it never
                    // appears in the shipped app (the `-uiTestPosterFloorOnly` / seed-arg convention).
                    if ProcessInfo.processInfo.arguments.contains(Self.uiTestScanSampleArgument) {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Sample") {
                                if let shared = SharedLineup(decoding: Self.uiTestSampleCode) {
                                    onScan(shared); dismiss()
                                }
                            }
                            .accessibilityIdentifier("festival.scan.sample")
                        }
                    }
                }
        }
        .presentationDetents([.large])
    }

    /// Launch arg that reveals the canned-scan seam above (UI test only).
    static let uiTestScanSampleArgument = "-uiTestFestivalScanSample"
    /// A canned `snappet://festival/…` value the seam feeds through `onScan` (an install-link form —
    /// no full pack needed to exercise the presentation).
    static let uiTestSampleCode =
        "snappet://festival/install/uitest-shared?h=example.com&t=Shared%20lineup&k=0"
}
