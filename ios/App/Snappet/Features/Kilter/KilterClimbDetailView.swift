import SwiftUI
import SwiftData
import Charts
import UIKit

/// A single climb: the holds rendered on the board, an angle selector (difficulty is per-angle),
/// grade / quality / ascents for that angle, logging (Flash / Sent / Project / Attempt), a Saved
/// toggle, a beta-video link, and — when a board is connected over BLE — illumination (Phase 2).
struct KilterClimbDetailView: View {
    /// The climb to open. Seeds `currentUUID`; swiping moves `currentUUID` through `siblings`.
    let uuid: String
    /// The ordered uuids of the list the user was browsing, so they can swipe left/right between
    /// climbs without backing out. Empty (or a single entry) disables sibling navigation.
    let siblings: [String]
    /// Created once in `KilterRootView` and passed down (Observation tracks property access in
    /// `body` regardless of how the instance arrives — more robust than `@Environment` across a
    /// pushed `navigationDestination`).
    let board: KilterBoardController
    let sessions: KilterSessionManager

    init(uuid: String, siblings: [String] = [], board: KilterBoardController, sessions: KilterSessionManager) {
        self.uuid = uuid
        self.siblings = siblings
        self.board = board
        self.sessions = sessions
        _currentUUID = State(initialValue: uuid)
    }

    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var favorites: [KilterFavorite]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.angle") private var sharedAngle: Int = 40
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }
    @AppStorage("kilter.apiLevel") private var apiLevelRaw = KilterProtocol.APILevel.v3.rawValue
    private var apiLevel: KilterProtocol.APILevel { .init(rawValue: apiLevelRaw) ?? .v3 }
    /// The user's physical board size (`product_size_id`). Drives which LED map is sent — the wrong
    /// size lights shifted/incorrect holds. Seeded to the layout's default on load, then user-chosen.
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    /// Reveals the "wrong holds?" fixups (board size + protocol) under the connected controls (hidden
    /// until the user hits the escape hatch, so the common path stays uncluttered).
    @State private var showingProtocolFix = false

    /// The climb currently shown — changes as the user swipes through `siblings`.
    @State private var currentUUID: String
    @State private var climb: KilterClimb?
    @State private var stats: [KilterClimbStat] = []
    @State private var holds: [KilterHold] = []
    @State private var geometry: KilterBoardGeometry = .empty
    @State private var betaLinks: [String] = []
    @State private var selectedAngle: Int = 40
    @State private var logConfirmation: String?
    @State private var showingShare = false

    private var currentStat: KilterClimbStat? { stats.first { $0.angle == selectedAngle } }
    private var isFavorite: Bool { favorites.contains { $0.climbUUID == currentUUID } }

    /// Position of the shown climb in the browsed list, when it's part of one.
    private var siblingIndex: Int? { siblings.firstIndex(of: currentUUID) }

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
                Button { showingShare = true } label: { Image(systemName: "qrcode") }
                    .disabled(climb == nil)
                    .accessibilityIdentifier("kilter.share")
                    .accessibilityLabel("Share climb")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { toggleFavorite() } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityIdentifier("kilter.favorite")
                .accessibilityLabel(isFavorite ? "Remove from saved" : "Save climb")
            }
        }
        .sheet(isPresented: $showingShare) {
            if let climb {
                KilterShareView(climb: climb,
                                gradeLabel: currentStat.map { catalog.gradeLabel($0.difficulty) } ?? "—",
                                angle: selectedAngle)
            }
        }
        // Reload whenever the shown climb changes (initial open + each swipe).
        .task(id: currentUUID) { load() }
        // When the board comes up while viewing a climb, light it immediately (it follows swipes via
        // `load()`); the manual "Light up this climb" button stays for a re-send.
        .onChange(of: board.isConnected) { _, connected in
            if connected { board.illuminate(holds) }
        }
        // A board-size change (from the browse chip, Settings, or the inline "wrong holds?" fix) remaps
        // every LED *and* reshapes the on-screen board — each size shows a different physical hole set —
        // so rebuild holds + geometry and re-light. Top-level (not inside the BLE-gated illuminate
        // section) so the on-screen render still updates with no board / on the simulator.
        .onChange(of: productSizeId) {
            guard let c = climb else { return }
            holds = catalog.holds(for: c, sizeId: productSizeId)
            geometry = catalog.boardGeometry(forLayout: c.layoutId, sizeId: productSizeId)
            if board.isConnected { board.illuminate(holds) }
        }
    }

    @ViewBuilder private func content(_ climb: KilterClimb) -> some View {
        VStack(spacing: 20) {
            boardSection

            roleLegend
            anglePicker
            statRow
            metaRow
            sessionStatusRow
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

    /// The board render plus left/right swipe (and tap chevrons) to move through the browsed list,
    /// with a "n / total" position pill. Disabled when the climb isn't part of a list.
    private var boardSection: some View {
        let index = siblingIndex
        let hasPrev = index.map { $0 > 0 } ?? false
        let hasNext = index.map { $0 < siblings.count - 1 } ?? false
        return VStack(spacing: 8) {
            KilterBoardView(geometry: geometry, holds: holds)
                .frame(maxHeight: 380)
                .overlay(alignment: .leading) { if hasPrev { chevron("chevron.left") { goToSibling(-1) } } }
                .overlay(alignment: .trailing) { if hasNext { chevron("chevron.right") { goToSibling(1) } } }
                .contentShape(Rectangle())
                // Simultaneous (not exclusive) so the enclosing ScrollView still scrolls vertically;
                // we act only on a clearly horizontal flick.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if value.translation.width < -40 { goToSibling(1) }
                            else if value.translation.width > 40 { goToSibling(-1) }
                        }
                )
                .padding(.horizontal)

            if let index, siblings.count > 1 {
                Text("\(index + 1) / \(siblings.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("kilter.position")
            }
        }
    }

    private func chevron(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.horizontal, 6)
        .accessibilityIdentifier("kilter.\(systemImage == "chevron.left" ? "prev" : "next")")
    }

    /// Move to the previous/next climb in the browsed list (clamped — no wrap-around).
    private func goToSibling(_ delta: Int) {
        guard let i = siblingIndex else { return }
        let j = i + delta
        guard siblings.indices.contains(j) else { return }
        withAnimation(.snappy) {
            logConfirmation = nil
            currentUUID = siblings[j]
        }
    }

    private var roleLegend: some View {
        HStack(spacing: 16) {
            legendDot("00DD00", "start", "Start")
            legendDot("00FFFF", "middle", "Middle")
            legendDot("FF00FF", "finish", "Finish")
            legendDot("FFA500", "foot", "Foot")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    /// One legend entry: the role's *shape* (not a plain dot) in the role color, so the legend teaches
    /// the color-blind-friendly shape code the board uses.
    private func legendDot(_ hex: String, _ role: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KilterHoldMark(shape: .forRole(role))
                .stroke(Color(hex: hex), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                .frame(width: 11, height: 11)
            Text(label)
        }
    }

    private var anglePicker: some View {
        // Persist the shared angle only on an *explicit* pick — not on the programmatic `selectedAngle`
        // writes `load()` makes for each climb. Otherwise swiping to a climb that lacks the preferred
        // angle would silently clobber the global `kilter.angle` preference for the whole catalog.
        let angleSelection = Binding(
            get: { selectedAngle },
            set: { selectedAngle = $0; sharedAngle = $0 }
        )
        return Menu {
            Picker("Angle", selection: angleSelection) {
                ForEach(stats) { Text("\($0.angle)°  ·  \(catalog.gradeLabel($0.difficulty))").tag($0.angle) }
            }
        } label: {
            Label("\(selectedAngle)°", systemImage: "angle")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .accessibilityIdentifier("kilter.angle")
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

    /// The matching rule (always shown), plus a benchmark ("Classic") badge + first-ascensionist when the
    /// catalog has them for this angle.
    @ViewBuilder private var metaRow: some View {
        let isClassic = currentStat?.benchmarkDifficulty != nil
        let fa = currentStat?.faUsername ?? ""
        HStack(spacing: 10) {
            matchBadge(noMatch: climb?.isNoMatch ?? false)
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

    /// The Kilter "No matching" rule as a tag: an amber `hand.raised.slash` "No matching" chip when the
    /// setter forbids matching hands on a hold, else a quiet "Matching" chip (the default). Mirrors the
    /// official app's no-match icon while still showing the allowed case so the rule is never ambiguous.
    private func matchBadge(noMatch: Bool) -> some View {
        Label(noMatch ? "No matching" : "Matching",
              systemImage: noMatch ? "hand.raised.slash.fill" : "hand.raised.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background((noMatch ? Color.orange : Color.secondary).opacity(noMatch ? 0.18 : 0.14), in: Capsule())
            .foregroundStyle(noMatch ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .accessibilityIdentifier("kilter.matchTag")
            .accessibilityLabel(noMatch ? "No matching allowed on this climb" : "Matching allowed")
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

    /// While a session is live, a compact "session active" + live-HR row above the log buttons, so
    /// the climber sees their heart rate without leaving the climb.
    @ViewBuilder private var sessionStatusRow: some View {
        if sessions.isActive {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating).font(.caption)
                Text("Session active").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if app.liveWorkout.state != .unavailable {
                    KilterHRPill(bpm: app.liveWorkout.latestHR)
                }
            }
            .padding(.horizontal)
            .accessibilityIdentifier("kilter.session.activeRow")
        }
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
                    wrongHoldsControl
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
            // Mirror a protocol switch made here to the controller immediately (the root view also
            // observes this, but the detail screen shouldn't depend on it being mounted); re-lights live.
            .onChange(of: apiLevelRaw) { board.setAPILevel(apiLevel) }
        }
    }

    /// Escape hatch when the board lights the wrong holds: a quiet "wrong holds?" link that reveals the
    /// two fixes, in likelihood order — (1) **board size**, the usual cause of shifted/incorrect holds
    /// (each size addresses its LEDs differently), and (2) the **Standard/Legacy** payload dialect for
    /// older controllers. Both re-light the current climb instantly and persist.
    @ViewBuilder private var wrongHoldsControl: some View {
        if showingProtocolFix {
            VStack(spacing: 12) {
                if let layoutId = climb?.layoutId {
                    let sizes = catalog.sizes(forLayout: layoutId)
                    if sizes.count > 1 {
                        VStack(spacing: 4) {
                            Picker("Board size", selection: $productSizeId) {
                                ForEach(sizes) { Text($0.label).tag($0.id) }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("kilter.board.size")
                            Text("Pick your board's size — the wrong size lights shifted/incorrect holds.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                VStack(spacing: 4) {
                    Picker("Board lights", selection: $apiLevelRaw) {
                        ForEach(KilterProtocol.APILevel.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kilter.board.protocol")
                    Text("Still off? Older controllers use Legacy. Each change re-lights instantly.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Button("Wrong holds lighting up?") { withAnimation(.snappy) { showingProtocolFix = true } }
                .font(.caption)
                .accessibilityIdentifier("kilter.board.wrongHolds")
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
        guard let c = catalog.climb(currentUUID) else { return }
        climb = c
        stats = catalog.stats(currentUUID)
        // Seed the board size to this layout's default if unset/invalid, so the picker shows a real
        // selection and the LED map is concrete.
        if !catalog.sizes(forLayout: c.layoutId).contains(where: { $0.id == productSizeId }) {
            productSizeId = catalog.defaultSizeId(forLayout: c.layoutId)
        }
        holds = catalog.holds(for: c, sizeId: productSizeId)
        geometry = catalog.boardGeometry(forLayout: c.layoutId, sizeId: productSizeId)
        betaLinks = catalog.betaLinks(currentUUID)
        // Prefer the shared angle if it has stats; otherwise the most-climbed angle.
        if stats.contains(where: { $0.angle == sharedAngle }) {
            selectedAngle = sharedAngle
        } else {
            selectedAngle = stats.max { $0.ascents < $1.ascents }?.angle ?? sharedAngle
        }
        // Keep a connected board in sync with the climb on screen (initial open + each swipe).
        if board.isConnected { board.illuminate(holds) }
        // Mark this climb as the one being worked, for per-climb timing + the HUD / Live Activity.
        if sessions.isActive, let c = climb {
            let g = stats.first { $0.angle == selectedAngle }.map { catalog.gradeLabel($0.difficulty) } ?? ""
            sessions.beginClimb(uuid: c.uuid, name: c.name, grade: kilterDisplayGrade(g, gradeFormat))
        }
    }

    private func log(_ status: KilterAscentStatus) {
        guard let climb, let stat = currentStat else { return }
        let grade = catalog.gradeLabel(stat.difficulty)
        let now = Date()
        // Re-arm the active climb (a prior send may have closed it) so timing + the HUD are correct.
        if sessions.isActive {
            sessions.beginClimb(uuid: climb.uuid, name: climb.name,
                                grade: kilterDisplayGrade(grade, gradeFormat))
        }
        // One entry per climb within a session: repeated logs (attempts, then a send) accumulate onto
        // a single row — total tries, attempt timestamps, and the latest status (a send is sticky) —
        // instead of inserting duplicate rows that would double-count the climb.
        if let id = sessions.currentId,
           let existing = existingSessionEntry(climbUUID: climb.uuid, sessionId: id) {
            existing.attempts += 1
            if status == .attempt { existing.attemptTimestamps.append(now) }
            if !existing.status.isSend { existing.statusRaw = status.rawValue }   // a send stays a send
            existing.endedAt = now
            existing.date = now
        } else {
            modelContext.insert(KilterLogEntry(
                climbUUID: climb.uuid, climbName: climb.name, angle: selectedAngle,
                difficulty: stat.difficulty, gradeLabel: grade, status: status,
                attempts: 1, date: now, sessionId: sessions.currentId,
                startedAt: sessions.activeClimbStartedAt, endedAt: now,
                attemptTimestamps: status == .attempt ? [now] : []))
        }
        try? modelContext.save()
        // Flush live HR onto the session as climbs are logged, so a clip recorded on this climb already
        // has heart rate to overlay when reviewed mid-session (no need to end the session first).
        sessions.syncLiveHR(in: modelContext)
        core.log(module: "kilter", action: "log-\(status.rawValue)",
                 summary: "\(status.label) \(climb.name) (\(grade) @\(selectedAngle)°)",
                 metric: stat.difficulty)
        // A send closes the climb so the next one's timing + rest start fresh.
        if status.isSend { sessions.closeActiveClimb() }
        withAnimation(.snappy) {
            logConfirmation = "Logged \(status.label.lowercased()) · \(grade)"
        }
    }

    /// The in-session entry for this climb (any status), if one exists — so repeated logs on the same
    /// climb accumulate onto a single row rather than creating duplicates.
    private func existingSessionEntry(climbUUID: String, sessionId: UUID) -> KilterLogEntry? {
        let descriptor = FetchDescriptor<KilterLogEntry>(predicate: #Predicate {
            $0.sessionId == sessionId && $0.climbUUID == climbUUID
        })
        return try? modelContext.fetch(descriptor).first
    }

    private func toggleFavorite() {
        if let existing = favorites.first(where: { $0.climbUUID == currentUUID }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(KilterFavorite(climbUUID: currentUUID))
        }
        try? modelContext.save()
    }

}
