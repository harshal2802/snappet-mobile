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

    /// Peripherals discovered while scanning (deduplicated by identifier), for the picker.
    private(set) var discovered: [BLEDevice] = []

    /// Name of the connected band when known, else a generic label.
    private(set) var connectedName: String?
    var displayName: String { connectedName ?? "Heart-rate band" }

    /// Wall-clock session start, to re-base samples onto the engine's `HRSample.t` timeline
    /// (seconds since the session began) — same convention as the watch path.
    private var sessionStart: Date?

    // MARK: - Heart Rate GATT identifiers (RESEARCH.md §3.3)

    #if canImport(CoreBluetooth)
    // `nonisolated` so the off-actor CoreBluetooth delegate callbacks can read them.
    // `CBUUID` is immutable; constructing one is safe off the main actor.
    nonisolated(unsafe) static let heartRateServiceUUID = CBUUID(string: "180D")
    nonisolated(unsafe) static let heartRateMeasurementUUID = CBUUID(string: "2A37")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The identifier the user asked to connect to (we connect when scanning finds it).
    private var desiredPeripheralID: UUID?
    #endif

    override init() {
        super.init()
        #if canImport(CoreBluetooth)
        // Lazily create the central on first use so we don't trigger the Bluetooth
        // permission prompt at app launch — only when the user opens the source picker /
        // selects BLE. `prepare()` does that.
        #endif
    }

    /// Spin up the `CBCentralManager` (triggers the one-time Bluetooth permission prompt)
    /// and begin scanning once powered on. Called when the user opens the HR-source picker.
    func prepare() {
        #if canImport(CoreBluetooth)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startScanIfPossible()
        }
        #endif
    }

    /// Begin/resume scanning for `0x180D` advertisers (no-op if Bluetooth isn't ready).
    func startScan() {
        #if canImport(CoreBluetooth)
        prepare()
        startScanIfPossible()
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
        desiredPeripheralID = device.id
        connectedName = device.name
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

    func start(for session: WorkoutSession, sport: SportTag?, category: ExerciseCategory?) {
        // The BLE band has no notion of a workout "type" — it just streams HR. We reset the
        // buffer onto this session's timeline and (re)connect if a band was chosen.
        sessionStart = session.startedAt
        samples.removeAll()
        latestHR = nil
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
        #endif
        isReachable = false
        if state == .streaming || state == .connected { state = .idle }
    }

    // MARK: - Sample ingestion (test seam)

    /// Ingest a parsed bpm at wall-clock `receivedAt`, re-based onto the session timeline.
    /// Pure given `sessionStart`, so it is unit-testable without a device.
    func ingest(bpm: Double, receivedAt: Date = .now) {
        latestHR = bpm
        let offset = Self.sessionOffset(sessionStart: sessionStart, receivedAt: receivedAt)
        samples.append(HRSample(t: offset, bpm: bpm))
        state = .streaming
    }

    /// Session-relative offset for a BLE sample. Unlike the watch (which relays its own
    /// monotonic `t`), a BLE measurement has no timestamp, so we use wall-clock elapsed
    /// since the session start, clamped ≥ 0.
    nonisolated static func sessionOffset(sessionStart: Date?, receivedAt: Date) -> Double {
        guard let sessionStart else { return 0 }
        return max(0, receivedAt.timeIntervalSince(sessionStart))
    }

    // MARK: - Pure HR-measurement parser (unit-testable, no device)

    /// Parse a Heart Rate Measurement characteristic value (`0x2A37`) into a bpm.
    ///
    /// Layout (Bluetooth SIG Heart Rate Measurement):
    /// - byte 0 = flags. **bit 0** = HR value format: `0` → next byte is `UInt8` bpm,
    ///   `1` → next two bytes are little-endian `UInt16` bpm. bits 1–2 = sensor-contact
    ///   status, bit 3 = energy-expended present, bit 4 = RR-intervals present. We only
    ///   need the bpm, so the optional sensor-contact / energy-expended / RR fields are
    ///   ignored — but the format bit must be honored to read the right width.
    /// - Returns `nil` for an empty or too-short buffer (e.g. flags say UInt16 but only one
    ///   value byte present), so a malformed packet can't poison the buffer.
    nonisolated static func parseHeartRate(_ data: Data) -> Double? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let isUInt16 = (flags & 0x01) != 0
        if isUInt16 {
            // Need flags + 2 value bytes.
            guard bytes.count >= 3 else { return nil }
            let value = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return Double(value)
        } else {
            guard bytes.count >= 2 else { return nil }
            return Double(bytes[1])
        }
    }

    // MARK: - Scan helper

    #if canImport(CoreBluetooth)
    private func startScanIfPossible() {
        guard let central, central.state == .poweredOn else { return }
        if state == .unavailable { state = .idle }
        central.scanForPeripherals(withServices: [Self.heartRateServiceUUID], options: nil)
    }
    #endif
}

#if canImport(CoreBluetooth)
extension BLEHeartRateMetricsSource: CBCentralManagerDelegate {
    // CoreBluetooth callbacks arrive off the main actor; hop to @MainActor before mutating
    // observable state (mirrors how AppleWatchMetricsSource's WCSessionDelegate does it).

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let poweredOn = central.state == .poweredOn
        Task { @MainActor [weak self] in
            guard let self else { return }
            if poweredOn {
                if self.state == .unavailable { self.state = .idle }
                self.startScanIfPossible()
            } else {
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
            if !self.discovered.contains(where: { $0.id == id }) {
                self.discovered.append(BLEDevice(id: id, name: name))
            }
            // If the user already asked to connect to this one, connect now that we see it.
            if self.desiredPeripheralID == id {
                self.peripheral = p
                p.delegate = self
                self.state = .connecting
                c.connect(p, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = true
            self.state = .connected
            if let name { self.connectedName = name }
        }
        peripheral.discoverServices([Self.heartRateServiceUUID])
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
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateServiceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.heartRateMeasurementUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        guard let char = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurementUUID }) else { return }
        // Subscribe to notifications — the band pushes a measurement ~1 Hz.
        peripheral.setNotifyValue(true, for: char)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurementUUID,
              let data = characteristic.value,
              let bpm = BLEHeartRateMetricsSource.parseHeartRate(data) else { return }
        Task { @MainActor [weak self] in self?.ingest(bpm: bpm) }
    }
}
#endif
