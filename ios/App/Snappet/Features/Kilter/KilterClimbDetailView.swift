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
    /// "Light climbs automatically" (Kilter Settings), OFF by default (user, 2026-10-29): only the button / pill light.
    @AppStorage(KilterAutoLight.defaultsKey) private var autoLight = false
    /// The climb you last lit on this screen — a reconnect / size fix re-sends it even with auto-light off.
    @State private var litClimbUUID: String?
    private var litByYou: Bool { litClimbUUID != nil && litClimbUUID == climb?.uuid }
    /// Reveals the "wrong holds?" fixups (board size + protocol) under the connected controls (hidden
    /// until the user hits the escape hatch, so the common path stays uncluttered).
    @State private var showingProtocolFix = false
    /// The active browse layout (`kilter.layout`) — read/written here only so a confirmed "Set up this
    /// board" choice repoints browsing at the board the user just verified. `KilterRootView` owns the same
    /// key; both are backed by the one `UserDefaults` value, so they stay in lockstep.
    @AppStorage("kilter.layout") private var activeLayoutId = 1
    /// The "Set up this board" verifier (prompt 120). Presented automatically on the first light against a
    /// connected board the user hasn't confirmed yet, and from the always-available control below.
    @State private var showingBoardSetup = false
    /// Per-board memory (layout/size/verified), keyed by BLE identifier — a `UserDefaults`-backed view like
    /// `KilterSettingsView`'s, so this instance stays consistent with the root view's.
    @State private var boardMemory = KilterBoardMemory()

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
    /// Your clips filed to this climb across board sessions (prompt 188) — "▶ N past clips" opens them all.
    @State private var clipCount = 0
    @State private var showingClips = false
    @State private var showingMatchInfo = false
    // Created-climb lifecycle (#76): edit re-opens the authoring sheet; rename + delete act in place.
    @State private var showingEdit = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingDeleteCreated = false
    // Prompt 214: this session's clips for the climb on screen + the Tag clips sheet + the shared clip studio.
    @State private var sessionClips: [SessionMedia] = []
    @State private var sessionClimbNames: [String: String] = [:]
    @State private var showingTagClips = false
    @State private var findingClips = false
    @State private var clipStudio: ClimbClipStudio?
    /// Prompt 215: your own photo of this board behind the holds, and its setup sheet.
    @State private var showingBoardPhoto = false
    private var photoBoardID: UUID? { board.connectedIdentifier ?? board.releasedBoardID }
    private var boardPhoto: UIImage? {
        guard let climb else { return nil }
        return KilterBoardPhotoStore.shared.image(layoutId: climb.layoutId, sizeId: productSizeId, boardID: photoBoardID)
    }

    private struct ClimbClipStudio: Identifiable {
        let id = UUID()
        let project: StudioProject
        let sessionId: UUID
        let visible: Set<UUID>?
        let focus: UUID?
        let single: SessionMedia?
    }

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
        // The name lives in the climb card under the board (prompt 214); the bar keeps it for VoiceOver + back menus.
        .navigationTitle(climb?.name ?? "Climb")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        .background(SnappetColor.paper.ignoresSafeArea())
        .celebrates(on: celebrationTrigger)
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
        .task(id: currentUUID) { clipCount = countClips(currentUUID); reloadSessionClips() }
        .onChange(of: sessions.currentId) { reloadSessionClips() }
        .sheet(isPresented: $showingBoardPhoto) {
            if let climb {
                KilterBoardPhotoSheet(layoutId: climb.layoutId, sizeId: productSizeId, boardID: photoBoardID,
                                      boardName: sharedBoardLabel ?? "your board", geometry: geometry,
                                      sampleHolds: holds)
            }
        }
        .sheet(isPresented: $showingTagClips, onDismiss: reloadSessionClips) {
            KilterTagClipsSheet(climbUUID: currentUUID, climbName: climb?.name ?? "this climb",
                                media: sessionClips, climbNames: sessionClimbNames, onFindNew: findNewClips)
        }
        .fullScreenCover(item: $clipStudio, onDismiss: reloadSessionClips) { p in
            KilterClipStudio(project: p.project, context: modelContext,
                             visibleClipMediaIDs: p.visible, focusClipMediaID: p.focus,
                             sessionId: p.sessionId, climbUUID: currentUUID,
                             singleClip: p.single,
                             climbTargets: sessionClimbNames.map { KilterClimbTarget(uuid: $0.key, name: $0.value) }
                                .sorted { $0.name < $1.name })
        }
        .sheet(isPresented: $showingClips) {
            ActivityClipsSheet(target: ActivityClipsTarget(key: ActivityKey(exerciseId: LibraryCatalog.kilterExerciseId,
                                                                            nameKey: currentUUID),
                                                           title: climb?.name ?? "Climb"),
                               history: [], unit: .kg, kilterClimbUUID: currentUUID)
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
        // `load()`); the manual "Light up this climb" button stays for a re-send. This is a real
        // wall-light, so it's captured for On the Board (prompt 121): the policy is "record every climb
        // whose holds actually reached a connected board", regardless of which control triggered it — the
        // capture used to be gated to the explicit button alone, so climbs lit by connect/swipe/pill were
        // silently dropped from the history. The shared upsert is idempotent per climb+session, so this
        // and the other light sites overlapping for the same climb only bump one row, never duplicate it.
        .onChange(of: board.isConnected) { _, connected in
            if connected, KilterAutoLight.shouldLight(.boardConnected, automatic: autoLight, litByYou: litByYou) {
                illuminateAndCapture()
            }
        }
        // A board-size change (from the browse chip, Settings, or the inline "wrong holds?" fix) remaps
        // every LED *and* reshapes the on-screen board — each size shows a different physical hole set —
        // so rebuild holds + geometry and re-light. Top-level (not inside the BLE-gated illuminate
        // section) so the on-screen render still updates with no board / on the simulator. Captures only
        // when the remapped holds actually reach a connected board (prompt 121); a size change on the
        // simulator just updates the render and records nothing.
        .onChange(of: productSizeId) {
            guard let c = climb else { return }
            holds = catalog.holds(for: c, sizeId: productSizeId)
            geometry = catalog.boardGeometry(forLayout: c.layoutId, sizeId: productSizeId)
            if board.canLight, KilterAutoLight.shouldLight(.boardSizeChanged, automatic: autoLight, litByYou: litByYou) {
                illuminateAndCapture()
            }
        }
        .sheet(isPresented: $showingBoardSetup) { boardSetupSheet }
        .kilterBoardChooser(board: board, catalog: catalog, layoutId: climb?.layoutId ?? activeLayoutId,
                            sizeId: productSizeId)
    }

    /// The "Set up this board" verifier, seeded with the open climb's own layout (so a matching board lights
    /// the real climb straight away) and the current size.
    /// Clips filed to this climb in any board session (not posted reels).
    private func countClips(_ uuid: String) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.assignedClimbUUID == uuid && $0.reelTitle == nil }))) ?? 0
    }

    @ViewBuilder private var boardSetupSheet: some View {
        KilterBoardSetupSheet(
            board: board, catalog: catalog, climb: climb,
            boardLabel: board.connectedIdentifier.flatMap { boardMemory.recall(identifier: $0) }?.label ?? "this board",
            initialLayoutId: climb?.layoutId ?? activeLayoutId,
            initialSizeId: productSizeId,
            myBoards: KilterMyBoards.unlinked(KilterMyBoards.load()),
            onConfirm: { layoutId, sizeId, name, mine in
                confirmBoardSetup(layoutId: layoutId, sizeId: sizeId)
                if let id = board.connectedIdentifier {
                    boardMemory.rename(identifier: id, to: name)      // prompt 205: named on first connect
                    if let mine { KilterMyBoards.save(KilterMyBoards.link(mine, to: id, in: KilterMyBoards.load())) }
                }
            })
    }

    /// Prompt 214 (mockup `docs/ux-research/design-system/kilter-climb.html`): the same elements as before,
    /// regrouped — session strip → board (+ legend, position, off-board note) → the climb card (name, set by / FA,
    /// grade with the angle picker | quality + ascents, tags) → Board (light + every connection state + fixes) →
    /// Log this climb → Videos from this session → Grade by angle → Beta.
    @ViewBuilder private func content(_ climb: KilterClimb) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionStatusRow
            boardSection
            offBoardNote
            climbCard(climb)
            illuminateSection
            logButtons
            sessionClipsCard
            gradeChart
            if let link = betaLinks.first, let url = URL(string: link) {
                Link(destination: url) {
                    SnappetRow(icon: "▶︎", title: "Beta video", subtitle: url.host() ?? "Opens the link")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, 2)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous)
                    .strokeBorder(SnappetColor.hairline))
                .padding(.horizontal)
                .accessibilityIdentifier("kilter.beta")
            }
        }
        .padding(.vertical, 8)
        .padding(.bottom, 16)
    }

    /// One climb card: name, "Set by · FA", grade at the chosen angle (with the angle picker) beside quality +
    /// ascents, then the tags (matching rule, Classic, past clips).
    private func climbCard(_ climb: KilterClimb) -> some View {
        let fa = currentStat?.faUsername ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(climb.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                Text((["Set by \(climb.setter)"] + (fa.isEmpty ? [] : ["FA \(fa)"])).joined(separator: " · "))
                    .snappetDetail()
            }
            Divider().overlay(SnappetColor.hairline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Grade").snappetLabel()
                        Spacer(minLength: 4)
                        anglePicker
                    }
                    Text(currentStat.map { kilterDisplayGrade(catalog.gradeLabel($0.difficulty), gradeFormat) } ?? "—")
                        .font(SnappetType.metric).monospacedDigit().foregroundStyle(SnappetColor.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("kilter.grade")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(SnappetColor.hairline).frame(width: 1, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quality").snappetLabel()
                    KilterStars(quality: currentStat?.quality ?? 0)
                    Text("\((currentStat?.ascents ?? 0).formatted()) ascents").snappetDetail()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            metaRow
        }
        .snappetPanel()
        .padding(.horizontal)
    }

    private var boardSection: some View {
        let index = siblingIndex
        let hasPrev = index.map { $0 > 0 } ?? false
        let hasNext = index.map { $0 < siblings.count - 1 } ?? false
        return VStack(spacing: 8) {
            KilterBoardView(geometry: geometry, holds: holds, photo: boardPhoto)
                .frame(maxHeight: 380)
                .overlay(alignment: .topLeading) {
                    if boardPhoto != nil {
                        Button { showingBoardPhoto = true } label: {
                            Label("Your photo", systemImage: "camera.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(SnappetColor.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .accessibilityIdentifier("kilter.boardPhoto.chip")
                    }
                }
                // Connection state where the eye already is (UX feedback "connecting to the board was
                // hard to see": the only Connect control sat 8 blocks down this scroll).
                .overlay(alignment: .topTrailing) { boardStatusPill.padding(8) }
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

            HStack {
                roleLegend
                Spacer(minLength: 6)
                if let index, siblings.count > 1 {
                    Text("\(index + 1) / \(siblings.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("kilter.position")
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// A glass status pill on the board render — the answer to "am I connected?" without scrolling.
    /// Idle/failed → one-tap Connect; busy → progress (tap cancels); connected → "On the board", tap
    /// re-sends the holds. The full section below (wrong-holds fixes, disconnect) is unchanged; this
    /// is the fast path, not a replacement. Hidden when there's no radio (simulator).
    @ViewBuilder private var boardStatusPill: some View {
        if board.state != .unsupported {
            Button { boardPillTapped() } label: {
                HStack(spacing: 5) {
                    switch board.state {
                    case .connected:
                        Image(systemName: "lightbulb.fill")
                        Text("On the board")
                    case .idle where board.isReleased:
                        Image(systemName: "person.2.fill")
                        Text("Board free · Light")
                    case .scanning, .connecting:
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                    case .bluetoothOff:
                        Image(systemName: "wifi.slash")
                        Text("Bluetooth off")
                    case .unauthorized:
                        Image(systemName: "lock.fill")
                        Text("Allow Bluetooth")
                    default:
                        Image(systemName: "bolt.fill")
                        Text("Connect board")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(board.canLight ? Color.green : SnappetColor.brand)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .animation(.snappy, value: board.state)
            .accessibilityIdentifier("kilter.board.pill")
        }
    }

    private func boardPillTapped() {
        switch board.state {
        case .connected:
            if needsBoardSetup { showingBoardSetup = true; return }
            illuminateAndCapture()
            Haptics.tap()
        case .idle where board.isReleased:
            illuminateAndCapture()
            Haptics.tap()
        case .idle, .failed:
            board.connect()
        case .scanning, .connecting:
            board.cancel()
        case .unauthorized:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        default:
            break   // .bluetoothOff — Control Center is the fix; the pill just says so.
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
        HStack(spacing: 10) {
            legendDot("00DD00", "start", "Start")
            legendDot("00FFFF", "middle", "Middle")
            legendDot("FF00FF", "finish", "Finish")
            legendDot("FFA500", "foot", "Foot")
        }
        .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
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
            HStack(spacing: 3) {
                Text("\(selectedAngle)°")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, -3).padding(.vertical, -2)
            .snappetPill(selected: true)
        }
        .accessibilityIdentifier("kilter.angle")
    }

    /// Holds on this climb that the selected board size has no LED for — the climb was set on a bigger
    /// board, so those holds can't light (device feedback: "cam pussie"'s 16 x 12-only finish). Browse
    /// already hides such climbs for your size; this catches ones reached from Saved, a QR code or History.
    /// Zero when the size has no LED map at all (an older catalog), so it never cries wolf.
    private var offBoardHolds: Int {
        guard holds.contains(where: { $0.ledPosition != nil }) else { return 0 }
        return holds.filter { $0.ledPosition == nil }.count
    }

    @ViewBuilder private var offBoardNote: some View {
        let n = offBoardHolds
        if n > 0, let c = climb {
            let sizes = catalog.sizes(forLayout: c.layoutId)
            let mine = sizes.first { $0.id == productSizeId }?.name ?? "your"
            let fits = sizes.first {
                $0.box?.fits(left: c.edgeLeft, right: c.edgeRight, bottom: c.edgeBottom, top: c.edgeTop) == true
            }?.name
            Label {
                Text("\(n) hold\(n == 1 ? " isn't" : "s aren't") on your \(mine) board, so \(n == 1 ? "it" : "they") won't light"
                     + (fits.map { ". This climb was set for a \($0)." } ?? "."))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(SnappetType.detail)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("kilter.offBoardNote")
        }
    }

    /// The matching rule (always shown), plus a benchmark ("Classic") badge + first-ascensionist when the
    /// catalog has them for this angle.
    @ViewBuilder private var metaRow: some View {
        let isClassic = currentStat?.benchmarkDifficulty != nil
        let match = matchBadge(noMatch: climb?.isNoMatch ?? false)
        let classic = Label("Classic", systemImage: "rosette").font(.system(size: 12.5)).snappetPill(selected: false)
        let clips = Button { showingClips = true } label: {
            Label("\(clipCount) past \(clipCount == 1 ? "clip" : "clips")", systemImage: "play.rectangle.on.rectangle")
                .font(.system(size: 12.5)).snappetPill(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.pastClips")
        // Wraps to a second line on narrow widths (FA moved to the name line).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                match
                if isClassic { classic }
                if clipCount > 0 { clips }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { match; if isClassic { classic } }
                if clipCount > 0 { clips }
            }
        }
    }

    /// The Kilter "No matching" rule as a **tappable** tag: an amber `hand.raised.slash` "No matching"
    /// chip when the setter forbids matching hands on a hold, else a quiet "Matching" chip (the default).
    /// Tapping it explains what matching means (a popover), since the convention isn't obvious. Mirrors
    /// the official app's no-match icon while still showing the allowed case so the rule is never ambiguous.
    private func matchBadge(noMatch: Bool) -> some View {
        Button { showingMatchInfo = true } label: {
            HStack(spacing: 4) {
                Label(noMatch ? "No matching" : "Matching",
                      systemImage: noMatch ? "hand.raised.slash.fill" : "hand.raised.fill")
                Image(systemName: "info.circle").font(.system(size: 10))
            }
            .font(.system(size: 12.5))
            .snappetPill(selected: false, tint: noMatch ? .orange : nil)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Grade by angle").snappetLabel()
                Chart(stats) { s in
                    // Bars rise from the domain's floor (not 0, which sits below it and overflowed the card).
                    BarMark(x: .value("Angle", "\(s.angle)°"),
                            yStart: .value("Floor", chartYDomain.lowerBound),
                            yEnd: .value("Difficulty", s.difficulty), width: .ratio(0.7))
                        .foregroundStyle(s.angle == selectedAngle ? SnappetColor.brand : SnappetColor.hairline)
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().font(.system(size: 9.5)).foregroundStyle(SnappetColor.textTertiary) }
                }
                .chartYScale(domain: chartYDomain)
                .frame(height: 72)
                .clipped()
                .animation(.snappy, value: selectedAngle)
                if let lo = stats.first, let hi = stats.last {
                    Text("\(kilterDisplayGrade(catalog.gradeLabel(lo.difficulty), gradeFormat)) at \(lo.angle)° → "
                         + "\(kilterDisplayGrade(catalog.gradeLabel(hi.difficulty), gradeFormat)) at \(hi.angle)°")
                        .snappetDetail()
                }
            }
            .snappetPanel()
            .padding(.horizontal)
        }
    }

    /// Tighten the chart's y-range around the climb's grades so small differences are visible.
    private var chartYDomain: ClosedRange<Double> {
        let ds = stats.map(\.difficulty)
        let lo = (ds.min() ?? 0) - 1, hi = (ds.max() ?? 1) + 1
        return lo...max(hi, lo + 1)
    }

    /// While a session is live, a compact "session active" + live-HR row above the log buttons, so
    /// the climber sees their heart rate without leaving the climb.
    @ViewBuilder private var sessionStatusRow: some View {
        if sessions.isActive {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Session").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                if app.liveWorkout.state != .unavailable {
                    KilterHRPill(bpm: app.liveWorkout.latestHR, compact: true,
                                 contactLost: app.liveWorkout.isContactLost == true,
                                 readiness: RecoveryReadiness.evaluate(
                                    currentBpm: app.liveWorkout.latestHR,
                                    restBpm: app.userProfile.profile.restingBound,
                                    maxBpm: app.userProfile.profile.resolvedMaxHR))
                }
                Spacer(minLength: 4)
                // For a plan-backed run, the climb screen is a station in the plan: back to the list, or on to
                // the next pending pick — a forward loop, not a back-button hunt.
                if sessions.currentPlanId != nil { planStrip }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.hairline))
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kilter.session.activeRow")
        }
    }

    private var planStrip: some View {
        HStack(spacing: 8) {
            Button {
                // Reset to the Kilter root + push the plan, rather than appending another
                // KilterPlanRoute onto a stack that already has Plan→Climb below (which would accrete
                // a stale Plan/Climb pair every loop). open() replaces the path, so this reaches the
                // plan-home cleanly from any entry — the dominant Plan→Climb flow and an off-plan
                // climb reached from the catalog alike. Same pattern the live chip / Home card use.
                router.open(module: "kilter")
                router.push(KilterPlanRoute())
            } label: {
                Label("Plan", systemImage: "chevron.left")
                    .font(SnappetType.detail.weight(.medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.climb.backToPlan")
            if let p = sessions.planProgress {
                Text("\(p.done)/\(p.total)")
                    .font(SnappetType.detail).monospacedDigit().foregroundStyle(SnappetColor.textSecondary)
            }
            if let next = sessions.nextPlanClimb(excluding: currentUUID) {
                Button { withAnimation(.snappy) { logConfirmation = nil; currentUUID = next } } label: {
                    HStack(spacing: 3) {
                        Text("Next pick"); Image(systemName: "chevron.right")
                    }
                    .font(SnappetType.detail.weight(.medium))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.climb.nextPick")
            } else {
                Text("Plan done").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .foregroundStyle(SnappetColor.brand)
    }

    private var logButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log this climb").snappetLabel()
            HStack(spacing: 8) {
                logButton(.flash, "bolt.fill")
                logButton(.sent, "checkmark")
            }
            HStack(spacing: 8) {
                logButton(.project, "target")
                logButton(.attempt, "arrow.uturn.up")
            }
            if let logConfirmation {
                Label(logConfirmation, systemImage: "checkmark.circle.fill")
                    .font(SnappetType.detail).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: logConfirmation)
                    .transition(.opacity)
                    .accessibilityIdentifier("kilter.logConfirmation")
            }
            autoStartCapsule
        }
        .snappetPanel()
        .padding(.horizontal)
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
            .font(SnappetType.detail)
            .transition(.opacity)
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

    private func logButton(_ status: KilterAscentStatus, _ image: String) -> some View {
        Button { log(status) } label: {
            Label(status.label, systemImage: image)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .snappetPill(selected: false, large: true, tint: status.isSend ? .green : .orange)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.log.\(status.rawValue)")
    }

    /// The connected or let-go board's name, for "Lighting on Gym · left…" (prompt 207).
    private var sharedBoardLabel: String? {
        (board.connectedIdentifier ?? board.releasedBoardID).flatMap { boardMemory.recall(identifier: $0)?.label }
    }

    @ViewBuilder private var illuminateSection: some View {
        // Simulators / devices with no BLE radio never show the section — there's nothing to connect to.
        if board.state != .unsupported {
            VStack(spacing: 8) {
                HStack {
                    Text("Board").snappetLabel()
                    Spacer()
                    if board.isConnected {
                        Label(sharedBoardLabel ?? "Connected", systemImage: "circle.fill")
                            .labelStyle(KilterDotLabelStyle())
                            .font(SnappetType.label).foregroundStyle(.green)
                    }
                }
                switch board.state {
                case .connected:
                    primaryButton("Light up this climb", systemImage: "lightbulb.fill") {
                        attemptLight()
                    }
                    KilterBoardShareStatus(board: board)
                    Divider().overlay(SnappetColor.hairline).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Set up this board ›") { showingBoardSetup = true }
                            .accessibilityIdentifier("kilter.board.setup")
                        Button(boardPhoto == nil ? "Add a photo of this board ›" : "Board photo ›") { showingBoardPhoto = true }
                            .accessibilityIdentifier("kilter.boardPhoto.open")
                        wrongHoldsControl
                        Button("Disconnect board") { board.disconnect() }
                            .foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("kilter.board.disconnect")
                    }
                    .font(SnappetType.detail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .connecting where board.isRelighting:
                    busyRow("Lighting on \(sharedBoardLabel ?? "the board")…")

                case .idle where board.isReleased:
                    // Prompt 207: let go while idle — the climb stays lit, the session carries on.
                    if let busy = board.busyMessage {
                        statusNote(busy, systemImage: "person.2.slash.fill", tint: .orange)
                            .accessibilityIdentifier("kilter.board.busy")
                        HStack {
                            primaryButton("Try again", systemImage: "arrow.clockwise") { board.retryLight() }
                            Button("Another board") { board.connect() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("kilter.board.anotherBoard")
                        }
                    } else {
                        statusNote("Still lit — the board is free for others. Light a climb and Snappet reconnects.",
                                   systemImage: "person.2.fill", tint: .secondary)
                            .accessibilityIdentifier("kilter.board.released")
                        primaryButton("Light this climb", systemImage: "lightbulb.fill") { attemptLight() }
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
            .snappetPanel()
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
            Button("Wrong holds lighting up? ›") { withAnimation(.snappy) { showingProtocolFix = true } }
                .font(SnappetType.detail)
                .accessibilityIdentifier("kilter.board.wrongHolds")
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(SnappetWidePrimaryStyle())
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
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("kilter.board.connecting")
    }

    private func statusNote(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(SnappetType.detail)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    // MARK: - Videos from this session (prompt 214)

    /// This session's clips tagged to the climb on screen: tap one = the clip studio (same as the session page),
    /// ＋ Tag a clip = the Tag clips sheet, Find new clips = the session's Photos search, Edit all = every video of
    /// this climb in the studio. Only while a session is live.
    @ViewBuilder private var sessionClipsCard: some View {
        if sessions.isActive {
            let mine = sessionClips.filter { $0.assignedClimbUUID == currentUUID }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Videos from this session").snappetLabel()
                    Spacer()
                    if !mine.isEmpty { Text("\(mine.count) of this climb").snappetLabel() }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mine) { m in
                            Button { openClip(m) } label: {
                                SessionMediaThumb(item: m, side: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("kilter.sessionClips.clip")
                        }
                        Button { showingTagClips = true } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 18))
                                Text("Tag a clip").font(SnappetType.label)
                            }
                            .foregroundStyle(SnappetColor.brand)
                            .frame(width: 92, height: 92)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(SnappetColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.sessionClips.tag")
                    }
                }
                HStack {
                    Button { Task { await findNewClips() } } label: {
                        Label(findingClips ? "Searching…" : "Find new clips", systemImage: "magnifyingglass")
                    }
                    .disabled(findingClips)
                    .accessibilityIdentifier("kilter.sessionClips.find")
                    Spacer()
                    if mine.contains(where: { $0.kind == .video }) {
                        Button("Edit all ›") { openClip(nil) }
                            .foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("kilter.sessionClips.editAll")
                    }
                }
                .font(SnappetType.detail)
                .foregroundStyle(SnappetColor.brand)
            }
            .snappetPanel()
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kilter.sessionClips")
        }
    }

    /// Re-read the live session's clips (reels excluded) and its climbs' names.
    private func reloadSessionClips() {
        guard let sid = sessions.currentId else { sessionClips = []; sessionClimbNames = [:]; return }
        sessionClips = (try? modelContext.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid && $0.reelTitle == nil },
            sortBy: [SortDescriptor(\.offsetSec, order: .reverse)]))) ?? []
        let entries = (try? modelContext.fetch(FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.sessionId == sid }))) ?? []
        var names: [String: String] = [:]
        for e in entries { names[e.climbUUID] = e.climbName }
        if let c = climb { names[c.uuid] = c.name }
        sessionClimbNames = names
    }

    /// The session page's "Find my clips": Photos access, then discovery for the live session.
    private func findNewClips() async {
        guard let sid = sessions.currentId else { return }
        findingClips = true
        _ = await app.sessionMedia.requestAccess()
        sessions.importMedia(forSessionID: sid, in: modelContext)
        reloadSessionClips()
        findingClips = false
    }

    /// One clip (videos only — photos aren't clip-editable) or, with nil, every video of this climb.
    private func openClip(_ clip: SessionMedia?) {
        guard let session = sessions.current else { return }
        if let clip, clip.kind != .video { return }
        sessions.syncLiveHR(in: modelContext)
        let sid = session.id
        let all = (try? modelContext.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let project = KilterStudioProjects.resolve(session, media: all, in: modelContext)
        let mineVideos = Set(sessionClips.filter { $0.assignedClimbUUID == currentUUID && $0.kind == .video }.map(\.id))
        clipStudio = ClimbClipStudio(project: project, sessionId: session.id,
                                     visible: clip.map { [$0.id] } ?? mineVideos,
                                     focus: clip?.id, single: clip)
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
        // Keep a connected board in sync with the climb on screen (initial open + each swipe). Opening or
        // swiping to a climb with a board on the wall lights it for real, so it counts as worked and is
        // captured for On the Board (prompt 121). Only fires with a board connected, so browsing on the
        // simulator (no wall-light) records nothing.
        // Opening / swiping lights it only with "Light climbs automatically" on (a released board reconnects, 207).
        if board.canLight, KilterAutoLight.shouldLight(.openOrSwipe, automatic: autoLight, litByYou: litByYou) {
            illuminateAndCapture()
        }
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

    /// Send the current climb's holds to the board AND — when a board is actually on the wall — record the
    /// wall-light as a deduped `KilterLitEvent` ("On the Board"). This is the single funnel every light
    /// site in this screen flows through (explicit "Light up this climb" button, the fast-path board pill,
    /// and the auto-lights on connect / swipe / size remap), so the policy is uniform: a climb counts as
    /// worked exactly when its holds reach a *connected* board (prompt 121). Capture is skipped when no
    /// board is connected (a swipe or size remap on the simulator just updates the on-screen render), so a
    /// light that never reached the wall isn't logged. The capture lives HERE — at the illuminate call
    /// site where the climb identity / session / size are known — never in the platform-pure
    /// `KilterBoardController` (which only sees `[KilterHold]`). The authoring preview (`CreateClimbView`)
    /// is intentionally NOT routed through this, so design previews don't pollute the worked-climbs history.
    private func illuminateAndCapture() {
        litClimbUUID = climb?.uuid
        board.illuminate(holds)
        if board.canLight { captureLitEvent() }
    }

    /// Whether the "Set up this board" verifier should intercept a light: a board is connected but the user
    /// hasn't confirmed its layout/size on the wall yet (prompt 120). Recall returns non-nil for a board
    /// that merely connected (it's auto-remembered from a *guess*), so we gate on the explicit `isVerified`
    /// flag, not on mere presence. False with no BLE (simulator) so lighting the on-screen board still works.
    private var needsBoardSetup: Bool {
        guard let id = board.connectedIdentifier else { return false }
        return boardMemory.recall(identifier: id)?.isVerified != true
    }

    /// Light the climb, but divert an unverified board to the setup verifier first (one-time per board).
    private func attemptLight() {
        if needsBoardSetup { showingBoardSetup = true; return }
        illuminateAndCapture()
    }

    /// Persist a confirmed "Set up this board" choice: mark this board verified with the chosen layout/size,
    /// repoint browsing at that layout, and remap the current size. Recording the lit event (when the open
    /// climb belongs to the confirmed layout) preserves the original "I lit this climb" intent that the
    /// setup diversion interrupted; a foreign-layout confirmation just leaves the calibration up.
    private func confirmBoardSetup(layoutId: Int, sizeId: Int) {
        if let id = board.connectedIdentifier {
            boardMemory.confirmSetup(identifier: id, layoutId: layoutId, productSizeId: sizeId)
        }
        activeLayoutId = layoutId
        productSizeId = sizeId            // triggers the size onChange → rebuilds holds/geometry + re-lights
        if climb?.layoutId == layoutId { captureLitEvent() }
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

/// "● Gym · left wall" — a small coloured dot before the text.
private struct KilterDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

/// The full-width filled accent button (Light up this climb / Try again / Connect board).
struct SnappetWidePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(SnappetColor.onBrand)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(SnappetColor.brand, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
