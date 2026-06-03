import SwiftUI
import SwiftData
import Charts
import UIKit

/// A single climb: the holds rendered on the board, an angle selector (difficulty is per-angle),
/// grade / quality / ascents for that angle, logging (Flash / Sent / Project / Attempt), a Saved
/// toggle, a beta-video link, and — when a board is connected over BLE — illumination (Phase 2).
struct KilterClimbDetailView: View {
    let uuid: String
    /// Created once in `KilterRootView` and passed down (Observation tracks property access in
    /// `body` regardless of how the instance arrives — more robust than `@Environment` across a
    /// pushed `navigationDestination`).
    let board: KilterBoardController
    let sessions: KilterSessionManager

    @Environment(SnappetCore.self) private var core
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var favorites: [KilterFavorite]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.angle") private var sharedAngle: Int = 40
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    @State private var climb: KilterClimb?
    @State private var stats: [KilterClimbStat] = []
    @State private var holds: [KilterHold] = []
    @State private var geometry: KilterBoardGeometry = .empty
    @State private var betaLinks: [String] = []
    @State private var selectedAngle: Int = 40
    @State private var logConfirmation: String?

    private var currentStat: KilterClimbStat? { stats.first { $0.angle == selectedAngle } }
    private var isFavorite: Bool { favorites.contains { $0.climbUUID == uuid } }

    var body: some View {
        Group {
            if let climb {
                ScrollView { content(climb) }
            } else {
                ContentUnavailableView("Climb unavailable", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(climb?.name ?? "Climb")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { toggleFavorite() } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityIdentifier("kilter.favorite")
                .accessibilityLabel(isFavorite ? "Remove from saved" : "Save climb")
            }
        }
        .task { load() }
    }

    @ViewBuilder private func content(_ climb: KilterClimb) -> some View {
        VStack(spacing: 20) {
            KilterBoardView(geometry: geometry, holds: holds)
                .frame(maxHeight: 380)
                .padding(.horizontal)

            roleLegend
            anglePicker
            statRow
            metaRow
            logButtons
            gradeChart
            illuminateSection
            if let link = betaLinks.first, let url = URL(string: link) {
                Link(destination: url) {
                    Label("Beta video", systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("kilter.beta")
            }
            Text("Set by \(climb.setter)").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical)
    }

    private var roleLegend: some View {
        HStack(spacing: 16) {
            legendDot("00DD00", "Start")
            legendDot("00FFFF", "Middle")
            legendDot("FF00FF", "Finish")
            legendDot("FFA500", "Foot")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func legendDot(_ hex: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().stroke(Color(hex: hex), lineWidth: 2).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var anglePicker: some View {
        Menu {
            Picker("Angle", selection: $selectedAngle) {
                ForEach(stats) { Text("\($0.angle)°  ·  \(catalog.gradeLabel($0.difficulty))").tag($0.angle) }
            }
        } label: {
            Label("\(selectedAngle)°", systemImage: "angle")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .accessibilityIdentifier("kilter.angle")
        .onChange(of: selectedAngle) { _, new in sharedAngle = new }
    }

    private var statRow: some View {
        HStack {
            stat("Grade", currentStat.map { kilterDisplayGrade(catalog.gradeLabel($0.difficulty), gradeFormat) } ?? "—")
                .accessibilityIdentifier("kilter.grade")
            Divider().frame(height: 32)
            VStack(spacing: 2) {
                KilterStars(quality: currentStat?.quality ?? 0)
                Text("Quality").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Divider().frame(height: 32)
            stat("Ascents", "\(currentStat?.ascents ?? 0)")
        }
        .padding(.horizontal)
    }

    /// Benchmark ("Classic") badge + first-ascensionist, when the catalog has them for this angle.
    @ViewBuilder private var metaRow: some View {
        let isClassic = currentStat?.benchmarkDifficulty != nil
        let fa = currentStat?.faUsername ?? ""
        if isClassic || !fa.isEmpty {
            HStack(spacing: 10) {
                if isClassic {
                    Label("Classic", systemImage: "rosette")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(SnappetColor.moduleAccent("kilter").opacity(0.18), in: Capsule())
                        .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                }
                if !fa.isEmpty {
                    Label("FA \(fa)", systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
    }

    /// How the grade changes across board angles — the climb's signature. The selected angle is
    /// highlighted in the Kilter accent; tap a bar to switch angle.
    @ViewBuilder private var gradeChart: some View {
        if stats.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grade by angle").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Chart(stats) { s in
                    BarMark(x: .value("Angle", "\(s.angle)°"), y: .value("Difficulty", s.difficulty))
                        .foregroundStyle(s.angle == selectedAngle
                                         ? SnappetColor.moduleAccent("kilter") : Color.gray.opacity(0.35))
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .chartYScale(domain: chartYDomain)
                .frame(height: 110)
                .animation(.snappy, value: selectedAngle)
            }
            .padding(.horizontal)
        }
    }

    /// Tighten the chart's y-range around the climb's grades so small differences are visible.
    private var chartYDomain: ClosedRange<Double> {
        let ds = stats.map(\.difficulty)
        let lo = (ds.min() ?? 0) - 1, hi = (ds.max() ?? 1) + 1
        return lo...max(hi, lo + 1)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var logButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                logButton(.flash, "bolt.fill")
                logButton(.sent, "checkmark")
            }
            HStack(spacing: 10) {
                logButton(.project, "target")
                logButton(.attempt, "arrow.uturn.up")
            }
            if let logConfirmation {
                Label(logConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: logConfirmation)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.green.opacity(0.14), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityIdentifier("kilter.logConfirmation")
            }
        }
        .padding(.horizontal)
    }

    private func logButton(_ status: KilterAscentStatus, _ image: String) -> some View {
        Button { log(status) } label: {
            Label(status.label, systemImage: image).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(status.isSend ? .green : .orange)
        .accessibilityIdentifier("kilter.log.\(status.rawValue)")
    }

    @ViewBuilder private var illuminateSection: some View {
        // Simulators / devices with no BLE radio never show the section — there's nothing to connect to.
        if board.state != .unsupported {
            VStack(spacing: 8) {
                switch board.state {
                case .connected:
                    primaryButton("Light up this climb", systemImage: "lightbulb.fill") {
                        board.illuminate(holds)
                    }
                    Button("Disconnect board") { board.disconnect() }
                        .font(.caption)
                        .accessibilityIdentifier("kilter.board.disconnect")

                case .scanning, .connecting:
                    busyRow(board.state == .scanning ? "Searching for your board…" : "Connecting…")
                    Button("Cancel") { board.cancel() }
                        .font(.caption)
                        .accessibilityIdentifier("kilter.board.cancel")

                case .failed(let message):
                    statusNote(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    primaryButton("Try again", systemImage: "arrow.clockwise") { board.connect() }

                case .bluetoothOff:
                    statusNote("Bluetooth is off. Turn it on in Control Center or Settings to connect your board.",
                               systemImage: "wifi.slash", tint: .secondary)

                case .unauthorized:
                    statusNote("Snappet needs Bluetooth access to connect to your board.",
                               systemImage: "lock.fill", tint: .secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.caption)

                default:   // .idle
                    primaryButton("Connect board", systemImage: "antenna.radiowaves.left.and.right") {
                        board.connect()
                    }
                }
            }
            .padding(.horizontal)
            .animation(.snappy, value: board.state)
            .onAppear { wireSessionCapture() }
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("kilter.illuminate")
    }

    /// In-flight row: a spinner + status text, framed like the buttons it replaces.
    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("kilter.board.connecting")
    }

    private func statusNote(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    // MARK: - Actions

    private func load() {
        guard let c = catalog.climb(uuid) else { return }
        climb = c
        stats = catalog.stats(uuid)
        holds = catalog.holds(for: c)
        geometry = catalog.boardGeometry(forLayout: c.layoutId)
        betaLinks = catalog.betaLinks(uuid)
        // Prefer the shared angle if it has stats; otherwise the most-climbed angle.
        if stats.contains(where: { $0.angle == sharedAngle }) {
            selectedAngle = sharedAngle
        } else {
            selectedAngle = stats.max { $0.ascents < $1.ascents }?.angle ?? sharedAngle
        }
    }

    private func log(_ status: KilterAscentStatus) {
        guard let climb, let stat = currentStat else { return }
        let grade = catalog.gradeLabel(stat.difficulty)
        modelContext.insert(KilterLogEntry(
            climbUUID: climb.uuid, climbName: climb.name, angle: selectedAngle,
            difficulty: stat.difficulty, gradeLabel: grade, status: status,
            sessionId: sessions.currentId))
        try? modelContext.save()
        core.log(module: "kilter", action: "log-\(status.rawValue)",
                 summary: "\(status.label) \(climb.name) (\(grade) @\(selectedAngle)°)",
                 metric: stat.difficulty)
        withAnimation(.snappy) {
            logConfirmation = "Logged \(status.label.lowercased()) · \(grade)"
        }
    }

    private func toggleFavorite() {
        if let existing = favorites.first(where: { $0.climbUUID == uuid }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(KilterFavorite(climbUUID: uuid))
        }
        try? modelContext.save()
    }

    /// Open a board session on connect and close it on disconnect, so logs made while connected are
    /// grouped under one session in History (Phase 2).
    private func wireSessionCapture() {
        board.onConnectionChange = { connected in
            if connected {
                sessions.start(angle: selectedAngle, source: "ble", in: modelContext)
            } else {
                sessions.end(in: modelContext)
            }
        }
    }
}
