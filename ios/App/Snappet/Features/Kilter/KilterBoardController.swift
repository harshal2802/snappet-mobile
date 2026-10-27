import CoreBluetooth
import Foundation
import HealthKit
import HighlightEngine
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

    /// The simulator has no BLE radio, but CoreBluetooth only reports `.unsupported` after a
    /// `CBCentralManager` exists — and creating one is deferred to the first `connect()` so the
    /// permission prompt never fires from mere browsing. Seed the known-at-compile-time answer
    /// instead, so radio-less devices show the session pitch (not a Connect that can't work).
    #if targetEnvironment(simulator)
    private(set) var state: State = .unsupported
    #else
    private(set) var state: State = .idle
    #endif
    var isConnected: Bool { state == .connected }
    /// The stable `CBPeripheral.identifier` of the board currently connected (nil unless connected). Lets a
    /// view bind a confirmed "Set up this board" choice (prompt 120) to the right physical board directly,
    /// without having to capture the one-shot `onBoardRecognized` callback.
    var connectedIdentifier: UUID? { isConnected ? peripheral?.identifier : nil }
    /// Which Aurora payload dialect to send. Default `.v3` (current boards); switched to `.v2` when a
    /// user with an older board reports the wrong holds lighting up. Persisted by the UI layer, which
    /// pushes it down via `setAPILevel(_:)`.
    private(set) var apiLevel: KilterProtocol.APILevel = .v3
    /// The most recently requested holds, so a protocol switch can re-light the current climb at once.
    private var lastHolds: [KilterHold] = []
    /// Notified when the connection comes up / goes down, so the module can open/close a session.
    var onConnectionChange: ((Bool) -> Void)?
    /// Fired once on a **confirmed** connect (the right write characteristic), with the board's stable
    /// `CBPeripheral.identifier` and the `#serial` parsed from its advertised local name (if any). P1's
    /// board-memory uses this to recall a previously-connected board and restore its layout/size +
    /// pre-select the usual angle (a one-tap confirm — never a silent overwrite). Additive: when unset,
    /// connect behaves exactly as before.
    var onBoardRecognized: ((_ identifier: UUID, _ serial: String?) -> Void)?
    /// The advertised local name from the most recent scan match, kept so the confirmed-connect hook can
    /// extract the board's `#serial`. A system-connected / identifier-adopted board (no scan) leaves this
    /// `nil`, and recall still works by identifier.
    private var lastAdvertisedName: String?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    /// Holds set while waiting for the characteristic to be discovered.
    private var pendingHolds: [KilterHold]?
    /// Set the moment the user taps Connect; lets us start scanning as soon as the radio reports
    /// `.poweredOn` (which can arrive after the tap on first launch / permission prompt).
    private var wantsToConnect = false
    /// Identifier of the last board we successfully reached, persisted across launches. Tried in
    /// parallel with the scan (`retrievePeripherals(withIdentifiers:)`) for a board iOS hasn't cached
    /// our service for — so `retrieveConnectedPeripherals(withServices:)` misses it.
    private static let lastBoardKey = "kilter.lastBoardID"
    private var lastBoardIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastBoardKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastBoardKey) }
    }
    /// Boards connected before (the view passes `KilterBoardMemory`'s ids) — connect at once when heard,
    /// and win over a stranger's board (prompt 204).
    var knownBoardIDs: Set<UUID> = []
    /// Watchdog that fails the attempt if scan/connect/discovery stalls.
    private var timeout: Task<Void, Never>?

    // MARK: Attempt bookkeeping (prompt 204 — `KilterConnectPolicy` makes the calls)
    /// Attempts made for the current tap of Connect (first + automatic retries).
    private var attempt = 0
    /// The remembered board's pending connect, racing the scan. `nil` once something is chosen.
    private var racingRememberedID: UUID?
    private var scanStartedAt: Date?
    /// Boards heard in this scan, with their latest signal.
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int, name: String?)] = [:]
    private var selection: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Lets a dropped board go after `KilterConnectPolicy.reconnectWindow`.
    private var reconnectGiveUp: Task<Void, Never>?
    /// The link dropped and iOS is reconnecting on its own (auto-reconnect). The UI says "Reconnecting…".
    private(set) var isReconnecting = false
    /// Set on a reconnect so the board isn't "recognized" (and its confirm ribbon shown) a second time.
    private var hasRecognizedThisLink = false

    // MARK: Sharing the board (prompt 207)

    /// The board Snappet let go of while idle — remembered so the next light reconnects to it directly.
    private(set) var releasedBoardID: UUID?
    /// Let go and still relightable (the climb stays lit on the wall; the session carries on).
    var isReleased: Bool { releasedBoardID != nil && !isConnected }
    /// Lighting a released board: reconnecting to it.
    private(set) var isRelighting = false
    /// When Snappet will let go of the board (`nil` = holding it — sharing off, or not connected). The countdown.
    private(set) var letGoAt: Date?
    /// Lighting a released board got no answer: someone else holds it.
    private(set) var busyMessage: String?
    /// A light can reach a board: connected, or released and relightable.
    var canLight: Bool { isConnected || isReleased }
    /// Per-board sharing setting (the view supplies it from `KilterBoardMemory`).
    var sharingSetting: (UUID) -> KilterBoardSharing.Setting = { _ in .default }
    /// The board's name for messages ("Gym · left").
    var boardName: (UUID) -> String? = { _ in nil }
    private var letGoTask: Task<Void, Never>?

    // MARK: Several boards in range (prompt 205)

    /// A board heard in this scan, for the "N boards nearby" chooser.
    struct NearbyBoard: Identifiable, Equatable, Sendable {
        let id: UUID
        var advertisedName: String?
        var serial: String?
        var rssi: Int
        var isKnown: Bool
    }
    /// Two or more boards are in range: the UI asks which one (the scan keeps running to refresh signal).
    private(set) var isChoosing = false
    /// The boards on offer while choosing, strongest first.
    private(set) var nearbyBoards: [NearbyBoard] = []
    /// The board currently lit by "Flash", if any.
    private(set) var flashingID: UUID?
    private var flashPeripheral: CBPeripheral?
    private var flashTask: Task<Void, Never>?
    /// What "Flash" lights (corners + center for the current layout/size) — set by the view.
    var flashHolds: [KilterHold] = []

    /// Whether an advertising peripheral looks like an Aurora-family board (Kilter/Tension/etc).
    /// Pure so it can be unit-tested off-device. Aurora boards generally do **not** advertise their
    /// primary service UUID, only a local name — so name matching is the primary signal and scanning
    /// filtered by service UUID (the old behavior) would never discover them.
    nonisolated static func isLikelyBoard(name: String?, advertisedServiceUUIDs: [CBUUID]) -> Bool {
        if advertisedServiceUUIDs.contains(advertisedServiceUUID) { return true }
        guard let name = name?.lowercased() else { return false }
        return ["kilter", "aurora", "tension", "grasshopper", "decoy", "soill"].contains { name.contains($0) }
    }

    /// Begin connecting (lazily creates the central manager → triggers the permission prompt).
    /// Reflects intent immediately so the UI shows progress even before the radio finishes powering on.
    func connect() {
        guard !state.isBusy, state != .connected else { return }
        forgetReleased()
        wantsToConnect = true
        attempt = 0
        hasRecognizedThisLink = false
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

    /// One attempt. A board **already connected at the system level** (paired, or held by the official
    /// app on this phone) has stopped advertising, so it's adopted directly. Otherwise SCAN — and, on a
    /// first attempt, race a pending connect to the remembered board alongside it: an awake remembered
    /// board connects in well under a second, while an asleep / out-of-range / stale one no longer
    /// strands the attempt (it used to wait out the watchdog and fail without ever scanning).
    private func beginConnect() {
        guard let central, central.state == .poweredOn, wantsToConnect else { return }
        attempt += 1
        resetAttempt()
        let knownServices = [Self.gattServiceUUID, Self.advertisedServiceUUID]
        if let existing = central.retrieveConnectedPeripherals(withServices: knownServices).first {
            lastAdvertisedName = nil   // adopted, not scanned — no advert to read a serial from
            choose(existing)
            return
        }
        state = .scanning
        scanStartedAt = .now
        // No service filter: Aurora boards advertise by name, not service UUID (see `isLikelyBoard`).
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        startTimeout(KilterConnectPolicy.scanTimeout) { [weak self] in self?.attemptFailed(.scan) }
        if attempt == 1, let known = lastBoardIdentifier,
           let remembered = central.retrievePeripherals(withIdentifiers: [known]).first {
            racingRememberedID = remembered.identifier
            peripheral = remembered
            remembered.delegate = self
            central.connect(remembered, options: Self.connectOptions)
        }
    }

    /// Commit to one board: stop scanning, drop the racing remembered connect if it's a different board,
    /// connect, and watch connect + discovery.
    private func choose(_ chosen: CBPeripheral) {
        selection?.cancel(); selection = nil
        isChoosing = false
        nearbyBoards = []
        central?.stopScan()
        if let racing = racingRememberedID, racing != chosen.identifier, let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        racingRememberedID = nil
        peripheral = chosen
        chosen.delegate = self
        state = .connecting
        // Always ask, even for a board another app on this phone holds: CoreBluetooth then hands this
        // app the link (didConnect fires at once).
        if chosen.state != .connecting { central?.connect(chosen, options: Self.connectOptions) }
        startTimeout(KilterConnectPolicy.connectTimeout) { [weak self] in self?.attemptFailed(.connect) }
    }

    /// iOS 17+: if the link drops later, the system reconnects by itself (we're told via
    /// `isReconnecting`), so a board that blinks off mid-session comes back without a tap.
    private static let connectOptions: [String: Any] = [CBConnectPeripheralOptionEnableAutoReconnect: true]

    /// The scan heard a board. A known board connects at once; otherwise collect adverts for a short
    /// window and take the strongest (`KilterConnectPolicy.pick`). While the remembered board's connect is
    /// still pending, a different board must wait out its grace period first.
    private func heard(_ p: CBPeripheral, rssi: Int, name: String?) {
        guard state == .scanning else { return }
        let isNew = candidates[p.identifier] == nil
        candidates[p.identifier] = (p, rssi, name)
        if isChoosing {
            // Keep the list fresh (new boards, signal) without re-rendering on every advert.
            if isNew || abs((nearbyBoards.first { $0.id == p.identifier }?.rssi ?? rssi) - rssi) >= 4 { refreshNearby() }
            return
        }
        if p.identifier == racingRememberedID { return }   // its pending connect may complete on its own
        // Prompt 205 (Q2): even a known board waits out the short window — with 2+ boards in range the
        // climber picks; with one it connects as before.
        guard selection == nil else { return }
        let grace: Duration = racingRememberedID == nil ? .zero
            : max(.zero, KilterConnectPolicy.rememberedGrace - .seconds(Date.now.timeIntervalSince(scanStartedAt ?? .now)))
        selection = Task { [weak self] in
            try? await Task.sleep(for: max(KilterConnectPolicy.selectionWindow, grace))
            guard !Task.isCancelled else { return }
            self?.selectBest()
        }
    }

    private func selectBest() {
        selection = nil
        guard state == .scanning, !isChoosing else { return }
        let list = candidateList
        if KilterConnectPolicy.showsChooser(list) {
            beginChoosing()
            return
        }
        // One board: if it's the remembered one still connecting, let that finish; else connect to it.
        guard let best = KilterConnectPolicy.pick(list), let entry = candidates[best.id] else { return }
        if best.id == racingRememberedID { return }
        lastAdvertisedName = entry.name
        choose(entry.peripheral)
    }

    private var candidateList: [KilterConnectPolicy.Candidate] {
        candidates.values.map {
            KilterConnectPolicy.Candidate(id: $0.peripheral.identifier, rssi: $0.rssi, isKnown: isKnown($0.peripheral.identifier))
        }
    }

    /// Stop guessing: show the nearby boards and let the climber pick (the scan keeps refreshing the list).
    private func beginChoosing() {
        timeout?.cancel(); timeout = nil          // no scan watchdog while the climber decides
        if let racing = racingRememberedID, let p = peripheral, p.identifier == racing {
            central?.cancelPeripheralConnection(p)
            peripheral = nil
        }
        racingRememberedID = nil
        isChoosing = true
        refreshNearby()
    }

    private func refreshNearby() {
        nearbyBoards = KilterConnectPolicy.nearby(candidateList).compactMap { c in
            guard let entry = candidates[c.id] else { return nil }
            return NearbyBoard(id: c.id, advertisedName: entry.name,
                               serial: KilterBoardMemory.serial(fromLocalName: entry.name),
                               rssi: c.rssi, isKnown: c.isKnown)
        }
    }

    /// The climber picked a board from the chooser.
    func pick(_ id: UUID) {
        guard isChoosing, let entry = candidates[id] else { return }
        endFlash()
        lastAdvertisedName = entry.name
        choose(entry.peripheral)
    }

    /// Briefly light a board's corners so the climber can see which wall it is, then let it go (prompt 205).
    /// Replaces whatever that board shows for `KilterConnectPolicy.flashDuration`.
    func flash(_ id: UUID) {
        guard isChoosing, flashingID == nil, let entry = candidates[id] else { return }
        flashingID = id
        flashPeripheral = entry.peripheral
        entry.peripheral.delegate = self
        central?.connect(entry.peripheral)
        flashTask?.cancel()
        flashTask = Task { [weak self] in        // give up if the board never answers
            try? await Task.sleep(for: KilterConnectPolicy.connectTimeout)
            guard !Task.isCancelled else { return }
            self?.endFlash()
        }
    }

    private func endFlash() {
        flashTask?.cancel(); flashTask = nil
        if let p = flashPeripheral { central?.cancelPeripheralConnection(p) }
        flashPeripheral = nil
        flashingID = nil
    }

    private func flashLinkReady(_ p: CBPeripheral, _ characteristic: CBCharacteristic) {
        send(flashHolds, to: p, characteristic: characteristic)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: KilterConnectPolicy.flashDuration)
            guard !Task.isCancelled, let self else { return }
            self.send([], to: p, characteristic: characteristic)   // lights off before letting go
            self.endFlash()
        }
    }

    private func isKnown(_ id: UUID) -> Bool { knownBoardIDs.contains(id) || id == lastBoardIdentifier }

    /// An attempt stopped at `stage`: tear it down, then retry once (rescanning — the remembered board isn't
    /// raced again) or surface why.
    private func attemptFailed(_ stage: KilterConnectPolicy.Stage) {
        if isRelighting { relightFailed(); return }
        guard state.isBusy || isReconnecting else { return }
        let retry = wantsToConnect && KilterConnectPolicy.shouldRetry(after: stage, attempt: attempt)
        let wasReconnecting = isReconnecting
        tearDownLink()
        isReconnecting = false
        if wasReconnecting && !retry { onConnectionChange?(false) }
        if retry {
            state = .connecting
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: KilterConnectPolicy.retryDelay)
                guard !Task.isCancelled else { return }
                self?.beginConnect()
            }
        } else {
            wantsToConnect = false
            state = .failed(KilterConnectPolicy.failureMessage(stage))
        }
    }

    /// Let go of a board that dropped and is still reconnecting (prompt 204): after
    /// `KilterConnectPolicy.reconnectWindow`, when the session ends, or when the app goes to the background.
    /// Cancelling the connection also stops iOS's auto-reconnect, so the board is free for someone else's
    /// phone. A no-op unless a reconnect is in flight — a live link is never cut by this.
    func releaseIfReconnecting() {
        guard isReconnecting else { return }
        wantsToConnect = false
        retryTask?.cancel(); retryTask = nil
        isReconnecting = false
        tearDownLink()
        state = .failed(KilterConnectPolicy.gaveUpReconnectMessage)
        onConnectionChange?(false)
    }

    /// Stop everything in flight for this attempt (scan, selection, watchdog, the link) — not the intent.
    private func tearDownLink() {
        endFlash()
        isChoosing = false
        nearbyBoards = []
        reconnectGiveUp?.cancel(); reconnectGiveUp = nil
        timeout?.cancel(); timeout = nil
        selection?.cancel(); selection = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        racingRememberedID = nil
    }

    private func resetAttempt() {
        candidates = [:]
        racingRememberedID = nil
        selection?.cancel(); selection = nil
        retryTask?.cancel(); retryTask = nil
    }

    /// Cancel an in-flight scan/connect/reconnect and return to idle (the user backing out).
    func cancel() {
        if isRelighting { relightFailed(showBusy: false) }
        forgetReleased()
        wantsToConnect = false
        retryTask?.cancel(); retryTask = nil
        let wasReconnecting = isReconnecting
        isReconnecting = false
        tearDownLink()
        if state != .unsupported && state != .unauthorized && state != .bluetoothOff { state = .idle }
        if wasReconnecting { onConnectionChange?(false) }
    }

    func disconnect() {
        let wasReleased = isReleased
        forgetReleased()
        wantsToConnect = false
        retryTask?.cancel(); retryTask = nil
        // Capture before mutating: `cancelPeripheralConnection` triggers `didDisconnectPeripheral`
        // only *after* this returns, by which point `isConnected` is already false — so the session
        // is closed here, not there.
        let wasConnected = isConnected || isReconnecting
        isReconnecting = false
        tearDownLink()
        state = .idle
        if wasConnected || wasReleased { onConnectionChange?(false) }
    }

    // MARK: - Sharing the board (prompt 207)

    /// Let go of the board so others can connect. The climb stays lit (Aurora boards keep the last climb), the
    /// session carries on, and the next light reconnects to this board directly. Not reported as a
    /// disconnect, so the session bar keeps the board's name ("· free").
    func letGo() {
        guard isConnected, let p = peripheral else { return }
        letGoTask?.cancel(); letGoTask = nil
        letGoAt = nil
        releasedBoardID = p.identifier
        wantsToConnect = false
        tearDownLink()   // cancelling the link also stops iOS's auto-reconnect
        state = .idle
    }

    /// Going to the background: let go now if this board is shared (no point holding it while you're away).
    func letGoIfSharing() {
        guard isConnected, let id = peripheral?.identifier, sharingSetting(id).letGoWhenIdle else { return }
        letGo()
    }

    /// (Re)start the idle countdown after a light / a connect; holds indefinitely when sharing is off.
    private func scheduleLetGo() {
        letGoTask?.cancel(); letGoTask = nil
        guard isConnected, let id = peripheral?.identifier,
              let at = KilterBoardSharing.letGoAt(lastLight: .now, setting: sharingSetting(id)) else {
            letGoAt = nil
            return
        }
        letGoAt = at
        letGoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.letGo()
        }
    }

    /// Light a released board: connect to it directly (it's advertising again unless someone else took it).
    private func relight() {
        guard let id = releasedBoardID, let central, central.state == .poweredOn,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            busyMessage = KilterBoardSharing.busyMessage(board: releasedBoardID.flatMap(boardName))
            return
        }
        busyMessage = nil
        isRelighting = true
        hasRecognizedThisLink = true   // the same board — no second "recognized" ribbon / setup prompt
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: Self.connectOptions)
        startTimeout(KilterBoardSharing.relightTimeout) { [weak self] in self?.relightFailed() }
    }

    /// No answer from a released board: someone else is connected to it. Stay released so "Try again" works.
    private func relightFailed(showBusy: Bool = true) {
        let id = releasedBoardID
        isRelighting = false
        tearDownLink()
        state = .idle
        busyMessage = showBusy ? KilterBoardSharing.busyMessage(board: id.flatMap(boardName)) : nil
    }

    /// "Try again" after a busy board.
    func retryLight() {
        guard isReleased, !isRelighting, !lastHolds.isEmpty else { return }
        pendingHolds = lastHolds
        relight()
    }

    private func forgetReleased() {
        letGoTask?.cancel(); letGoTask = nil
        letGoAt = nil
        releasedBoardID = nil
        busyMessage = nil
        isRelighting = false
    }

    /// Watchdog: run `onFire` if the step it guards stalls.
    private func startTimeout(_ duration: Duration, onFire: @escaping @MainActor () -> Void) {
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            onFire()
        }
    }

    /// Light the given holds on the board (no-op unless connected). Stores them if the characteristic
    /// isn't discovered yet so they flush once ready.
    func illuminate(_ holds: [KilterHold]) {
        lastHolds = holds
        guard isConnected, let peripheral, let writeChar else {
            pendingHolds = holds
            // Released while idle (prompt 207): reconnect to the same board and light it.
            if isReleased, !isRelighting { relight() }
            return
        }
        send(holds, to: peripheral, characteristic: writeChar)
        scheduleLetGo()
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
                // or `.idle`) → start the attempt. Don't disturb an in-flight connect/connected.
                if wantsToConnect && state != .connecting && state != .connected {
                    attempt = 0
                    beginConnect()
                }
            case .poweredOff:
                let wasLinked = isConnected || isReconnecting
                isReconnecting = false
                tearDownLink()
                state = .bluetoothOff
                if wasLinked { onConnectionChange?(false) }
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
        let rssi = RSSI.intValue
        // CBUUID isn't Sendable; the assumeIsolated closure runs synchronously on this (main) thread.
        nonisolated(unsafe) let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            guard state == .scanning,
                  Self.isLikelyBoard(name: localName ?? peripheral.name,
                                     advertisedServiceUUIDs: advertisedServices) else { return }
            heard(peripheral, rssi: rssi, name: localName ?? peripheral.name)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            if peripheral.identifier == flashingID, peripheral.identifier == flashPeripheral?.identifier {
                peripheral.discoverServices([Self.gattServiceUUID])
                return
            }
            // Prompt 205: other boards are in range too → ask, don't take the remembered one silently.
            if peripheral.identifier == racingRememberedID, state == .scanning,
               candidates.keys.contains(where: { $0 != peripheral.identifier }) {
                selectBest()
                if isChoosing { return }
            }
            // The remembered board's pending connect won the race against the scan → it's the one.
            if peripheral.identifier == racingRememberedID, state == .scanning {
                selection?.cancel(); selection = nil
                self.central?.stopScan()
                racingRememberedID = nil
                lastAdvertisedName = nil
                state = .connecting
            }
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            // Keep the watchdog running across service/characteristic discovery — that's where a board
            // with an unexpected GATT layout would otherwise hang silently.
            if isRelighting {
                startTimeout(KilterBoardSharing.relightTimeout) { [weak self] in self?.relightFailed() }
            } else {
                startTimeout(KilterConnectPolicy.connectTimeout) { [weak self] in self?.attemptFailed(.discovery) }
            }
            peripheral.discoverServices([Self.gattServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            if peripheral.identifier == flashingID { endFlash(); return }
            // The remembered board's racing connect failing is fine — the scan carries on.
            if peripheral.identifier == racingRememberedID, state == .scanning {
                racingRememberedID = nil
                self.peripheral = nil
                return
            }
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            attemptFailed(.connect)
        }
    }

    /// iOS 17+ disconnect callback (replaces the plain one when implemented): `isReconnecting` says the
    /// system is already bringing the link back (we connected with auto-reconnect).
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            if peripheral.identifier == flashingID, peripheral.identifier != self.peripheral?.identifier {
                flashTask?.cancel(); flashTask = nil
                flashPeripheral = nil; flashingID = nil
                return
            }
            // The remembered board's racing connect dropping is fine — the scan carries on.
            if peripheral.identifier == racingRememberedID, state == .scanning {
                racingRememberedID = nil
                self.peripheral = nil
                return
            }
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            let wasConnected = isConnected
            writeChar = nil
            letGoTask?.cancel(); letGoTask = nil
            letGoAt = nil
            if wasConnected && isReconnecting {
                // A mid-session drop iOS is repairing: hold the session, say so, re-light on return.
                self.isReconnecting = true
                state = .connecting
                pendingHolds = lastHolds.isEmpty ? nil : lastHolds
                timeout?.cancel(); timeout = nil
                // If the returning link then fails discovery, allow one fresh attempt (a rescan).
                wantsToConnect = true
                attempt = KilterConnectPolicy.maxAttempts - 1
                reconnectGiveUp?.cancel()
                reconnectGiveUp = Task { [weak self] in
                    try? await Task.sleep(for: KilterConnectPolicy.reconnectWindow)
                    guard !Task.isCancelled else { return }
                    self?.releaseIfReconnecting()
                }
                return
            }
            if state.isBusy || self.isReconnecting {
                // Dropped before the board was ready — routine BLE flakiness; retry once.
                attemptFailed(.connect)
                return
            }
            timeout?.cancel(); timeout = nil
            self.peripheral = nil
            if let error, wasConnected {
                state = .failed("The board disconnected: \(error.localizedDescription). Tap Connect to reconnect.")
            } else if case .failed = state {
                // A watchdog failure already set its message and initiated this disconnect.
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
            if peripheral.identifier == flashingID, peripheral.identifier != self.peripheral?.identifier {
                let services = (peripheral.services ?? []).filter { $0.uuid == Self.gattServiceUUID }
                guard error == nil, !services.isEmpty else { endFlash(); return }
                for service in services { peripheral.discoverCharacteristics([Self.writeUUID], for: service) }
                return
            }
            let services = (peripheral.services ?? []).filter { $0.uuid == Self.gattServiceUUID }
            // No lighting service (or an error) → fail fast (and retry once) instead of waiting out the
            // watchdog in silence.
            guard error == nil, !services.isEmpty else { attemptFailed(.discovery); return }
            for service in services {
                peripheral.discoverCharacteristics([Self.writeUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated {
            if peripheral.identifier == flashingID, peripheral.identifier != self.peripheral?.identifier {
                guard let characteristic = (service.characteristics ?? []).first(where: { $0.uuid == Self.writeUUID })
                else { endFlash(); return }
                flashLinkReady(peripheral, characteristic)
                return
            }
            guard let characteristic = (service.characteristics ?? []).first(where: { $0.uuid == Self.writeUUID }) else {
                attemptFailed(.discovery)
                return
            }
            timeout?.cancel(); timeout = nil
            wantsToConnect = false
            let reconnected = isReconnecting
            isReconnecting = false
            // Lighting a released board (prompt 207): the same board, back for one light.
            let relit = isRelighting
            isRelighting = false
            releasedBoardID = nil
            busyMessage = nil
            reconnectGiveUp?.cancel(); reconnectGiveUp = nil
            writeChar = characteristic
            // Remember this board now that it's confirmed (right write characteristic) — only here,
            // so the identifier-based path never targets a device that wasn't really a board.
            lastBoardIdentifier = peripheral.identifier
            state = .connected
            // Recognize the board (P1) once per link — a reconnect is the same board, no second ribbon.
            if (!reconnected && !relit) || !hasRecognizedThisLink {
                hasRecognizedThisLink = true
                onBoardRecognized?(peripheral.identifier,
                                   KilterBoardMemory.serial(fromLocalName: lastAdvertisedName))
            }
            onConnectionChange?(true)
            if let pending = pendingHolds {
                pendingHolds = nil
                send(pending, to: peripheral, characteristic: characteristic)
            }
            scheduleLetGo()
        }
    }
}

/// Tracks the active board session so logged ascents can be grouped in History, and — when bound to
/// the app's live-metrics + Live-Activity + media services — drives **live heart rate**, a **Lock
/// Screen / Dynamic Island Live Activity**, **per-climb timing**, and **post-session media
/// discovery** for the session (workout-grade parity, decisions.md 2026-06-06). Created at the module
/// root and shared via the environment. A session opens when a board connects (source `"ble"`),
/// when the user starts one manually, or — undoably — on the first climb logged with no session
/// live (source `"auto"`, #75); it closes when the user ends it (never on a mere BLE disconnect).
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

    /// The planned session pinned to the live `KilterSession` (`KilterPlan.id`), when the run was
    /// started from "Plan a session" — so the plan-home and the cross-screen live chip can find the
    /// frozen plan, and the log path can tick its items. `nil` for an ad-hoc session (started from the
    /// catalog, a BLE connect, or the first idle log) until a plan is attached.
    private(set) var currentPlanId: UUID?

    /// Live progress of the pinned plan as `(done, total)` for the cross-screen live chip — `nil` for
    /// an ad-hoc session with no plan. Kept in lockstep with the plan on attach / log / adopt, and
    /// cleared whenever the session ends. Stored (not computed) so the `@Observable` chip ticks on it
    /// without a SwiftData fetch.
    private(set) var planProgress: (done: Int, total: Int)?

    /// The pinned plan's still-`pending` picks in plan order — backs the climb screen's "Next pick →"
    /// loop without a per-render fetch (the climb screen re-renders on every HR tick). Kept in lockstep
    /// with `planProgress`; empty when no plan is live.
    private(set) var planPendingUUIDs: [String] = []

    /// Live Activity board label (no per-board name today).
    private let boardName = "Kilter Board"

    // Services wired once by `AppModel.init` via `bind(...)` — at construction, not on a view's
    // appear, so a deep link that skips the root (Home → plan) can't start an unbound session
    // (#71 review). Strong refs to AppModel-owned siblings; no cycle (none reference the manager).
    private var liveWorkout: LiveMetricsCoordinator?
    private var liveActivity: KilterLiveActivityController?
    private var media: SessionMediaService?
    /// The shared on-device HR profile (Phase 2), used to personalize the session's `maxHR`/`restHR`
    /// and a BLE calorie estimate on `end`, and to send the resolved max HR to the watch + Live
    /// Activity. A strong ref to an AppModel-owned singleton (outlives this manager — no cycle).
    private var userProfile: UserProfileStore?
    /// Post-hoc HealthKit reader (AppModel-owned `health`), used to densify a watch session's sparse HR
    /// series after it ends (prompt 102). `nil` leaves the live buffer as-is (the pre-densify behavior).
    private var health: HealthKitService?

    /// Whether *this* session started the live-metrics source — so `end()` only flushes/stops HR it
    /// owns. Guards against a Kilter session that opened while a WorkoutTracker workout was already
    /// running: it must not steal that workout's HR buffer or stop its source.
    private var didStartMetrics = false

    /// Inject the live-metrics + Live-Activity + media services so the manager can drive HR / the
    /// Live Activity / media discovery. Idempotent; called once from `AppModel.init` (all four are
    /// AppModel-owned siblings), so the manager is bound before any view — or deep link — can start
    /// a session.
    func bind(liveWorkout: LiveMetricsCoordinator,
              liveActivity: KilterLiveActivityController,
              media: SessionMediaService,
              userProfile: UserProfileStore? = nil,
              health: HealthKitService? = nil) {
        self.liveWorkout = liveWorkout
        self.liveActivity = liveActivity
        self.media = media
        self.userProfile = userProfile
        self.health = health
    }

    /// Returns `true` only when this call **created a fresh session** — `false` when a session was
    /// already current or recovery adopted an open one. The auto-start-on-log path (#75) keys its
    /// "Session started · Undo" confirmation on this: undoing must only ever delete a session the
    /// log itself created, never one adopted from the store.
    @discardableResult
    func start(angle: Int, source: String, layoutId: Int? = nil, in context: ModelContext) -> Bool {
        guard current == nil else { return false }
        // Re-sync with the store BEFORE creating anything (#71 review): recovery adopts the newest
        // still-fresh open session instead of forking a duplicate (single-open invariant) and
        // auto-closes duplicate / long-abandoned opens at their last activity. Folding it here —
        // not only on the root's appear — applies the #54 stale-session policy on EVERY path that
        // can start a session: the root menu, a BLE connect, the first log of an idle climber
        // (source "auto", #75), and deep links that skip `KilterRootView` (Home → plan, QR → climb).
        recover(in: context)
        if current != nil { return false }   // recovery adopted the open session — nothing to create
        let session = KilterSession(angle: angle, source: source, layoutId: layoutId)
        context.insert(session)
        current = session
        resetActiveClimb()
        // Begin live HR capture (Apple Watch or BLE band, whichever the coordinator resolves) — but
        // only if no workout is already driving a source (we must not commandeer a running workout).
        let maxHR = userProfile?.profile.resolvedMaxHR
        if let liveWorkout, !liveWorkout.isSessionActive {
            liveWorkout.start(LiveMetricsContext(startedAt: session.startedAt, activityType: .climbing,
                                                 maxHR: maxHR, restHR: userProfile?.profile.restingBound))
            didStartMetrics = true
        }
        try? context.save()
        // Lock Screen / Dynamic Island live session widget (no-op if unavailable/unauthorized).
        liveActivity?.start(boardName: boardName, startedAt: session.startedAt, angle: angle, maxHR: maxHR)
        return true
    }

    /// Undo a just-created session (the auto-start-on-log confirmation, #75): **keep the logs,
    /// drop the session** — entries logged into it detach (`sessionId = nil`, exactly the pre-#75
    /// idle-log shape), live metrics stop only if this start owned them (never a running workout's
    /// source), the Live Activity ends, and the row is deleted. Only called for a session `start`
    /// reported as freshly created — an adopted/recovered session must never be deleted by an undo.
    func undoStart(in context: ModelContext) {
        guard let session = current else { return }
        let sid = session.id
        let attached = (try? context.fetch(FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.sessionId == sid }))) ?? []
        for entry in attached { entry.sessionId = nil }
        // A plan only exists on the Plan-view start path (not the auto-start path this undo serves),
        // but a plan must never outlive the session it was pinned to — drop it with the session.
        if let plan = openPlan(forSession: sid, in: context) { context.delete(plan) }
        if didStartMetrics {
            liveWorkout?.stop()
            didStartMetrics = false
        }
        liveActivity?.end()
        // Cascade, not a bare delete: a clip filmed in the seconds before the undo would
        // otherwise orphan its SessionMedia row (prompt 125).
        SessionCascade.deleteKilterSession(session, in: context)
        try? context.save()
        current = nil
        currentPlanId = nil
        planProgress = nil
        planPendingUUIDs = []
        resetActiveClimb()
    }

    /// Re-sync the manager with the persisted store — the single source of truth for "what session is
    /// open". Called on `KilterRootView` appear / after a relaunch, and by `start` before it creates a
    /// session: with no in-memory session, it adopts the newest open `KilterSession`, **closes** any
    /// duplicate or long-abandoned opens (the pure `KilterSessionRecovery`), and re-attaches HR
    /// ownership + the Live Activity. Idempotent and a near-no-op once a session is already live, so
    /// it's safe to call on every appear / every start.
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
        for closure in plan.close {
            byID[closure.id]?.endedAt = closure.endedAt   // auto-close dups/abandoned
            // Close the pinned plan in lockstep too — otherwise an auto-closed (abandoned/duplicate)
            // session leaks a permanently-open KilterPlan row that bloats the store + every backup.
            // Mirrors end(sessionID:); stamps at the session's own close time.
            openPlan(forSession: closure.id, in: context)?.completedAt = closure.endedAt
        }
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
            if isCurrent { current = nil; currentPlanId = nil; planProgress = nil; planPendingUUIDs = []; resetActiveClimb() }
            return
        }
        session.endedAt = .now
        // Close the plan pinned to this session in lockstep, so it stops being "open" — no orphaned
        // KilterPlan rows accumulating across sessions, and an ended session's plan can never resurface
        // as the active one. (PR's user-facing "Finish plan" later routes through here.)
        openPlan(forSession: sessionID, in: context)?.completedAt = .now
        // Flush the live HR buffer onto the session BEFORE stopping the source (mirrors
        // WorkoutTracker.finishWorkout) — only when this session owns the source. Stamp the source
        // label from the actually-captured data, so it's never a misleading default.
        if isCurrent, didStartMetrics, let liveWorkout {
            session.hrSeries = WorkoutHRStats.points(from: liveWorkout.samples)
            if !session.hrSeries.isEmpty {
                let profile = userProfile?.profile ?? .empty
                session.metricsSourceRaw = liveWorkout.activeKind.rawValue
                session.maxHR = profile.resolvedMaxHR
                session.restHR = profile.restingBound
                // Calories are BLE-only (the watch measures real energy; never override it).
                if liveWorkout.activeKind == .ble {
                    session.kcalEstimate = profile.estimatedKcal(forSeries: session.hrSeries,
                                                                 durationSec: session.duration)
                }
            }
            liveWorkout.stop()
            didStartMetrics = false
        }
        // Recap feed (F0b): append-only, idempotent session activity (safe on the recovery path).
        FeedActivityWriter.recordKilterSessionFinish(session, in: context)
        try? context.save()
        liveActivity?.end()
        if isCurrent { current = nil; currentPlanId = nil; planProgress = nil; planPendingUUIDs = []; resetActiveClimb() }
        // Auto-discover photos/videos shot during the session window and tag them to the session + the
        // climb they fall within. Best-effort; only runs with full Photos access.
        discoverMedia(for: session, in: context)
        // Watch sessions persist a SPARSE live-relay HR series; once HealthKit has synced the on-wrist
        // workout, backfill the denser stored series (prompt 102). Best-effort + idempotent: HK often
        // hasn't synced yet at `end()`, so the session-detail `.task` re-attempts the catch-up. No-op for
        // BLE / already-dense sessions (guarded inside).
        let sid = session.id
        Task { await densifyHRFromHealthKit(sessionID: sid, in: context) }
    }

    /// Backfill a finished **watch** session's sparse HR series from HealthKit's complete on-wrist series
    /// (prompt 102). The live `WCSession` relay surfaces HR only ~every 5–15 s, but the `HKWorkoutSession`
    /// stored ~1 per 1–5 s — so re-reading the session window recovers the interior detail the relay
    /// thinned (the flat clip-overlay fix for watch users). Idempotent and cheap to re-run:
    ///
    /// - **BLE / unknown source** → skip (BLE is already dense AND carries RR a HealthKit read lacks).
    /// - **Already dense** (`HRCadence.perSecond ≥ 0.5`) → skip, so a re-open or a prior densify doesn't
    ///   re-query HealthKit.
    /// - else read `[startedAt, endedAt]`, keep the **denser** of {stored, HealthKit}, save only if it grew.
    ///
    /// Device-gated: returns a no-op on the simulator / without a synced `HKWorkout`. Pure choice logic is
    /// `HRSeriesDensify.denser`, unit-tested.
    func densifyHRFromHealthKit(sessionID: UUID, in context: ModelContext) async {
        guard let health else { return }
        guard let session = (try? context.fetch(FetchDescriptor<KilterSession>(
            predicate: #Predicate { $0.id == sessionID })))?.first,
              let endedAt = session.endedAt,
              session.metricsSourceRaw == MetricsSourceKind.appleWatch.rawValue else { return }
        // Already dense enough? Don't bother HealthKit (covers re-opens + the post-densify state).
        if HRCadence.summarize(session.hrSeries).perSecond >= 0.5 { return }
        let hk = (try? await health.heartRateSamples(start: session.startedAt, end: endedAt)) ?? []
        guard !hk.isEmpty else { return }
        let merged = HRSeriesDensify.denser(live: session.hrSeries,
                                            healthKit: WorkoutHRStats.points(from: hk))
        guard merged.count > session.hrSeries.count else { return }
        session.hrSeries = merged
        try? context.save()
    }

    // MARK: - Planned session (KilterPlan)

    /// Pin a freshly-created `KilterPlan` to the live session and freeze it — the recommender never
    /// rebuilds it again; the plan-home and live chip read it back by `sessionId`, and the log path
    /// ticks its items. Called by `KilterPlanView` right after `start`. No-op with no live session.
    ///
    /// Enforces **one open plan per session**: any *other* open plan already pinned to this session is
    /// closed first, so a deep-link race (a `start` that adopts a stale open session which already had
    /// a plan) can't leave two open plans fighting over one session — which would make the tick and the
    /// rendered order non-deterministic (both readers use an unordered `.first`).
    func attachPlan(_ plan: KilterPlan, in context: ModelContext) {
        guard let id = current?.id else { return }
        if let existing = openPlan(forSession: id, in: context), existing.id != plan.id {
            existing.completedAt = .now
        }
        plan.sessionId = id
        currentPlanId = plan.id
        planProgress = KilterPlanProgress.progress(plan.items)
        planPendingUUIDs = KilterPlanProgress.pendingClimbUUIDs(plan.items)
    }

    /// Tick the active plan when a climb is logged: flip the lowest-order matching `pending`
    /// `KilterPlanItem` to sent/attempted (a later send upgrades an attempted one). Done-state is read
    /// straight off the plan — never re-derived from logs + the recommender — so a completed
    /// send/project pick can no longer be filtered out and reshuffled. No-op for an ad-hoc session
    /// (no pinned plan) or an off-plan climb.
    func applyLogToPlan(climbUUID: String, ascent: KilterAscentStatus, at date: Date,
                        in context: ModelContext) {
        guard let sid = current?.id, let plan = openPlan(forSession: sid, in: context) else { return }
        let updated = KilterPlanProgress.applyingLog(climbUUID: climbUUID, ascent: ascent,
                                                     at: date, to: plan.items)
        guard updated != plan.items else { return }
        plan.items = updated
        currentPlanId = plan.id
        planProgress = KilterPlanProgress.progress(updated)
        planPendingUUIDs = KilterPlanProgress.pendingClimbUUIDs(updated)
        try? context.save()
    }

    /// Skip a pending plan pick (a deliberate "not today") — flips it to `.skipped` so it leaves the
    /// "next up" rotation without counting as done. Drives the plan-home swipe action; keeps the
    /// progress/pending caches in lockstep. No-op for an ad-hoc session or an unknown id.
    func skipPlanItem(id: UUID, in context: ModelContext) {
        guard let sid = current?.id, let plan = openPlan(forSession: sid, in: context) else { return }
        let updated = KilterPlanProgress.skipping(id: id, in: plan.items)
        guard updated != plan.items else { return }
        plan.items = updated
        planProgress = KilterPlanProgress.progress(updated)
        planPendingUUIDs = KilterPlanProgress.pendingClimbUUIDs(updated)
        try? context.save()
    }

    /// The open (un-finished) plan pinned to a session, if any.
    func openPlan(forSession sid: UUID, in context: ModelContext) -> KilterPlan? {
        (try? context.fetch(FetchDescriptor<KilterPlan>(
            predicate: #Predicate { $0.sessionId == sid && $0.completedAt == nil })))?.first
    }

    /// The next pick to climb in the pinned plan — advancing by **plan order**: the pending pick
    /// immediately after `uuid` in the ordered pending list (so "Next pick" always moves forward, even
    /// when the current climb wasn't logged — a plain "first pending that isn't me" oscillates between
    /// the first two pending picks). When `uuid` isn't pending (already logged/skipped, or off-plan),
    /// falls back to the earliest pending pick. `nil` when there's no plan or nothing else pending.
    /// Reads the cached `planPendingUUIDs` (no fetch) so the climb screen can call it on every HR tick.
    func nextPlanClimb(excluding uuid: String?) -> String? {
        guard let uuid, let idx = planPendingUUIDs.firstIndex(of: uuid) else {
            return planPendingUUIDs.first
        }
        return idx + 1 < planPendingUUIDs.count ? planPendingUUIDs[idx + 1] : nil
    }

    /// Drop every reference into the store WITHOUT writing to it — the suite restore
    /// (`SnappetBackup.restore`) is about to DELETE every row, including the live `KilterSession`
    /// this manager may hold; a later write through `current` would trap on the deleted `@Model`
    /// (or resurrect a zombie row via the context), and the Live Activity would keep counting a
    /// session that no longer exists. Called by `BackupView.runRestore()` immediately before the
    /// restore. Deliberately persists nothing (no `endedAt`, no `save()`): the rows are seconds
    /// from deletion, and the restored data carries its own truth — `recover(in:)` re-adopts any
    /// open session from it on the next Kilter entry (the #54 recovery semantics). Stops live
    /// metrics only when this manager started them (never a running workout's source).
    func detachForStoreRestore() {
        if didStartMetrics {
            liveWorkout?.stop()
            didStartMetrics = false
        }
        liveActivity?.end()
        current = nil
        currentPlanId = nil
        planProgress = nil
        planPendingUUIDs = []
        resetActiveClimb()
    }

    /// Make an already-persisted open session the live one, re-deriving live state from the store + the
    /// shared coordinator. Used by `recover` (which `start` also runs) when a session is already open.
    private func adopt(_ session: KilterSession, in context: ModelContext) {
        current = session
        resetActiveClimb()
        // Re-establish the pinned plan (if this session was started from "Plan a session") so the
        // plan-home + live chip recover it after a relaunch / navigating back into Kilter.
        if let plan = openPlan(forSession: session.id, in: context) {
            currentPlanId = plan.id
            planProgress = KilterPlanProgress.progress(plan.items)
            planPendingUUIDs = KilterPlanProgress.pendingClimbUUIDs(plan.items)
        } else {
            currentPlanId = nil
            planProgress = nil
            planPendingUUIDs = []
        }
        // The shared metrics coordinator outlives the manager. If it's still streaming, this recovered
        // session owns it (so `end` flushes + stops HR); otherwise we don't resurrect HR for a session
        // recovered after a relaunch (the early buffer is gone — same stance as WorkoutTracker).
        didStartMetrics = liveWorkout?.isSessionActive ?? false
        // Re-attach the Live Activity: adopt one still on the Lock Screen, else (re)start it so the
        // recovered session is visible again. No-op where Live Activities are unavailable.
        if let liveActivity, !liveActivity.adoptRunningActivity() {
            liveActivity.start(boardName: boardName, startedAt: session.startedAt, angle: session.angle,
                               maxHR: session.maxHR ?? userProfile?.profile.resolvedMaxHR)
        }
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

    /// Flush the live HR buffer onto the **active** session WITHOUT ending it, so clip HR overlays and
    /// the summary chart can show heart rate *during* the session — not only after it ends. The
    /// coordinator's buffer is cumulative (samples from the session start), so this overwrites
    /// `hrSeries` with everything captured so far (it always covers any earlier clip's window). No-op
    /// when there's no active session this manager owns the metrics for, or the buffer is still empty.
    /// Called on opening the session summary, after each log, and before opening a clip.
    func syncLiveHR(in context: ModelContext) {
        guard let session = current, didStartMetrics, let liveWorkout else { return }
        let points = WorkoutHRStats.points(from: liveWorkout.samples)
        guard !points.isEmpty else { return }
        session.hrSeries = points
        session.metricsSourceRaw = liveWorkout.activeKind.rawValue
        try? context.save()
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
        let profile = userProfile?.profile ?? .empty
        let ready = RecoveryReadiness.evaluate(currentBpm: hrBpm.map(Double.init),
                                               restBpm: profile.restingBound,
                                               maxBpm: profile.resolvedMaxHR).state == .ready
        return KilterLiveSnapshot(
            startedAt: session.startedAt, hrBpm: hrBpm,
            currentClimbName: activeClimbName, currentGrade: activeClimbGrade,
            climbCount: climbCount, paused: liveWorkout?.isPaused ?? false,
            recoveryReady: ready)
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
        // If we're finding clips for the *live* session, flush HR first so the just-discovered clips
        // can overlay heart rate immediately (not only after the session ends).
        if current?.id == id { syncLiveHR(in: context) }
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
        // Global — not session-scoped — dedup set (R2/R4): see `SessionMedia.allIdentifiers`.
        let existing = SessionMedia.allIdentifiers(in: context)
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
}
