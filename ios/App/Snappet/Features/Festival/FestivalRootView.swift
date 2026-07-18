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

    @State private var installer = FestivalLineupInstaller()
    @State private var showingBrowse = false
    @State private var showingScan = false
    /// A scanned/opened `snappet://festival/…` value awaiting the import-confirm (festival prompt 05).
    /// Fed from the shell's one-shot (`SuiteRouter.pendingFestivalImport`) and from an in-app scan.
    @State private var incoming: SharedLineup?

    var body: some View {
        Group {
            if lineups.isEmpty {
                FestivalEmptyStateView(installer: installer, onBrowse: { showingBrowse = true },
                                       onScan: { showingScan = true })
            } else {
                lineupList
            }
        }
        .navigationTitle("Festival")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBrowse) {
            FestivalCatalogBrowseView(installer: installer)
        }
        .sheet(isPresented: $showingScan) {
            FestivalScanView(onScan: { present($0) })
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

    /// Stage a decoded value for the import-confirm (from an in-app scan). Dismiss the scanner first.
    private func present(_ shared: SharedLineup) {
        showingScan = false
        incoming = shared
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
                }
        }
        .presentationDetents([.large])
    }
}
