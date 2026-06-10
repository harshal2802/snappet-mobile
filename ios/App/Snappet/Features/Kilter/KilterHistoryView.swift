import SwiftUI
import SwiftData

/// Your Kilter history: a summary, a grade pyramid (sends per grade), board sessions
/// (auto-captured while connected over BLE — Phase 2), and the full ascent log, newest first.
/// Pushed onto the App Library's shared NavigationStack by `KilterRootView`.
struct KilterHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Query(sort: \KilterLogEntry.date, order: .reverse) private var entries: [KilterLogEntry]
    @Query(sort: \KilterSession.startedAt, order: .reverse) private var allSessions: [KilterSession]

    @State private var pendingDeleteEntryOffsets: IndexSet?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "figure.climbing",
                    description: Text("Climbs you log appear here."))
            } else {
                List {
                    summarySection
                    pyramidSection
                    if !sessions.isEmpty { sessionsSection }
                    ascentsSection
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear all", role: .destructive) { clearAll() }
                        .accessibilityIdentifier("kilter.history.clear")
                }
            }
        }
        .confirmationDialog(
            "Delete this ascent?",
            isPresented: Binding(
                get: { pendingDeleteEntryOffsets != nil },
                set: { if !$0 { pendingDeleteEntryOffsets = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeleteEntryOffsets { deleteEntries(at: offsets) }
                pendingDeleteEntryOffsets = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteEntryOffsets = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            HStack {
                summaryStat("Sends", "\(sends.count)")
                Divider().frame(height: 36)
                summaryStat("This month", "\(sendsThisMonth)")
                Divider().frame(height: 36)
                summaryStat("Hardest", hardestSend ?? "—")
            }
        }
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var pyramidSection: some View {
        Section("Grade pyramid") {
            if pyramid.isEmpty {
                Text("Log a send to build your pyramid.").font(.caption).foregroundStyle(.secondary)
            } else {
                let maxCount = pyramid.map(\.count).max() ?? 1
                ForEach(pyramid, id: \.label) { row in
                    HStack {
                        Text(row.label).font(.caption.monospacedDigit()).frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(.tint)
                                .frame(width: max(8, geo.size.width * CGFloat(row.count) / CGFloat(maxCount)))
                        }
                        .frame(height: 14)
                        Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        Section("Sessions") {
            ForEach(sessions) { session in
                let logs = entries.filter { $0.sessionId == session.id }
                NavigationLink(value: KilterSessionRoute(id: session.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.startedAt, format: .dateTime.weekday().day().month()).font(.headline)
                            Text("· \(session.angle)°").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            if session.isActive {
                                Label("Live", systemImage: "record.circle")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                                    .symbolEffect(.pulse, options: .repeating)
                            }
                            if !session.hrSeries.isEmpty {
                                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                            }
                            Text(session.source == "ble" ? "BLE" : "Manual")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(session.source == "ble" ? Color.green.opacity(0.2) : Color(.tertiarySystemBackground),
                                            in: Capsule())
                        }
                        if session.isActive {
                            HStack(spacing: 4) {
                                Text("\(logs.count) climb\(logs.count == 1 ? "" : "s") ·")
                                Text(session.startedAt, style: .timer).monospacedDigit()
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(logs.filter { $0.status.isSend }.count) sent · "
                                 + "\(logs.filter { $0.status == .project }.count) proj"
                                 + durationText(session))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("kilter.sessionRow")
                .swipeActions(edge: .trailing) {
                    if session.isActive {
                        Button("End") { app.kilterSessions.end(sessionID: session.id, in: modelContext) }
                            .tint(.red)
                            .accessibilityIdentifier("kilter.session.endFromHistory")
                    }
                }
            }
        }
    }

    private var ascentsSection: some View {
        Section("Ascents") {
            ForEach(entries) { entry in
                KilterAscentRow(entry: entry).accessibilityIdentifier("kilter.historyRow")
            }
            .onDelete { pendingDeleteEntryOffsets = $0 }
        }
    }

    // MARK: - Derived data

    private var sends: [KilterLogEntry] { entries.filter { $0.status.isSend } }

    private var sendsThisMonth: Int {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        return sends.filter { $0.date >= start }.count
    }

    private var hardestSend: String? {
        sends.max { $0.difficulty < $1.difficulty }?.gradeLabel
    }

    /// Sends per grade, ordered easiest → hardest (by the difficulty snapshot).
    private var pyramid: [(label: String, count: Int, difficulty: Double)] {
        var byLabel: [String: (count: Int, difficulty: Double)] = [:]
        for send in sends {
            let prior = byLabel[send.gradeLabel]
            byLabel[send.gradeLabel] = (count: (prior?.count ?? 0) + 1, difficulty: send.difficulty)
        }
        return byLabel.map { ($0.key, $0.value.count, $0.value.difficulty) }
            .sorted { $0.difficulty < $1.difficulty }
    }

    /// Sessions with logged entries, plus any **open** session — so a live/recovered session is always
    /// visible and endable here (the recovery surface of last resort), even before its first log.
    private var sessions: [KilterSession] {
        let used = Set(entries.compactMap(\.sessionId))
        return allSessions.filter { used.contains($0.id) || $0.isActive }
    }

    private func durationText(_ session: KilterSession) -> String {
        guard let end = session.endedAt else { return "" }
        let minutes = Int(end.timeIntervalSince(session.startedAt) / 60)
        return minutes > 0 ? " · \(minutes) min" : ""
    }

    // MARK: - Mutations

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(entries[index]) }
        try? modelContext.save()
    }

    private func clearAll() {
        // Never delete the in-flight session out from under the live bar — clear everything else.
        let activeID = allSessions.first { $0.isActive }?.id
        for entry in entries where entry.sessionId != activeID { modelContext.delete(entry) }
        for session in allSessions where !session.isActive { modelContext.delete(session) }
        try? modelContext.save()
    }
}

/// One ascent row: status pill + climb name on top, grade · angle · date below.
private struct KilterAscentRow: View {
    let entry: KilterLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.status.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(statusColor.opacity(0.22), in: Capsule())
                    .foregroundStyle(statusColor)
                Text(entry.climbName).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
            }
            HStack {
                Text("\(entry.gradeLabel) · \(entry.angle)°").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .flash, .sent: return .green
        case .project: return .orange
        case .attempt: return .secondary
        }
    }
}
