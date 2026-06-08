import Foundation
import Observation
import HighlightEngine
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// A discovered BLE heart-rate peripheral (a chest strap / band advertising the standard
/// Heart Rate Service). Identified by its `CBPeripheral.identifier` (a stable per-device
/// UUID on this phone) so the picker can offer "connect" and the coordinator can remember
/// the chosen one. Plain value type, no `CoreBluetooth` import, so the picker UI + tests
/// don't drag the framework in.
struct BLEDevice: Identifiable, Equatable, Sendable {
    let id: UUID          // CBPeripheral.identifier
    let name: String
    /// `true` when iOS already has this band connected at the system level (paired in
    /// Settings / actively connected) — surfaced via `retrieveConnectedPeripherals` so it
    /// appears **instantly**, without waiting for an advertising scan. These are the bands a
    /// plain scan misses, which is why an already-connected band "wasn't auto-detected".
    var isSystemConnected: Bool = false
}

/// Whether Bluetooth is usable for band detection, surfaced so the picker can show a clear,
/// actionable message instead of an endless "Scanning…" spinner when it can't possibly work.
enum BluetoothAvailability: Equatable, Sendable {
    /// Not yet determined (central not created / state unknown).
    case unknown
    /// The user declined the Bluetooth permission — needs a trip to Settings.
    case unauthorized
    /// Bluetooth is switched off — needs Control Center / Settings.
    case poweredOff
    /// Powered on and authorized; scanning + retrieval are live.
    case ready
}

/// Generic BLE heart-rate-band live-metrics source (RESEARCH.md §3.3, A3).
///
/// Non-Apple bands (chest straps, Polar / Garmin / Wahoo, any device exposing the standard
/// **Heart Rate Profile**) connect on-device via `CoreBluetooth` — service `0x180D`,
/// measurement characteristic `0x2A37` — **never** a cloud API (Fitbit/Google ruled out,
/// decisions.md 2026-06-01). The central scans for peripherals advertising `0x180D`,
/// exposes the discovered list for the picker, connects a chosen one, subscribes to
/// `0x2A37`, parses each Heart Rate Measurement, and emits `HRSample`s on the
/// `WorkoutSession.startedAt` timeline like the watch path. Energy isn't in the HR profile,
/// so `energy` stays `0`.
///
/// The HR-measurement byte parsing is isolated into the pure static `parseHeartRate(_:)` so
/// it is unit-testable without a device or a band.
///
/// **Verification honesty:** a real BLE connect + HR stream only runs on a device with a
/// physical band; a simulator/type-check proves the shape + the pure parser, not a live
/// stream.
@MainActor
@Observable
final class BLEHeartRateMetricsSource: NSObject, MetricsSource {

    private(set) var latestHR: Double?
    /// Always `0` — the Heart Rate Profile has no calorie/energy field (RESEARCH.md §3.3).
    let energy: Double = 0
    private(set) var samples: [HRSample] = []
    private(set) var state: MetricsSourceState = .unavailable
    private(set) var isReachable = false

    /// Whether the band currently reports the sensor has lost skin/strap contact — only when the
    /// band supports the optional Heart Rate Measurement sensor-contact flag. `nil` when it can't
    /// report contact (most generic straps), distinct from `false` ("contact is fine"). No-contact
    /// readings are dropped in `ingest` (bpm is garbage off-skin) and the UI shows "adjust strap".
    private(set) var isContactLost: Bool? = nil

    /// Coarse Bluetooth usability, for the picker's empty-state messaging.
    private(set) var availability: BluetoothAvailability = .unknown

    /// Bands the picker should offer: the system-connected bands (`retrieveConnectedPeripherals`)
    /// merged with the bands found by scanning, de-duplicated by identifier.
    private(set) var discovered: [BLEDevice] = []

    /// Raw split halves of `discovered`, kept so a new scan hit / system refresh can re-merge
    /// without losing the other half.
    private var systemConnected: [BLEDevice] = []
    private var scanned: [BLEDevice] = []

    /// Name of the connected band when known, else a generic label.
    private(set) var connectedName: String?
    var displayName: String { connectedName ?? "Heart-rate band" }

    /// The stable identifier of the band currently targeted/connected — the one the picker
    /// should mark active. Matching the UI on this (not `connectedName`) avoids mis-flagging
    /// rows when two bands share a model name, or when a still-unseen "Saved" row's name
    /// differs from the real peripheral's name. `nil` when no band is targeted.
    var activeDeviceID: UUID? {
        #if canImport(CoreBluetooth)
        desiredPeripheralID
        #else
        nil
        #endif
    }

    /// Persisted "my usual band" so it reconnects automatically next time (no re-picking).
    private let memory: BandMemory
    /// The remembered band, surfaced for the picker + the coordinator's source default.
    var rememberedID: UUID? { memory.rememberedID }
    var rememberedName: String? { memory.rememberedName }
    var hasRememberedBand: Bool { memory.hasRemembered }

    /// Whether there's a band to use **without** opening the picker — one is remembered, or one
    /// is already targeted/connected. Drives the coordinator's automatic source default so a
    /// returning band user lands on BLE with no taps.
    var hasKnownBand: Bool { memory.hasRemembered || connectedName != nil }

    /// The list the picker renders (discovered bands + the remembered band when it hasn't been
    /// rediscovered yet). Pure, so it's the same on-device and in tests.
    var displayDevices: [BLEDevice] {
        BLEBands.displayList(discovered: discovered,
                             rememberedID: memory.rememberedID,
                             rememberedName: memory.rememberedName)
    }

    /// Wall-clock session start, to re-base samples onto the engine's `HRSample.t` timeline
    /// (seconds since the session began) — same convention as the watch path.
    private var sessionStart: Date?

    /// Whether the connected band's RR-intervals are trusted for HRV (fitness-band Phase 3). Set on
    /// connect from the peripheral name and refined when the `0x2A24` model number is read; gates RR
    /// capture in `ingest`. Default-deny → an unknown band carries no RR (HRV degrades to bpm-only).
    private var rrTrusted = false

    // MARK: - Heart Rate GATT identifiers (RESEARCH.md §3.3)

    #if canImport(CoreBluetooth)
    // `nonisolated` so the off-actor CoreBluetooth delegate callbacks can read them.
    // `CBUUID` is immutable; constructing one is safe off the main actor.
    nonisolated(unsafe) static let heartRateServiceUUID = CBUUID(string: "180D")
    nonisolated(unsafe) static let heartRateMeasurementUUID = CBUUID(string: "2A37")
    // Device Information (0x180A) → Model Number String (0x2A24), read once on connect to refine RR
    // trust (fitness-band Phase 3). Optional — name-based trust covers bands that don't expose it.
    nonisolated(unsafe) static let deviceInfoServiceUUID = CBUUID(string: "180A")
    nonisolated(unsafe) static let modelNumberUUID = CBUUID(string: "2A24")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The identifier the user asked to connect to (we connect when scanning finds it).
    private var desiredPeripheralID: UUID?
    #endif

    init(memory: BandMemory = BandMemory()) {
        self.memory = memory
        super.init()
        #if canImport(CoreBluetooth)
        // Lazily create the central on first use so we don't trigger the Bluetooth
        // permission prompt at app launch — only when the user opens the source picker /
        // selects BLE, or (once a band is remembered → permission already granted) when a
        // session auto-reconnects. `prepare()` / `autoConnectIfRemembered()` do that.
        // Pre-seed the desired band from memory so a session can reconnect it before the
        // picker is ever opened.
        desiredPeripheralID = memory.rememberedID
        connectedName = memory.rememberedName
        #endif
    }

    /// Prepare the central **only if** the user has a remembered band — so a returning user's
    /// band reconnects automatically (the permission was already granted the first time), while
    /// a first-time user still gets the deliberate, prompt-on-open flow. Safe to call at launch.
    func autoConnectIfRemembered() {
        #if canImport(CoreBluetooth)
        guard memory.hasRemembered else { return }
        prepare()
        #endif
    }

    /// Spin up the `CBCentralManager` (triggers the one-time Bluetooth permission prompt)
    /// and begin scanning once powered on. Called when the user opens the HR-source picker.
    func prepare() {
        #if canImport(CoreBluetooth)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            // `startScanIfPossible` refreshes the system-connected list + tries an auto-connect
            // before (re)starting the advertising scan.
            startScanIfPossible()
        }
        #endif
    }

    /// Begin/resume scanning for `0x180D` advertisers (no-op if Bluetooth isn't ready).
    func startScan() {
        #if canImport(CoreBluetooth)
        // Clear the previous session's *scanned* discoveries so the picker doesn't show stale,
        // out-of-range advertisers — but keep the system-connected bands, which are still valid.
        scanned.removeAll()
        rebuildDiscovered()
        prepare()
        #endif
    }

    func stopScan() {
        #if canImport(CoreBluetooth)
        central?.stopScan()
        #endif
    }

    /// Connect to a discovered band. We hold the desired id and, if the peripheral is
    /// already known, connect immediately; otherwise the next scan hit connects it.
    func connect(_ device: BLEDevice) {
        #if canImport(CoreBluetooth)
        // Already connected/connecting to this exact band → don't downgrade a live `.streaming`
        // state back to `.connecting` on a double-tap.
        if desiredPeripheralID == device.id,
           state == .connecting || state == .connected || state == .streaming { return }
        // Switching bands: disconnect the previous one so we don't ingest from two at once.
        if let existing = peripheral { central?.cancelPeripheralConnection(existing) }
        peripheral = nil
        desiredPeripheralID = device.id
        connectedName = device.name
        // A deliberate pick re-opts-in: clear any Forget suppression so this band auto-connects
        // again (and gets remembered on connect). No-op for the auto paths, which never pick a
        // suppressed band.
        memory.allowAutoConnect(id: device.id)
        guard let central else { prepare(); return }
        if let known = central.retrievePeripherals(withIdentifiers: [device.id]).first {
            peripheral = known
            known.delegate = self
            state = .connecting
            central.connect(known, options: nil)
        } else {
            state = .connecting
        }
        #endif
    }

    // MARK: - MetricsSource

    func start(_ context: LiveMetricsContext) {
        // The BLE band has no notion of a workout "type" — it just streams HR. We reset the
        // buffer onto this session's timeline and (re)connect if a band was chosen.
        sessionStart = context.startedAt
        samples.removeAll()
        latestHR = nil
        isContactLost = nil
        #if canImport(CoreBluetooth)
        prepare()
        if let id = desiredPeripheralID,
           let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            state = .connecting
            central?.connect(known, options: nil)
        }
        #endif
    }

    func stop() {
        sessionStart = nil
        #if canImport(CoreBluetooth)
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        #endif
        isReachable = false
        // Reset from any active state (incl. `.connecting`, e.g. ending a workout before the band
        // finishes connecting) so a stale "Connecting…" doesn't persist; keep `.unavailable` (BT off).
        if state != .unavailable { state = .idle }
    }

    // MARK: - Sample ingestion (test seam)

    /// Ingest a parsed bpm (and optional sensor-contact state) at wall-clock `receivedAt`, re-based
    /// onto the session timeline. Pure given `sessionStart`, so it is unit-testable without a device.
    ///
    /// `contact == false` (band reports the strap is off-skin / loose): the bpm is garbage, so DROP
    /// it — don't append, don't move `latestHR` (the pill keeps the last good value), don't flip to
    /// `.streaming` — and raise `isContactLost` so the UI shows "adjust strap". `contact == true`
    /// clears the flag and ingests normally; `nil` (the band can't report contact) ingests as before.
    func ingest(bpm: Double, contact: Bool? = nil, rrIntervalsMs: [Double]? = nil, receivedAt: Date = .now) {
        if contact == false {
            isContactLost = true
            return
        }
        if contact == true { isContactLost = false }
        latestHR = bpm
        let offset = Self.sessionOffset(sessionStart: sessionStart, receivedAt: receivedAt)
        // Keep RR only from a trusted chest strap (Phase 3); untrusted/unknown → drop it so HRV stays
        // the honest bpm-only state. `rrTrusted` is overridable in tests via `setRRTrusted`.
        samples.append(HRSample(t: offset, bpm: bpm, rrIntervalsMs: rrTrusted ? rrIntervalsMs : nil))
        state = .streaming
    }

    /// Test seam: set the RR-trust flag directly (the real flag is derived from the band's name /
    /// `0x2A24` model number on connect, which needs a device).
    func setRRTrusted(_ trusted: Bool) { rrTrusted = trusted }

    /// Session-relative offset for a BLE sample. Unlike the watch (which relays its own
    /// monotonic `t`), a BLE measurement has no timestamp, so we use wall-clock elapsed
    /// since the session start, clamped ≥ 0.
    nonisolated static func sessionOffset(sessionStart: Date?, receivedAt: Date) -> Double {
        guard let sessionStart else { return 0 }
        return max(0, receivedAt.timeIntervalSince(sessionStart))
    }

    // MARK: - Pure HR-measurement parser (unit-testable, no device)

    /// A parsed Heart Rate Measurement: the bpm plus, when the band supports it, the sensor-contact
    /// state (`nil` = the band can't report contact). Plain value type, so the parse seam is
    /// unit-testable from byte fixtures with no device.
    struct HRMeasurement: Equatable, Sendable {
        let bpm: Double
        /// `true` = contact detected, `false` = contact lost, `nil` = the band doesn't support it.
        let contact: Bool?
        /// RR-intervals (ms) present in this packet (flags bit 4), already converted from the spec's
        /// 1/1024-second units; `nil` when the band doesn't send them (fitness-band Phase 3). Trust
        /// gating (chest-strap vs optical) happens at `ingest`, not here — this is the raw decode.
        let rrIntervalsMs: [Double]?

        /// `rrIntervalsMs` defaults to `nil` so existing bpm+contact construction (and its tests) is
        /// unchanged; the RR decode passes it explicitly.
        init(bpm: Double, contact: Bool?, rrIntervalsMs: [Double]? = nil) {
            self.bpm = bpm
            self.contact = contact
            self.rrIntervalsMs = rrIntervalsMs
        }
    }

    /// Decode the sensor-contact state from the Heart Rate Measurement flags byte.
    ///
    /// Bluetooth SIG layout: **bit 2** (`0x04`) = Sensor Contact *Supported*, **bit 1** (`0x02`) =
    /// Sensor Contact *Status* (meaningful only when supported). These are two independent bits, NOT
    /// a single 2-bit enum — so we gate on the support bit first: unsupported → `nil` ("unknown",
    /// never a false "adjust strap"); supported → the status bit (`true` = contact, `false` = lost).
    /// (Decoding them as a 2-bit value mis-fires on hardware that sets status without support —
    /// decisions.md 2026-06-08.)
    nonisolated static func contactStatus(flags: UInt8) -> Bool? {
        let supported = (flags & 0x04) != 0
        guard supported else { return nil }
        return (flags & 0x02) != 0
    }

    /// Parse a Heart Rate Measurement characteristic value (`0x2A37`) into bpm + sensor contact.
    ///
    /// Layout (Bluetooth SIG Heart Rate Measurement):
    /// - byte 0 = flags. **bit 0** = HR value format: `0` → next byte is `UInt8` bpm, `1` → next two
    ///   bytes are little-endian `UInt16` bpm. **bits 1–2** = sensor-contact support/status (decoded
    ///   via `contactStatus`), **bit 3** (`0x08`) = energy-expended present (a UInt16, in kJ, sitting
    ///   *before* RR — skipped to reach RR), **bit 4** (`0x10`) = RR-intervals present (a variable
    ///   number of little-endian UInt16, each in **1/1024 s** units → converted to ms).
    /// - Returns `nil` for an empty or too-short buffer (e.g. flags say UInt16 but only one value
    ///   byte present), so a malformed packet can't poison the buffer. A truncated RR tail yields only
    ///   the whole intervals that fit (never reads past the end).
    nonisolated static func parseMeasurement(_ data: Data) -> HRMeasurement? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let isUInt16 = (flags & 0x01) != 0
        let bpm: Double
        var idx: Int
        if isUInt16 {
            // Need flags + 2 value bytes.
            guard bytes.count >= 3 else { return nil }
            bpm = Double(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            idx = 3
        } else {
            guard bytes.count >= 2 else { return nil }
            bpm = Double(bytes[1])
            idx = 2
        }
        // Energy-Expended (bit 3): a UInt16 that precedes RR. We don't use it (Keytel estimates BLE
        // energy, Phase 2), but must step over it to reach RR.
        if (flags & 0x08) != 0 { idx += 2 }
        // RR-Intervals (bit 4): the rest of the buffer, UInt16 LE pairs in 1/1024 s → ms.
        var rr: [Double]? = nil
        if (flags & 0x10) != 0 {
            var out: [Double] = []
            while idx + 1 < bytes.count {
                let raw = UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8)
                out.append(Double(raw) * 1000.0 / 1024.0)
                idx += 2
            }
            rr = out.isEmpty ? nil : out
        }
        return HRMeasurement(bpm: bpm, contact: contactStatus(flags: flags), rrIntervalsMs: rr)
    }

    /// Bpm-only convenience over `parseMeasurement` (back-compat shim): same width logic, same
    /// nil-on-malformed contract, contact discarded.
    nonisolated static func parseHeartRate(_ data: Data) -> Double? {
        parseMeasurement(data)?.bpm
    }

    /// Decide whether a band's RR-intervals are trustworthy for HRV (fitness-band Phase 3).
    ///
    /// RR (beat-to-beat timing) is reliable only from **chest straps**; optical wrist/arm sensors emit
    /// synthetic or no genuine RR, so HRV off them would be misleading. We classify off the band's
    /// model number (`0x180A`/`0x2A24`) and/or its advertised name — **default-deny**: an unknown or
    /// unnamed device is NOT trusted, so HRV cleanly degrades to the bpm-only effort/recovery already
    /// shipped (decisions.md 2026-06-08). The optical blacklist is checked *before* the chest-strap
    /// whitelist so e.g. "TICKR FIT" (Wahoo's optical armband) is rejected before the "tickr" match.
    nonisolated static func rrTrusted(modelNumber: String?, deviceName: String?) -> Bool {
        let hay = [modelNumber ?? "", deviceName ?? ""].joined(separator: " ")
            .lowercased().trimmingCharacters(in: .whitespaces)
        guard !hay.isEmpty else { return false }
        let optical = ["fit", "oh1", "verity", "scosche", "rhythm", "fitbit", "whoop",
                       "apple watch", "wrist", "armband", "ring"]
        if optical.contains(where: hay.contains) { return false }
        let straps = ["polar h", "hrm", "tickr", "movesense", "frontier", "wahoo",
                      "garmin", "coospo h", "magene h", "decathlon dual", "chest"]
        return straps.contains(where: hay.contains)
    }

    /// Forget the remembered band and disconnect it. The user is telling us "don't auto-use
    /// this one anymore"; the picker offers it via swipe / a button. We also **suppress**
    /// auto-connect for it (persisted) so the "single system-connected band → just use it" rule
    /// can't silently reconnect + re-remember it next scan/launch — the case where the band stays
    /// connected to iOS on its own (e.g. a Fitbit kept alive by its app). Re-tapping it re-opts-in.
    func forget(_ device: BLEDevice) {
        #if canImport(CoreBluetooth)
        if desiredPeripheralID == device.id {
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            desiredPeripheralID = nil
            connectedName = nil
            if state != .unavailable { state = .idle }
        }
        memory.suppressAutoConnect(id: device.id)
        #endif
    }

    // MARK: - Scan helper

    #if canImport(CoreBluetooth)
    private func startScanIfPossible() {
        guard let central, central.state == .poweredOn else { return }
        if state == .unavailable { state = .idle }
        refreshSystemConnected()
        central.scanForPeripherals(withServices: [Self.heartRateServiceUUID], options: nil)
    }

    /// Ask iOS for bands it already has connected (paired in Settings / actively connected) and
    /// fold them into the discovered list — these never advertise, so a plain scan misses them.
    /// This is the core of "auto-detect the Bluetooth-connected fitness band".
    private func refreshSystemConnected() {
        guard let central else { return }
        let peripherals = central.retrieveConnectedPeripherals(withServices: [Self.heartRateServiceUUID])
        systemConnected = peripherals.map { BLEDevice(id: $0.identifier,
                                                      name: $0.name ?? "Heart-rate band",
                                                      isSystemConnected: true) }
        rebuildDiscovered()
        tryAutoConnect()
    }

    /// Re-merge the system-connected + scanned halves into the published `discovered` list.
    private func rebuildDiscovered() {
        discovered = BLEBands.merge(systemConnected: systemConnected, scanned: scanned)
    }

    /// Connect a band the user shouldn't have to tap: the remembered one, or the single band
    /// already connected to iOS. No-op once we already have a target / live connection.
    private func tryAutoConnect() {
        guard desiredPeripheralID == nil || state == .idle || state == .unavailable else { return }
        // The remembered band is the strongest signal even before it's in `discovered` — unless
        // it's been Forgotten (suppressed), in which case we must not silently reconnect it.
        if let id = memory.rememberedID, id != memory.suppressedID,
           let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            connect(BLEDevice(id: id, name: memory.rememberedName ?? known.name ?? "Heart-rate band"))
            return
        }
        if let pick = BLEBands.bandToAutoConnect(remembered: memory.rememberedID,
                                                 suppressed: memory.suppressedID,
                                                 visible: discovered) {
            connect(pick)
        }
    }
    #endif
}

#if canImport(CoreBluetooth)
extension BLEHeartRateMetricsSource: CBCentralManagerDelegate {
    // CoreBluetooth callbacks arrive off the main actor; hop to @MainActor before mutating
    // observable state (mirrors how AppleWatchMetricsSource's WCSessionDelegate does it).

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let cbState = central.state
        let unauthorized = central.authorization == .denied || central.authorization == .restricted
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch cbState {
            case .poweredOn:
                self.availability = .ready
                if self.state == .unavailable { self.state = .idle }
                self.startScanIfPossible()
            case .unauthorized:
                self.availability = .unauthorized
                self.state = .unavailable
                self.isReachable = false
            case .poweredOff:
                self.availability = .poweredOff
                self.state = .unavailable
                self.isReachable = false
            default:
                self.availability = unauthorized ? .unauthorized : .unknown
                self.state = .unavailable
                self.isReachable = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Heart-rate band"
        // The peripheral / central are confined to CoreBluetooth's delegate queue (where
        // this callback runs); they aren't Sendable, so capture them via the documented
        // escape hatch to use them on the MainActor (CB tolerates connect from any queue).
        nonisolated(unsafe) let p = peripheral
        nonisolated(unsafe) let c = central
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.scanned.contains(where: { $0.id == id }) {
                self.scanned.append(BLEDevice(id: id, name: name))
                self.rebuildDiscovered()
            }
            // If the user already asked to connect to this one, connect now that we see it.
            if self.desiredPeripheralID == id {
                self.peripheral = p
                p.delegate = self
                self.state = .connecting
                c.connect(p, options: nil)
            } else {
                // Otherwise see if this newly-seen band is one we should auto-connect (the
                // remembered band waking up, or the only band around).
                self.tryAutoConnect()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name
        let id = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = true
            self.state = .connected
            if let name { self.connectedName = name }
            // RR trust from the name we have now (Phase 3) — refined by the 0x2A24 model number below.
            // Named straps are trusted immediately; unknown names stay untrusted (HRV → bpm-only).
            self.rrTrusted = Self.rrTrusted(modelNumber: nil, deviceName: self.connectedName)
            // Remember this band so the next workout / launch reconnects it automatically
            // (the one-time manual pick becomes a permanent convenience).
            self.memory.remember(id: id, name: self.connectedName ?? "Heart-rate band")
            // We have our band — stop the radio scan to save battery. The picker re-scans on
            // appear if the user wants to switch bands.
            self.central?.stopScan()
        }
        // HR measurement + Device Info (for the RR-trust model gate, Phase 3).
        peripheral.discoverServices([Self.heartRateServiceUUID, Self.deviceInfoServiceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = false
            if self.state == .streaming || self.state == .connected { self.state = .idle }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            self?.isReachable = false
            self?.state = .idle
        }
    }
}

extension BLEHeartRateMetricsSource: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case Self.heartRateServiceUUID:
                peripheral.discoverCharacteristics([Self.heartRateMeasurementUUID], for: service)
            case Self.deviceInfoServiceUUID:
                peripheral.discoverCharacteristics([Self.modelNumberUUID], for: service)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case Self.heartRateMeasurementUUID:
                // Subscribe to notifications — the band pushes a measurement ~1 Hz.
                peripheral.setNotifyValue(true, for: char)
            case Self.modelNumberUUID:
                // One-shot read; refines RR trust (Phase 3).
                peripheral.readValue(for: char)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        // Device-Info model number → refine the RR-trust gate (Phase 3).
        if characteristic.uuid == Self.modelNumberUUID {
            let model = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rrTrusted = Self.rrTrusted(modelNumber: model, deviceName: self.connectedName)
            }
            return
        }
        guard characteristic.uuid == Self.heartRateMeasurementUUID,
              let data = characteristic.value,
              let m = BLEHeartRateMetricsSource.parseMeasurement(data) else { return }
        Task { @MainActor [weak self] in
            self?.ingest(bpm: m.bpm, contact: m.contact, rrIntervalsMs: m.rrIntervalsMs)
        }
    }
}
#endif
