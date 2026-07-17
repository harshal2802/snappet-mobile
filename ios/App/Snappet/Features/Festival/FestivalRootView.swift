import SwiftUI
import SwiftData

/// The Festival root — installed lineups, or the catalog empty state when there are none (wireframe
/// frames 2–3). Pushed into the App Library's `NavigationStack` (no stack of its own, per the
/// suite rule); the hosted-catalog browse is a sheet with its own stack. Tapping a lineup pushes
/// its day schedule.
struct FestivalRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Query(sort: \FestivalLineup.installedAt, order: .reverse) private var lineups: [FestivalLineup]

    @State private var installer = FestivalLineupInstaller()
    @State private var showingBrowse = false

    var body: some View {
        Group {
            if lineups.isEmpty {
                FestivalEmptyStateView(installer: installer, onBrowse: { showingBrowse = true })
            } else {
                lineupList
            }
        }
        .navigationTitle("Festival")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBrowse) {
            FestivalCatalogBrowseView(installer: installer)
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

    /// Remove a lineup and everything hanging off its `packID` (stars, attendance claims). The
    /// dance `WorkoutSession`s stay — they're the user's workout history, owned by the spine.
    private func deleteLineups(at offsets: IndexSet) {
        for index in offsets {
            let lineup = lineups[index]
            let packID = lineup.packID
            let stars = (try? context.fetch(FetchDescriptor<FestivalStar>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            stars.forEach { context.delete($0) }
            let attendance = (try? context.fetch(FetchDescriptor<FestivalAttendance>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            attendance.forEach { context.delete($0) }
            context.delete(lineup)
            core.log(module: FestivalModule.id, action: "remove",
                     summary: "Removed lineup: \(lineup.name)")
        }
        try? context.save()
    }
}
