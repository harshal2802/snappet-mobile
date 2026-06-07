import CoreBluetooth
import Foundation
import HealthKit
import SwiftData

/// Drives the physical Kilter board over Bluetooth LE: scan → connect → write the illumination
/// packets built by `KilterProtocol`. On-device only (BLE is local radio; no network).
///
/// ⚠️ Device-unverified. The service/characteristic UUIDs and packet format follow the community
/// reverse-engineering of the Aurora protocol; this has **not** been confirmed on real hardware, so
/// per the repo's device-only rule it must not be reported as working until validated on a board.
/// Everything here is inert until the user explicitly taps Connect — Phase 1 never touches it.
@MainActor
@Observable
final class KilterBoardController: NSObject {
    enum State: Equatable {
        case unsupported          // no BLE radio / simulator — nothing to offer
        case bluetoothOff         // radio present but powered off — ask the user to turn it on
        case unauthorized         // Bluetooth permission denied — deep-link to Settings
        case idle
        case scanning
        case connecting
        case connected
        case failed(String)

        /// A scan/connect attempt is in flight (button should show progress + a Cancel affordance).
        var isBusy: Bool { self == .scanning || self == .connecting }
    }

    // Aurora/Kilter board BLE addressing. Two distinct UUIDs — conflating them was the connect bug:
    //  * `advertisedServiceUUID` is what the board *advertises* (used only to recognise it while
    //    scanning / to retrieve a system-connected board); it is not where illumination data is written.
    //  * the writable endpoint is the **Nordic UART** GATT service + characteristic, shared by the whole
    //    Aurora family (Kilter / Tension / Grasshopper / …) — there is no per-board variation here.
    // `nonisolated(unsafe)`: CBUUID isn't Sendable, but these are immutable constants, so the
    // pure (nonisolated) `isLikelyBoard` matcher can read `advertisedServiceUUID` safely.
    nonisolated(unsafe) private static let advertisedServiceUUID = CBUUID(string: "4488B571-7806-4DF6-BCFF-A2897E4953FF")
    nonisolated(unsafe) private static let gattServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) private static let writeUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    /// How long to look for a board before giving up, and how long a single GATT
    /// connect + discovery may take. CoreBluetooth's own `connect(_:)` never times out, so without
    /// these a missing/asleep board leaves the UI wedged on "Connecting…" forever (the reported bug).
    private static let scanTimeout: Duration = .seconds(12)
    private static let connectTimeout: Duration = .seconds(12)

    private(set) var state: State = .idle
    var isConnected: Bool { state == .connected }
    /// Which Aurora payload dialect to send. Default `.v3` (current boards); switched to `.v2` when a
    /// user with an older board reports the wrong holds lighting up. Persisted by the UI layer, which
    /// pushes it down via `setAPILevel(_:)`.
    private(set) var apiLevel: KilterProtocol.APILevel = .v3
    /// The most recently requested holds, so a protocol switch can re-light the current climb at once.
    private var lastHolds: [KilterHold] = []
    /// Notified when the connection comes up / goes down, so the module can open/close a session.
    var onConnectionChange: ((Bool) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    /// Holds set while waiting for the characteristic to be discovered.
    private var pendingHolds: [KilterHold]?
    /// Set the moment the user taps Connect; lets us start scanning as soon as the radio reports
    /// `.poweredOn` (which can arrive after the tap on first launch / permission prompt).
    private var wantsToConnect = false
    /// Identifier of the last board we successfully reached, persisted across launches. Used as the
    /// second adopt path (`retrievePeripherals(withIdentifiers:)`) for a paired board that iOS hasn't
    /// cached our service for — so `retrieveConnectedPeripherals(withServices:)` misses it.
    private static let lastBoardKey = "kilter.lastBoardID"
    private var lastBoardIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastBoardKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastBoardKey) }
    }
    /// Watchdog that fails the attempt if scan/connect/discovery stalls.
    private var timeout: Task<Void, Never>?

    /// Whether an advertising peripheral looks like an Aurora-family board (Kilter/Tension/etc).
    /// Pure so it can be unit-tested off-device. Aurora boards generally do **not** advertise their
    /// primary service UUID, only a local name — so name matching is the primary signal and scanning
    /// filtered by service UUID (the old behavior) would never discover them.
    nonisolated static func isLikelyBoard(name: String?, advertisedServiceUUIDs: [CBUUID]) -> Bool {
        if advertisedServiceUUIDs.contains(advertisedServiceUUID) { return true }
        guard let name = name?.lowercased() else { return false }
        return ["kilter", "aurora", "tension", "grasshopper", "decoy", "soill"].contains { name.contains($0) }
    }

    /// Begin scanning for a board (lazily creates the central manager → triggers the permission prompt).
    /// Reflects intent immediately so the UI shows progress even before the radio finishes powering on.
    func connect() {
        wantsToConnect = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // nil queue → main
        }
        guard let central else { return }
        switch central.state {
        case .poweredOn: beginConnect()
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .scanning   // .unknown / .resetting — wait for didUpdateState
        }
    }

    /// Adopt a board that's **already connected at the system level** (paired in Settings, or held by
    /// the official Aurora/Kilter app) before falling back to a scan. Such a board has stopped
    /// advertising, so a scan would never re-discover it — this was the reported "won't connect, but
    /// the Kilter app connects fine" case. Two adopt paths, then scan:
    ///
    /// 1. `retrieveConnectedPeripherals(withServices:)` — returns the board when iOS has cached that it
    ///    exposes our service (typically because the official app discovered it).
    /// 2. `retrievePeripherals(withIdentifiers:)` with our last-connected board's id — covers a paired
    ///    board iOS *hasn't* cached our service for, so path 1 comes back empty. `connect(_:)` then
    ///    reaches it if it's available (the watchdog fails the attempt otherwise).
    private func beginConnect() {
        guard let central, central.state == .poweredOn else { return }
        let knownServices = [Self.gattServiceUUID, Self.advertisedServiceUUID]
        if let existing = central.retrieveConnectedPeripherals(withServices: knownServices).first {
            connect(to: existing)
        } else if let known = lastBoardIdentifier,
                  let remembered = central.retrievePeripherals(withIdentifiers: [known]).first {
            connect(to: remembered)
        } else {
            beginScan()
        }
    }

    /// Connect to a chosen peripheral (from a system-connected lookup or a scan match) and start the
    /// watchdog over connect + discovery.
    private func connect(to peripheral: CBPeripheral) {
        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central?.connect(peripheral)
        startTimeout(Self.connectTimeout,
                     message: "Couldn't reach the board. Move closer and try again.")
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        state = .scanning
        // No service filter: Aurora boards advertise by name, not service UUID (see `isLikelyBoard`).
        central.scanForPeripherals(withServices: nil)
        startTimeout(Self.scanTimeout,
                     message: "No board found nearby. Make sure it's powered on and within range.")
    }

    /// Cancel an in-flight scan/connect and return to idle (the user backing out of a stuck attempt).
    func cancel() {
        wantsToConnect = false
        timeout?.cancel(); timeout = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        if state != .unsupported && state != .unauthorized && state != .bluetoothOff { state = .idle }
    }

    func disconnect() {
        wantsToConnect = false
        timeout?.cancel(); timeout = nil
        central?.stopScan()
        // Capture before mutating: `cancelPeripheralConnection` triggers `didDisconnectPeripheral`
        // only *after* this returns, by which point `isConnected` is already false — so the session
        // is closed here, not there.
        let wasConnected = isConnected
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        state = .idle
        if wasConnected { onConnectionChange?(false) }
    }

    /// Watchdog: fail the attempt (and tear down any half-open connection) if a step stalls.
    private func startTimeout(_ duration: Duration, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.timedOut(message)
        }
    }

    private func timedOut(_ message: String) {
        guard state.isBusy else { return }
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        wantsToConnect = false
        state = .failed(message)
    }

    /// Light the given holds on the board (no-op unless connected). Stores them if the characteristic
    /// isn't discovered yet so they flush once ready.
    func illuminate(_ holds: [KilterHold]) {
        lastHolds = holds
        guard isConnected, let peripheral, let writeChar else {
            pendingHolds = holds
            return
        }
        send(holds, to: peripheral, characteristic: writeChar)
    }

    /// Switch the payload dialect and, if a climb is currently lit, re-send it so the change shows on
    /// the wall immediately. No-op when unchanged — safe to call on every settings sync.
    func setAPILevel(_ level: KilterProtocol.APILevel) {
        guard level != apiLevel else { return }
        apiLevel = level
        if isConnected, !lastHolds.isEmpty { illuminate(lastHolds) }
    }

    private func send(_ holds: [KilterHold], to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let payload = holds.compactMap { hold -> (position: Int, colorHex: String)? in
            guard let pos = hold.ledPosition else { return nil }
            return (pos, hold.ledColorHex)   // the board's LED color, not the on-screen color
        }
        let mode: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        for message in KilterProtocol.messages(for: payload, level: apiLevel) {
            peripheral.writeValue(Data(message), for: characteristic, type: mode)
        }
    }
}

extension KilterBoardController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Delegate callbacks arrive on the main queue (`queue: nil`), so hopping to the main actor is
        // safe; the non-Sendable CB object is marked unsafe to satisfy Swift 6 region isolation.
        nonisolated(unsafe) let central = central
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                // Radio came up after the user tapped Connect (state was the placeholder `.scanning`
                // or `.idle`) → adopt a system-connected board or start the scan. Don't disturb an
                // in-flight connect/connected.
                if wantsToConnect && state != .connecting && state != .connected { beginConnect() }
            case .poweredOff:
                state = .bluetoothOff
            case .unauthorized:
                state = .unauthorized
            case .unsupported:
                state = .unsupported
            default:
                break   // .unknown / .resetting — transient; wait for the next update
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        nonisolated(unsafe) let peripheral = peripheral
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // CBUUID isn't Sendable; the assumeIsolated closure runs synchronously on this (main) thread.
        nonisolated(unsafe) let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            guard state == .scanning,
                  Self.isLikelyBoard(name: localName ?? peripheral.name,
                                     advertisedServiceUUIDs: advertisedServices) else { return }
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            // Keep the watchdog running across service/characteristic discovery — that's where a board
            // with an unexpected GATT layout would otherwise hang silently.
            startTimeout(Self.connectTimeout,
                         message: "Connected, but the board didn't respond. Try again.")
            peripheral.discoverServices([Self.gattServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            timeout?.cancel(); timeout = nil
            wantsToConnect = false
            self.peripheral = nil
            state = .failed(error?.localizedDescription ?? "Couldn't connect to the board.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            timeout?.cancel(); timeout = nil
            wantsToConnect = false
            let wasConnected = isConnected
            self.peripheral = nil
            writeChar = nil
            // An unexpected drop (error) while connected is worth surfacing; a clean disconnect isn't.
            if let error, wasConnected {
                state = .failed("The board disconnected: \(error.localizedDescription)")
            } else if case .failed = state {
                // A watchdog timeout already set a failure message and *initiated* this disconnect
                // (its own `cancelPeripheralConnection`). Don't wipe that message back to idle.
            } else {
                state = .idle
            }
            if wasConnected { onConnectionChange?(false) }
        }
    }
}

extension KilterBoardController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] where service.uuid == Self.gattServiceUUID {
                peripheral.discoverCharacteristics([Self.writeUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.writeUUID {
                timeout?.cancel(); timeout = nil
                wantsToConnect = false
                writeChar = characteristic
                // Remember this board now that it's confirmed (right write characteristic) — only here,
                // so the identifier-based adopt path never targets a device that wasn't really a board.
                lastBoardIdentifier = peripheral.identifier
                state = .connected
                onConnectionChange?(true)
                if let pending = pendingHolds {
                    pendingHolds = nil
                    send(pending, to: peripheral, characteristic: characteristic)
                }
            }
        }
    }
}

/// Tracks the active board session so logged ascents can be grouped in History, and — when bound to
/// the app's live-metrics + Live-Activity + media services — drives **live heart rate**, a **Lock
/// Screen / Dynamic Island Live Activity**, **per-climb timing**, and **post-session media
/// discovery** for the session (workout-grade parity, decisions.md 2026-06-06). Created at the module
/// root and shared via the environment. A session opens when a board connects (source `"ble"`) or
/// when the user starts one manually, and closes on disconnect / when the user ends it.
@MainActor
@Observable
final class KilterSessionManager {
    private(set) var current: KilterSession?
    var isActive: Bool { current != nil }
    var currentId: UUID? { current?.id }

    /// The climb currently being worked while a session is live — for the HUD, the Live Activity, and
    /// per-climb timing. `activeClimbStartedAt` stamps when the climber moved onto it.
    private(set) var activeClimbUUID: String?
    private(set) var activeClimbName: String = "Resting"
    private(set) var activeClimbGrade: String = ""
    private(set) var activeClimbStartedAt: Date?

    /// Live Activity board label (no per-board name today).
    private let boardName = "Kilter Board"

    // Services wired once by `KilterRootView` via `bind(...)`. Strong refs to AppModel-owned
    // singletons, which outlive this manager — no retain cycle (AppModel doesn't hold the manager).
    private var liveWorkout: LiveMetricsCoordinator?
    private var liveActivity: KilterLiveActivityController?
    private var media: SessionMediaService?

    /// Whether *this* session started the live-metrics source — so `end()` only flushes/stops HR it
    /// owns. Guards against a Kilter session that opened while a WorkoutTracker workout was already
    /// running: it must not steal that workout's HR buffer or stop its source.
    private var didStartMetrics = false

    /// Inject the live-metrics + Live-Activity + media services so the manager can drive HR / the
    /// Live Activity / media discovery. Idempotent; called from the root view on appear.
    func bind(liveWorkout: LiveMetricsCoordinator,
              liveActivity: KilterLiveActivityController,
              media: SessionMediaService) {
        self.liveWorkout = liveWorkout
        self.liveActivity = liveActivity
        self.media = media
    }

    func start(angle: Int, source: String, in context: ModelContext) {
        guard current == nil else { return }
        // Single-open invariant: if a session is already open in the store — survived a manager reset,
        // a relaunch, or was opened via the other start path — adopt it instead of forking a duplicate.
        if let open = newestOpenSession(in: context) { adopt(open, in: context); return }
        let session = KilterSession(angle: angle, source: source)
        context.insert(session)
        current = session
        resetActiveClimb()
        // Begin live HR capture (Apple Watch or BLE band, whichever the coordinator resolves) — but
        // only if no workout is already driving a source (we must not commandeer a running workout).
        if let liveWorkout, !liveWorkout.isSessionActive {
            liveWorkout.start(LiveMetricsContext(startedAt: session.startedAt, activityType: .climbing))
            didStartMetrics = true
        }
        try? context.save()
        // Lock Screen / Dynamic Island live session widget (no-op if unavailable/unauthorized).
        liveActivity?.start(boardName: boardName, startedAt: session.startedAt, angle: angle)
    }

    /// Re-sync the manager with the persisted store — the single source of truth for "what session is
    /// open". Called on `KilterRootView` appear / after a relaunch: with no in-memory session, it adopts
    /// the newest open `KilterSession`, **closes** any duplicate or long-abandoned opens (the pure
    /// `KilterSessionRecovery`), and re-attaches HR ownership + the Live Activity. Idempotent and a
    /// near-no-op once a session is already live, so it's safe to call on every appear.
    func recover(in context: ModelContext) {
        guard current == nil else { return }
        let openSessions = (try? context.fetch(FetchDescriptor<KilterSession>(
            predicate: #Predicate { $0.endedAt == nil }))) ?? []
        guard !openSessions.isEmpty else { return }
        let plan = KilterSessionRecovery.plan(
            open: openSessions.map {
                KilterSessionRecovery.Candidate(id: $0.id, startedAt: $0.startedAt,
                                                lastActivity: lastActivity(of: $0, in: context))
            },
            now: .now)
        let byID = Dictionary(openSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for closure in plan.close { byID[closure.id]?.endedAt = closure.endedAt }   // auto-close dups/abandoned
        if let adoptID = plan.adopt, let session = byID[adoptID] { adopt(session, in: context) }
        try? context.save()
    }

    func end(in context: ModelContext) {
        guard let id = current?.id else { return }
        end(sessionID: id, in: context)
    }

    /// End a session **by id** — works whether or not it's the in-memory `current` one, so the live
    /// bar, the summary, and History can all close a session (including a recovered/orphaned one). HR is
    /// flushed + the source stopped only when this manager owns the live metrics for that session.
    func end(sessionID: UUID, in context: ModelContext) {
        let isCurrent = current?.id == sessionID
        let session: KilterSession? = isCurrent
            ? current
            : (try? context.fetch(FetchDescriptor<KilterSession>(
                predicate: #Predicate { $0.id == sessionID })))?.first
        guard let session, session.endedAt == nil else {
            if isCurrent { current = nil; resetActiveClimb() }
            return
        }
        session.endedAt = .now
        // Flush the live HR buffer onto the session BEFORE stopping the source (mirrors
        // WorkoutTracker.finishWorkout) — only when this session owns the source. Stamp the source
        // label from the actually-captured data, so it's never a misleading default.
        if isCurrent, didStartMetrics, let liveWorkout {
            session.hrSeries = WorkoutHRStats.points(from: liveWorkout.samples)
            if !session.hrSeries.isEmpty { session.metricsSourceRaw = liveWorkout.activeKind.rawValue }
            liveWorkout.stop()
            didStartMetrics = false
        }
        try? context.save()
        liveActivity?.end()
        if isCurrent { current = nil; resetActiveClimb() }
        // Auto-discover photos/videos shot during the session window and tag them to the session + the
        // climb they fall within. Best-effort; only runs with full Photos access.
        discoverMedia(for: session, in: context)
    }

    /// Make an already-persisted open session the live one, re-deriving live state from the store + the
    /// shared coordinator. Used by `recover` and by `start` when a session is already open.
    private func adopt(_ session: KilterSession, in context: ModelContext) {
        current = session
        resetActiveClimb()
        // The shared metrics coordinator outlives the manager. If it's still streaming, this recovered
        // session owns it (so `end` flushes + stops HR); otherwise we don't resurrect HR for a session
        // recovered after a relaunch (the early buffer is gone — same stance as WorkoutTracker).
        didStartMetrics = liveWorkout?.isSessionActive ?? false
        // Re-attach the Live Activity: adopt one still on the Lock Screen, else (re)start it so the
        // recovered session is visible again. No-op where Live Activities are unavailable.
        if let liveActivity, !liveActivity.adoptRunningActivity() {
            liveActivity.start(boardName: boardName, startedAt: session.startedAt, angle: session.angle)
        }
    }

    /// The newest still-open (`endedAt == nil`) session in the store, if any.
    private func newestOpenSession(in context: ModelContext) -> KilterSession? {
        var d = FetchDescriptor<KilterSession>(predicate: #Predicate { $0.endedAt == nil },
                                               sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// The last real activity in a session — newest log time, else the start — used to stamp an
    /// auto-close at when climbing actually stopped (not "now").
    private func lastActivity(of session: KilterSession, in context: ModelContext) -> Date {
        let sid = session.id
        let entries = (try? context.fetch(FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.sessionId == sid }))) ?? []
        let lastLog = entries.map { $0.endedAt ?? $0.date }.max()
        return max(session.startedAt, lastLog ?? session.startedAt)
    }

    /// Mark the climb now on screen as the active one (called from the detail view's `load()` on the
    /// initial open + each swipe, and on each log). Stamps the start when the climb changes, or when
    /// it's been disarmed by a prior send (`activeClimbStartedAt == nil`) — but not on a plain swipe
    /// back to the same in-progress climb, so its timer isn't reset.
    func beginClimb(uuid: String, name: String, grade: String) {
        guard isActive, uuid != activeClimbUUID || activeClimbStartedAt == nil else { return }
        activeClimbUUID = uuid
        activeClimbName = name
        activeClimbGrade = grade
        activeClimbStartedAt = .now
    }

    /// Called after a successful send (Flash/Sent) — the climb is done, so go back to "Resting" and
    /// let the next climb's timing/rest start fresh.
    func closeActiveClimb() { resetActiveClimb() }

    /// The current live snapshot for the HUD + Live Activity, or `nil` when no session is active.
    func liveSnapshot(hrBpm: Int?, climbCount: Int) -> KilterLiveSnapshot? {
        guard let session = current else { return nil }
        return KilterLiveSnapshot(
            startedAt: session.startedAt, hrBpm: hrBpm,
            currentClimbName: activeClimbName, currentGrade: activeClimbGrade,
            climbCount: climbCount, paused: liveWorkout?.isPaused ?? false)
    }

    /// Push a throttled update to the Live Activity (called by the detail view as HR / the active
    /// climb / the climb count change while the session is visible).
    func pushLiveActivity(hrBpm: Int?, climbCount: Int) {
        guard let snap = liveSnapshot(hrBpm: hrBpm, climbCount: climbCount) else { return }
        liveActivity?.update(snap)
    }

    private func resetActiveClimb() {
        activeClimbUUID = nil
        activeClimbName = "Resting"
        activeClimbGrade = ""
        activeClimbStartedAt = nil
    }

    /// Re-run media discovery for a past session by id (the summary's "Find my clips" action, after
    /// the user has granted full Photos access). No-op if the session can't be found.
    func importMedia(forSessionID id: UUID, in context: ModelContext) {
        guard let session = try? context.fetch(
            FetchDescriptor<KilterSession>(predicate: #Predicate { $0.id == id })).first else { return }
        discoverMedia(for: session, in: context)
    }

    // MARK: - Media discovery (best-effort; full Photos access only)

    private func discoverMedia(for session: KilterSession, in context: ModelContext) {
        guard let media, media.canAutoDiscover else { return }
        let sessionID = session.id
        let startedAt = session.startedAt
        let completedAt = session.endedAt
        let windows = climbWindows(for: session, in: context)
        let existing = existingMediaIdentifiers(sessionID: sessionID, in: context)
        Task { @MainActor in
            guard let candidates = try? await media.discover(
                startedAt: startedAt, completedAt: completedAt, existingIdentifiers: existing)
            else { return }
            for c in candidates {
                let climbUUID = KilterMediaAssignment.climbUUID(forOffset: c.offsetSec, windows: windows)
                context.insert(SessionMedia(
                    sessionID: sessionID, localIdentifier: c.localIdentifier, kind: c.kind,
                    offsetSec: c.offsetSec, durationSec: c.durationSec,
                    assignedClimbUUID: climbUUID,
                    source: climbUUID != nil ? .auto : .general))
            }
            try? context.save()
        }
    }

    /// Each in-session climb's `[start, end]` window in seconds from the session start, for clip
    /// auto-assignment. Climbs without a recorded start are skipped (no window to match against).
    private func climbWindows(for session: KilterSession,
                              in context: ModelContext) -> [KilterMediaAssignment.ClimbWindow] {
        let sid = session.id
        let start = session.startedAt
        let entries = (try? context.fetch(
            FetchDescriptor<KilterLogEntry>(predicate: #Predicate { $0.sessionId == sid }))) ?? []
        return entries.compactMap { e in
            guard let s = e.startedAt else { return nil }
            let end = e.endedAt ?? e.date
            return KilterMediaAssignment.ClimbWindow(
                climbUUID: e.climbUUID,
                startOffset: max(0, s.timeIntervalSince(start)),
                endOffset: max(0, end.timeIntervalSince(start)))
        }
    }

    private func existingMediaIdentifiers(sessionID: UUID, in context: ModelContext) -> Set<String> {
        let rows = (try? context.fetch(
            FetchDescriptor<SessionMedia>(predicate: #Predicate { $0.sessionID == sessionID }))) ?? []
        return Set(rows.map(\.localIdentifier))
    }
}
