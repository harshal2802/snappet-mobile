import SwiftUI
import SwiftData
import Charts
import HighlightEngine
import UIKit

/// A single climb: the holds rendered on the board, an angle selector (difficulty is per-angle),
/// grade / quality / ascents for that angle, logging (Flash / Sent / Project / Attempt), a Saved
/// toggle, a beta-video link, and — when a board is connected over BLE — illumination (Phase 2).
/// Logging with no session live **auto-starts** one (undoable, #75) so the rich-session layer —
/// live HR, Live Activity, per-climb timing, media, summary, reel — is never silently forfeited.
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
    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
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
    /// Shown when a log **auto-started** a session (#75): an undoable "Session started" capsule.
    /// Set only when `sessions.start` reports it created a fresh session — never when recovery
    /// adopted an open one — so Undo can only ever remove a session this log created.
    @State private var showingAutoStartUndo = false
    /// Incremented on a first send of a grade — drives `.celebrates(on:)` (issue #80).
    @State private var celebrationTrigger = 0
    @State private var showingShare = false
    @State private var showingMatchInfo = false
    // Created-climb lifecycle (#76): edit re-opens the authoring sheet; rename + delete act in place.
    @State private var showingEdit = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingDeleteCreated = false
    /// All-time ascent history for the currently shown climb — drives flash gate + ascent chip.
    @State private var climbHasAnyAttempt: Bool = false
    @State private var climbIsSent: Bool = false
    @State private var climbIsFlashed: Bool = false
    @State private var climbAttemptCount: Int = 0

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
        .celebrates(on: celebrationTrigger)
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
            // Edit / rename / delete — only for climbs the user authored (#76).
            if let created = createdClimb(currentUUID) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingEdit = true } label: { Label("Edit holds", systemImage: "pencil") }
                        Button { renameText = created.name; showingRename = true } label: {
                            Label("Rename", systemImage: "character.cursor.ibeam")
                        }
                        Button(role: .destructive) { showingDeleteCreated = true } label: {
                            Label("Delete climb", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("kilter.created.menu")
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            if let climb {
                KilterShareView(climb: climb,
                                gradeLabel: currentStat.map { catalog.gradeLabel($0.difficulty) } ?? "—",
                                angle: selectedAngle)
            }
        }
        // Re-open the authoring sheet on the climb (#76). Re-derived identity (changed holds) ⇒ follow it.
        .sheet(isPresented: $showingEdit) {
            if let created = createdClimb(currentUUID) {
                CreateClimbView(onCreated: { newUUID in currentUUID = newUUID; load() },
                                board: board, editing: created)
                    .environment(core)
            }
        }
        .alert("Rename climb", isPresented: $showingRename) {
            TextField("Name", text: $renameText).accessibilityIdentifier("kilter.created.renameField")
            Button("Save") { renameCreated() }.accessibilityIdentifier("kilter.created.renameSave")
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this climb?", isPresented: $showingDeleteCreated, titleVisibility: .visible) {
            Button("Delete climb", role: .destructive) { deleteCreated() }
                .accessibilityIdentifier("kilter.created.deleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = logCount(for: currentUUID)
            Text(n == 0 ? "This removes the climb from Mine. It can't be undone."
                 : "This removes the climb from Mine. Its \(n) logged ascent\(n == 1 ? "" : "s") stay in History.")
        }
        // Reload whenever the shown climb changes (initial open + each swipe).
        .task(id: currentUUID) { load() }
        // When the board comes up while viewing a climb, light it immediately (it follows swipes via
        // `load()`); the manual "Light up this climb" button stays for a re-send. Illumination ONLY — no
        // capture: merely opening a climb's detail while connected isn't a deliberate "I worked this"
        // signal, and recording it turned On the Board into a passive browse log (F1). Capture lives only
        // on the explicit "Light up this climb" tap. (Dropping this site also removes the off-main /
        // double-insert race the BLE-state onChange used to drive.)
        .onChange(of: board.isConnected) { _, connected in
            if connected { board.illuminate(holds) }
        }
        // A board-size change (from the browse chip, Settings, or the inline "wrong holds?" fix) remaps
        // every LED *and* reshapes the on-screen board — each size shows a different physical hole set —
        // so rebuild holds + geometry and re-light. Top-level (not inside the BLE-gated illuminate
        // section) so the on-screen render still updates with no board / on the simulator. Illumination
        // ONLY — no capture (F1): a size remap isn't a fresh "I worked this climb" action.
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
            boardCard
            ascentStatusChip
            logButtons
            gradeChart
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
                .background(SnappetColor.surfaceMuted, in: Capsule())
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

    /// The Kilter "No matching" rule as a **tappable** tag: an amber `hand.raised.slash` "No matching"
    /// chip when the setter forbids matching hands on a hold, else a quiet "Matching" chip (the default).
    /// Tapping it explains what matching means (a popover), since the convention isn't obvious. Mirrors
    /// the official app's no-match icon while still showing the allowed case so the rule is never ambiguous.
    private func matchBadge(noMatch: Bool) -> some View {
        Button { showingMatchInfo = true } label: {
            Label(noMatch ? "No matching" : "Matching",
                  systemImage: noMatch ? "hand.raised.slash.fill" : "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background((noMatch ? Color.orange : Color.secondary).opacity(noMatch ? 0.18 : 0.14), in: Capsule())
                .foregroundStyle(noMatch ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.matchTag")
        .accessibilityLabel(noMatch ? "No matching allowed on this climb" : "Matching allowed")
        .accessibilityHint("Explains what matching means")
        .popover(isPresented: $showingMatchInfo) {
            matchInfoPopover(noMatch: noMatch).presentationCompactAdaptation(.popover)
        }
    }

    /// Small explainer shown when the matching chip is tapped: what "matching" is, and this climb's rule.
    private func matchInfoPopover(noMatch: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(noMatch ? "No matching" : "Matching allowed",
                  systemImage: noMatch ? "hand.raised.slash.fill" : "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(noMatch ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
            Text("“Matching” means putting both hands on the same hold. "
                 + (noMatch
                    ? "This climb is set no-matching — the setter asks you not to match hands on any hold."
                    : "Matching is allowed on this climb (the default)."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 240)
        .accessibilityIdentifier("kilter.matchInfo")
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
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle").foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating).font(.caption)
                    Text("Session active").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if app.liveWorkout.state != .unavailable {
                        KilterHRPill(bpm: app.liveWorkout.latestHR,
                                     contactLost: app.liveWorkout.isContactLost == true,
                                     readiness: RecoveryReadiness.evaluate(
                                        currentBpm: app.liveWorkout.latestHR,
                                        restBpm: app.userProfile.profile.restingBound,
                                        maxBpm: app.userProfile.profile.resolvedMaxHR))
                    }
                }
                // For a plan-backed run, the climb screen is a station in the plan: jump back to the
                // list or advance to the next pending pick — a forward loop, not a back-button hunt.
                if sessions.currentPlanId != nil { planStrip }
            }
            .padding(.horizontal)
            .accessibilityIdentifier("kilter.session.activeRow")
        }
    }

    private var planStrip: some View {
        HStack(spacing: 12) {
            Button {
                // Reset to the Kilter root + push the plan, rather than appending another
                // KilterPlanRoute onto a stack that already has Plan→Climb below (which would accrete
                // a stale Plan/Climb pair every loop). open() replaces the path, so this reaches the
                // plan-home cleanly from any entry — the dominant Plan→Climb flow and an off-plan
                // climb reached from the catalog alike. Same pattern the live chip / Home card use.
                router.open(module: "kilter")
                router.push(KilterPlanRoute())
            } label: {
                Label("Back to plan", systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.climb.backToPlan")
            Spacer()
            if let p = sessions.planProgress {
                Text("\(p.done)/\(p.total)")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if let next = sessions.nextPlanClimb(excluding: currentUUID) {
                Button { withAnimation(.snappy) { logConfirmation = nil; currentUUID = next } } label: {
                    HStack(spacing: 3) {
                        Text("Next pick"); Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.climb.nextPick")
            } else {
                Text("Plan done").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .tint(SnappetColor.moduleAccent("kilter"))
        .foregroundStyle(SnappetColor.moduleAccent("kilter"))
    }

    private var logButtons: some View {
        VStack(spacing: 8) {
            if climbIsSent {
                // State C: already sent — secondary actions only, no Send it! emphasis
                HStack(spacing: 10) {
                    logButton(.sent, "checkmark", label: "Log again")
                    logButton(.attempt, "arrow.uturn.up")
                }
                HStack(spacing: 10) {
                    logButton(.project, "target")
                    flashButtonDisabled(reason: climbIsFlashed ? "Already flashed" : "Already sent")
                }
            } else if climbHasAnyAttempt {
                // State B: attempted but not sent — Send it! is the primary action
                Button { log(.sent) } label: {
                    Label("Send it!", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("kilter.log.sent")
                HStack(spacing: 10) {
                    logButton(.attempt, "arrow.uturn.up")
                    logButton(.project, "target")
                }
                flashButtonDisabled(reason: "Flash not available — you've already attempted this climb")
            } else {
                // State A: never tried — all options available, Flash eligible
                HStack(spacing: 10) {
                    logButton(.flash, "bolt.fill")
                    logButton(.sent, "checkmark")
                }
                HStack(spacing: 10) {
                    logButton(.project, "target")
                    logButton(.attempt, "arrow.uturn.up")
                }
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
            autoStartCapsule
        }
        .padding(.horizontal)
        .animation(.snappy, value: climbHasAnyAttempt)
        .animation(.snappy, value: climbIsSent)
    }

    /// Disabled Flash button with a brief inline reason — always full-width so layout doesn't shift.
    private func flashButtonDisabled(reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.slash.fill").foregroundStyle(.secondary)
            Text(reason).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("kilter.log.flash.disabled")
    }

    /// Undoable "Session started" confirmation, shown when a log auto-started a session (#75) —
    /// the log is already attached; Undo keeps the log and removes the session. Auto-dismisses
    /// (the session itself stays — the bar/HUD keep showing it; only the undo window closes).
    @ViewBuilder private var autoStartCapsule: some View {
        if showingAutoStartUndo, sessions.isActive {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Session started — this log is in it")
                    .foregroundStyle(.secondary)
                Button("Undo") {
                    withAnimation(.snappy) {
                        sessions.undoStart(in: modelContext)
                        showingAutoStartUndo = false
                    }
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("kilter.autoSession.undo")
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.green.opacity(0.14), in: Capsule())
            .transition(.scale.combined(with: .opacity))
            // The container gets a name WITHOUT clobbering the Undo button's id (the #68
            // banner gotcha: a bare container identifier propagates onto every child element).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kilter.autoSession.banner")
            .task {
                try? await Task.sleep(for: .seconds(10))
                withAnimation(.snappy) { showingAutoStartUndo = false }
            }
        }
    }

    private func logButton(_ status: KilterAscentStatus, _ image: String, label: String? = nil) -> some View {
        Button { log(status) } label: {
            Label(label ?? status.label, systemImage: image).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(status.isSend ? .green : .orange)
        .accessibilityIdentifier("kilter.log.\(status.rawValue)")
    }

    /// Compact board connection card shown above the log buttons — persistent so the climber can
    /// reconnect mid-session without scrolling to the bottom.
    @ViewBuilder private var boardCard: some View {
        if board.state != .unsupported {
            VStack(spacing: 0) {
                switch board.state {
                case .connected:
                    HStack(spacing: 10) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Board connected · \(selectedAngle)°")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            lightAndCapture()
                        } label: {
                            Label("Light up", systemImage: "lightbulb.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(SnappetColor.moduleAccent("kilter").opacity(0.18),
                                            in: Capsule())
                                .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.illuminate")
                        Button {
                            board.disconnect()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.board.disconnect")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.green.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: SnappetRadius.md)
                            .stroke(Color.green.opacity(0.30), lineWidth: 1)
                    )

                case .scanning, .connecting:
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text(board.state == .scanning ? "Searching for board…" : "Connecting…")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { board.cancel() }
                            .font(.caption)
                            .accessibilityIdentifier("kilter.board.cancel")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(SnappetColor.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))

                case .failed(let message):
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button {
                            board.connect()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: SnappetRadius.md)
                            .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                    )

                case .bluetoothOff:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text("Bluetooth is off — turn it on to connect your board")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(SnappetColor.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))

                case .unauthorized:
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        Text("Snappet needs Bluetooth access to connect your board")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(SnappetColor.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: SnappetRadius.md))

                default: // .idle
                    Button {
                        board.connect()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                            Text("Connect Kilter Board")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(SnappetColor.surfaceMuted,
                                    in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kilter.board.connect")
                }

                // Wrong-holds fix exposed only when connected
                if case .connected = board.state {
                    wrongHoldsControl.padding(.horizontal, 14).padding(.top, 6)
                }
            }
            .padding(.horizontal)
            .animation(.snappy, value: board.state)
            .onChange(of: apiLevelRaw) { board.setAPILevel(apiLevel) }
        }
    }

    /// A compact chip showing the climber's all-time ascent status on this climb.
    @ViewBuilder private var ascentStatusChip: some View {
        if climbIsSent {
            Label(climbIsFlashed ? "Flashed" : "Sent · \(climbAttemptCount) attempts",
                  systemImage: climbIsFlashed ? "bolt.fill" : "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
                .accessibilityIdentifier("kilter.ascentStatus")
        } else if climbHasAnyAttempt {
            Label(climbAttemptCount == 1 ? "1 attempt · not sent" : "\(climbAttemptCount) attempts · not sent",
                  systemImage: "arrow.uturn.up.circle")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
                .accessibilityIdentifier("kilter.ascentStatus")
        }
        // State A (never tried): no chip — blank slate, no need to state the obvious
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


    // MARK: - Actions

    /// Resolve a climb by uuid: a catalog climb first, else one the user authored (`KilterCreatedClimb`,
    /// adapted via `asClimb`) so created climbs open in this same screen — render, logging, favorite, and
    /// BLE illumination all work unchanged.
    private func resolveClimb(_ uuid: String) -> KilterClimb? {
        if let c = catalog.climb(uuid) { return c }
        return createdClimb(uuid)?.asClimb
    }

    /// The user-authored climb with this uuid, if any.
    private func createdClimb(_ uuid: String) -> KilterCreatedClimb? {
        let d = FetchDescriptor<KilterCreatedClimb>(predicate: #Predicate { $0.uuid == uuid })
        return try? modelContext.fetch(d).first
    }

    /// Logged ascents pointing at a climb — surfaced before delete so the user knows what stays (#76).
    private func logCount(for uuid: String) -> Int {
        let d = FetchDescriptor<KilterLogEntry>(predicate: #Predicate { $0.climbUUID == uuid })
        return (try? modelContext.fetchCount(d)) ?? 0
    }

    /// In-place rename of the authored climb (same holds ⇒ same content uuid, so nothing else moves).
    private func renameCreated() {
        guard let created = createdClimb(currentUUID) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        created.name = trimmed
        try? modelContext.save()
        load()
    }

    /// Delete the authored climb (#76). Its logged ascents are **kept** — a real send shouldn't vanish;
    /// they carry their own name snapshot, so History stays readable. A stale favorite is dropped. Pops
    /// back to browse. Because the row leaves `Mine`, the duplicate checker no longer traps against it.
    private func deleteCreated() {
        guard let created = createdClimb(currentUUID) else { return }
        core.log(module: "kilter", action: "deleted", summary: "Deleted \(created.name)")
        KilterCreatedClimb.delete(created, in: modelContext)
        dismiss()
    }

    /// Fetch all-time log entries for this climb and update the flash-gate state.
    private func fetchClimbHistory() {
        let uuid = currentUUID
        // Fetch by climbUUID only — computed properties (status.isSend) can't appear in #Predicate
        // (which compiles to SQL). Raw-value filtering happens in Swift after the fetch.
        let descriptor = FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.climbUUID == uuid })
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        let sentRaw = KilterAscentStatus.sent.rawValue
        let flashRaw = KilterAscentStatus.flash.rawValue
        let attemptRaw = KilterAscentStatus.attempt.rawValue
        // An attempt or any send (including flash) forfeits Flash eligibility on future tries.
        // Project entries are bookmarks only and do NOT forfeit Flash.
        let hasSend = entries.contains { $0.statusRaw == sentRaw || $0.statusRaw == flashRaw }
        let hasAttempt = entries.contains { $0.statusRaw == attemptRaw }
        climbIsSent = hasSend
        climbIsFlashed = entries.contains { $0.statusRaw == flashRaw }
        climbHasAnyAttempt = hasAttempt || hasSend
        // Count total attempt events (not entries): each entry's `attempts` field tracks how many
        // times the climber tapped Attempt/Send on that session's row.
        climbAttemptCount = entries.reduce(0) { $0 + $1.attempts }
    }

    private func load() {
        guard let c = resolveClimb(currentUUID) else { return }
        climb = c
        var resolvedStats = catalog.stats(currentUUID)
        // Created climbs have no per-angle catalog stats — synthesize a single stat from the climb's
        // designed angle + predicted/chosen grade so the grade row and angle picker still read.
        if resolvedStats.isEmpty, let created = createdClimb(currentUUID), let g = created.predictedGrade {
            resolvedStats = [KilterClimbStat(angle: created.angle, difficulty: g, benchmarkDifficulty: nil,
                                             ascents: 0, quality: 0, faUsername: "")]
        }
        stats = resolvedStats
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
        fetchClimbHistory()
        // Keep a connected board in sync with the climb on screen (initial open + each swipe).
        // Illumination ONLY — no capture (F1): opening/swiping to a climb's detail while connected isn't
        // a deliberate "I worked this" action; only the explicit "Light up this climb" tap records one.
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
        // Counted BEFORE this log lands, so the entry being written can't shadow itself.
        let priorSendsAtGrade = priorSendCount(atGrade: grade)
        // Logging with no session live silently forfeited the whole rich-session layer (live HR,
        // Live Activity, per-climb timing, media, summary, reel) — auto-start one, matching the
        // BLE-connect behavior (#75). `start` folds recovery, so an open session in the store is
        // adopted rather than forked; the undoable capsule is offered ONLY for a fresh creation.
        if !sessions.isActive {
            // Stamp the board layout this session ran on (the climb's own layout) so History can facet by
            // board/layout — this is the most-common start path (logging a climb), which previously left
            // `layoutId` nil (FC).
            let createdFresh = sessions.start(angle: selectedAngle, source: "auto",
                                              layoutId: climb.layoutId, in: modelContext)
            withAnimation(.snappy) { showingAutoStartUndo = createdFresh }
        }
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
            if !existing.status.isSend {
                existing.statusRaw = status.rawValue   // a send stays a send
                // Refresh the grade snapshot with the angle actually climbed — the angle
                // picker may have moved since the row was first logged, and the
                // first-send milestone + history read these fields (review fix). Once a
                // send landed, its snapshot is history and stays put.
                existing.angle = selectedAngle
                existing.difficulty = stat.difficulty
                existing.gradeLabel = grade
            }
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
        // Recap feed (F0b): append-only, idempotent per-send activity (sends carry sent/flashed).
        FeedActivityWriter.recordKilterLog(climbUUID: climb.uuid, difficulty: stat.difficulty,
                                           status: status, gradeLabel: grade, date: now,
                                           sessionId: sessions.currentId, in: modelContext)
        try? modelContext.save()
        fetchClimbHistory()
        // Tick the active planned session, if this run came from "Plan a session": flips the matching
        // KilterPlanItem to sent/attempted so the plan-home shows it done. No-op for an ad-hoc session
        // or an off-plan climb. Read off the plan, never re-derived from logs + the recommender.
        sessions.applyLogToPlan(climbUUID: climb.uuid, ascent: status, at: now, in: modelContext)
        // Flush live HR onto the session as climbs are logged, so a clip recorded on this climb already
        // has heart rate to overlay when reviewed mid-session (no need to end the session first).
        sessions.syncLiveHR(in: modelContext)
        core.log(module: "kilter", action: "log-\(status.rawValue)",
                 summary: "\(status.label) \(climb.name) (\(grade) @\(selectedAngle)°)",
                 metric: stat.difficulty)
        // A send closes the climb so the next one's timing + rest start fresh.
        if status.isSend { sessions.closeActiveClimb() }
        // Tactile commit cue — a first send of a grade gets the celebration burst, every
        // other log a plain success haptic (issue #80; logging happens mid-climb with
        // chalky hands, where the caption capsule alone is easy to miss).
        if KilterMilestones.isFirstSend(status: status, priorSendCountAtGrade: priorSendsAtGrade) {
            celebrationTrigger += 1
        } else {
            Haptics.success()
        }
        withAnimation(.snappy) {
            logConfirmation = "Logged \(status.label.lowercased()) · \(grade)"
        }
    }

    /// One-off count of entries already logged as a send at this grade label (any climb).
    private func priorSendCount(atGrade grade: String) -> Int {
        let sendRaws = [KilterAscentStatus.sent.rawValue, KilterAscentStatus.flash.rawValue]
        let descriptor = FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.gradeLabel == grade && sendRaws.contains($0.statusRaw) })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
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
        Haptics.tap()
    }

    /// Light the climb on the board AND record a deduped `KilterLitEvent` (P5 "On the Board"). The
    /// capture lives HERE — at the illuminate call site where the climb identity / session / size are
    /// known — never in the platform-pure `KilterBoardController` (which only sees `[KilterHold]`). The
    /// authoring preview (`CreateClimbView`) is intentionally NOT routed through this, so design
    /// previews don't pollute the worked-climbs history.
    ///
    /// `wasConnected` records whether a board was actually on the wall when lit; an explicit tap with no
    /// board still records intent (the climber chose this climb) but flagged not-on-the-wall.
    private func lightAndCapture() {
        board.illuminate(holds)
        captureLitEvent()
    }

    /// Upsert a `KilterLitEvent` keyed by (normalized climbUUID, current sessionId): bump `litAt` on the
    /// existing row for this climb-in-this-session, else insert one — so re-lighting a project many times
    /// in a session yields ONE bounded row. Snapshots the climb's display facts so On the Board renders
    /// without re-opening the catalog. No-op until the climb has loaded. The shared upsert path also backs
    /// the re-light buttons (F3), so every recording route dedups identically.
    private func captureLitEvent() {
        guard let climb else { return }
        upsertLitEvent(climbUUID: climb.uuid, climbName: climb.name, layoutId: climb.layoutId,
                       angle: selectedAngle, sizeId: productSizeId,
                       gradeLabel: currentStat.map { catalog.gradeLabel($0.difficulty) } ?? "",
                       sessionId: sessions.currentId, wasConnected: board.isConnected,
                       in: modelContext)
    }

}

/// The shared (normalized climbUUID, sessionId) upsert behind every lit-event recording site — the
/// detail-screen capture (F2) AND both re-light buttons (F3) — so they can't dedup differently.
///
/// The dedup matches `sessionId` IN MEMORY rather than via a `#Predicate { $0.sessionId == sid }`, because
/// a SwiftData predicate compiles to SQL where `NULL == NULL` is never true: a no-session light could
/// never match the existing no-session row, so every out-of-session light inserted an unbounded new row
/// (F2). Instead we fetch by the NON-optional `climbUUID` and match the session (incl. `nil == nil`) in
/// Swift. Bumps `litAt` + refreshes the on-screen snapshot facts on a hit; inserts one row on a miss.
@MainActor
func upsertLitEvent(climbUUID: String, climbName: String, layoutId: Int, angle: Int, sizeId: Int,
                    gradeLabel: String, sessionId: UUID?, wasConnected: Bool,
                    at now: Date = Date(), in modelContext: ModelContext) {
    let key = KilterClimbID.normalize(climbUUID)
    // Match BOTH the normalized uuid AND the session in memory: a `#Predicate` can't call our normalizer
    // (so a differently-cased stored uuid would be missed) and compiles `sessionId == nil` to SQL where
    // `NULL == NULL` is never true (so a no-session light would never find its existing no-session row →
    // unbounded inserts, F2). Lit events are deduped per climb-per-session, so this small fetch is bounded.
    let existing = (try? modelContext.fetch(FetchDescriptor<KilterLitEvent>()))?
        .first { KilterClimbID.normalize($0.climbUUID) == key && $0.sessionId == sessionId }
    if let existing {
        existing.litAt = now
        existing.wasConnected = wasConnected
        // Refresh the snapshot facts to the angle/size now on screen (the picker may have moved).
        existing.angle = angle
        existing.gradeLabel = gradeLabel
        existing.sizeId = sizeId
    } else {
        modelContext.insert(KilterLitEvent(
            climbUUID: climbUUID, climbName: climbName, gradeLabel: gradeLabel,
            angle: angle, layoutId: layoutId, sizeId: sizeId,
            litAt: now, wasConnected: wasConnected, sessionId: sessionId))
    }
    try? modelContext.save()
}
