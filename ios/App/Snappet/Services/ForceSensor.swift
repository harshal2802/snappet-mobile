import Foundation
import Observation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Connection state of a force sensor (prompt 145).
enum ForceSensorState: Equatable, Sendable {
    /// Bluetooth off / not permitted / not supported here.
    case unavailable
    case idle
    case connecting
    case connected
    /// Streaming weight readings.
    case measuring

    var isConnected: Bool { self == .connected || self == .measuring }
}

/// A force sensor the workout can read live (prompt 145). Generic so other boards (PitchSix, Entralpi…)
/// can be added later without touching the workout code; the Tindeq Progressor is the first. Everything
/// that uses force treats "no sensor" as the normal case.
@MainActor
protocol ForceSensorSource: AnyObject {
    var state: ForceSensorState { get }
    var availability: BluetoothAvailability { get }
    var latestKg: Double? { get }
    var batteryPercent: Int? { get }
    var isLowPower: Bool { get }
    var connectedName: String? { get }
    /// Sensors found by the current scan (for pairing in Settings).
    var discovered: [BLEDevice] { get }
    var hasRememberedSensor: Bool { get }
    var rememberedName: String? { get }
    /// The remembered sensor is advertising nearby right now (drives the "Tindeq nearby · Connect" card).
    var isRememberedNearby: Bool { get }
    /// The sensor dropped while measuring (battery / range) — the runner shows the fallback banner.
    var droppedWhileMeasuring: Bool { get }
    /// Called on the main actor for every reading while measuring.
    var onSample: ((ForceSample) -> Void)? { get set }

    /// Power the radio up and look for sensors (asks for Bluetooth permission the first time).
    func startScan()
    func stopScan()
    func connect(_ device: BLEDevice)
    func connectRemembered()
    func disconnect()
    func forget()
    func tare()
    func startMeasuring()
    func stopMeasuring()
}

/// Remembers the paired force sensor (separate keys from the heart-rate band's `BandMemory`).
@MainActor
final class ForceSensorMemory {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var rememberedID: UUID? {
        get { defaults.string(forKey: "snappet.force.sensorID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "snappet.force.sensorID") }
    }
    var rememberedName: String? {
        get { defaults.string(forKey: "snappet.force.sensorName") }
        set { defaults.set(newValue, forKey: "snappet.force.sensorName") }
    }
}

// MARK: - Tindeq Progressor

/// The Tindeq Progressor over CoreBluetooth (prompt 145). Scans for the Progressor service, connects,
/// subscribes to the data point, writes one-byte commands to the control point, and turns weight packets
/// (parsed by the pure `TindeqProtocol`) into `ForceSample`s. The radio is only woken when the user pairs
/// a sensor or a force-capable protocol starts with one remembered — never for people without a sensor.
///
/// **Verification honesty:** the packet format and analysis are unit-tested; a live connection only runs
/// on a phone with a real Progressor (the simulator has no Bluetooth).
@MainActor
@Observable
final class TindeqProgressorSource: NSObject, ForceSensorSource {
    private(set) var state: ForceSensorState = .unavailable
    private(set) var availability: BluetoothAvailability = .unknown
    private(set) var latestKg: Double?
    private(set) var batteryPercent: Int?
    private(set) var isLowPower = false
    private(set) var connectedName: String?
    private(set) var discovered: [BLEDevice] = []
    private(set) var isRememberedNearby = false
    private(set) var droppedWhileMeasuring = false
    @ObservationIgnored var onSample: ((ForceSample) -> Void)?

    private let memory: ForceSensorMemory
    var hasRememberedSensor: Bool { memory.rememberedID != nil }
    var rememberedName: String? { memory.rememberedName }

    /// Seconds-offset so readings stay monotonic across stop/start (the device restarts its clock).
    private var timeOffset: TimeInterval = 0
    private var lastT: TimeInterval = 0
    private var lastCommand: TindeqProtocol.Command?
    private var wantsMeasuring = false

    #if canImport(CoreBluetooth)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var desiredID: UUID?
    nonisolated(unsafe) private static let service = CBUUID(string: TindeqProtocol.serviceUUID)
    nonisolated(unsafe) private static let dataChar = CBUUID(string: TindeqProtocol.dataUUID)
    nonisolated(unsafe) private static let controlCharUUID = CBUUID(string: TindeqProtocol.controlUUID)
    #endif

    init(memory: ForceSensorMemory = ForceSensorMemory()) {
        self.memory = memory
        super.init()
    }

    // MARK: Radio

    func startScan() {
        #if canImport(CoreBluetooth)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // scanning starts once powered on
            return
        }
        scanIfReady()
        #endif
    }

    func stopScan() {
        #if canImport(CoreBluetooth)
        central?.stopScan()
        #endif
    }

    func connect(_ device: BLEDevice) {
        #if canImport(CoreBluetooth)
        desiredID = device.id
        if let p = central?.retrievePeripherals(withIdentifiers: [device.id]).first {
            attach(p)
        } else {
            startScan()
        }
        #endif
    }

    func connectRemembered() {
        guard let id = memory.rememberedID else { return }
        connect(BLEDevice(id: id, name: memory.rememberedName ?? "Tindeq Progressor"))
    }

    func disconnect() {
        #if canImport(CoreBluetooth)
        desiredID = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        #endif
    }

    func forget() {
        disconnect()
        memory.rememberedID = nil
        memory.rememberedName = nil
        isRememberedNearby = false
    }

    // MARK: Commands

    func tare() { send(.tare) }

    func startMeasuring() {
        wantsMeasuring = true
        droppedWhileMeasuring = false
        timeOffset = lastT
        send(.startWeight)
    }

    func stopMeasuring() {
        wantsMeasuring = false
        send(.stopWeight)
        if state == .measuring { state = .connected }
    }

    private func send(_ command: TindeqProtocol.Command) {
        #if canImport(CoreBluetooth)
        guard let p = peripheral, let c = controlChar else { return }
        lastCommand = command
        p.writeValue(Data([command.rawValue]), for: c, type: .withResponse)
        #endif
    }

    // MARK: Ingest (main actor)

    private func ingest(_ packet: TindeqProtocol.Packet) {
        switch packet {
        case .weights(let pairs):
            if state == .connected, wantsMeasuring { state = .measuring }
            for (kg, micros) in pairs {
                let t = timeOffset + TimeInterval(micros) / 1_000_000
                lastT = max(lastT, t)
                latestKg = kg
                onSample?(ForceSample(t: t, kg: kg))
            }
        case .commandResponse(let payload):
            if lastCommand == .battery, let mv = TindeqProtocol.batteryMillivolts(payload) {
                batteryPercent = TindeqProtocol.batteryPercent(millivolts: mv)
            }
        case .lowPower:
            isLowPower = true
        case .unknown:
            break
        }
    }

    #if canImport(CoreBluetooth)
    private func scanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        // Already connected to the system? (e.g. reopened app) — pick it up without a scan.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.service]) where p.identifier == desiredID {
            attach(p)
            return
        }
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central?.connect(p, options: nil)
    }

    private func didDiscover(_ device: BLEDevice, peripheral p: CBPeripheral) {
        if !discovered.contains(where: { $0.id == device.id }) { discovered.append(device) }
        if device.id == memory.rememberedID { isRememberedNearby = true }
        if device.id == desiredID, peripheral == nil || !state.isConnected { attach(p) }
    }
    #endif
}

#if canImport(CoreBluetooth)
extension TindeqProgressorSource: CBCentralManagerDelegate, CBPeripheralDelegate {
    // Callbacks arrive on the main queue (queue: nil); hop explicitly to the main actor for observable
    // state, mirroring BLEHeartRateMetricsSource.

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch s {
            case .poweredOn:
                self.availability = .ready
                if self.state == .unavailable { self.state = .idle }
                self.scanIfReady()
            case .unauthorized: self.availability = .unauthorized; self.state = .unavailable
            case .poweredOff: self.availability = .poweredOff; self.state = .unavailable
            default: self.state = .unavailable
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let device = BLEDevice(id: peripheral.identifier,
                               name: peripheral.name
                                   ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                                   ?? "Tindeq Progressor")
        nonisolated(unsafe) let p = peripheral
        Task { @MainActor [weak self] in self?.didDiscover(device, peripheral: p) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let name = peripheral.name ?? "Tindeq Progressor"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .connected
            self.connectedName = name
            self.memory.rememberedID = id
            self.memory.rememberedName = name
            self.isRememberedNearby = true
            self.central?.stopScan()
        }
        peripheral.discoverServices([Self.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.wantsMeasuring { self.droppedWhileMeasuring = true }
            self.state = .idle
            self.controlChar = nil
            // Reconnect automatically if it comes back (battery swap, walked out of range).
            if self.desiredID != nil { self.scanIfReady() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in self?.state = .idle }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.dataChar, Self.controlCharUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == Self.dataChar { peripheral.setNotifyValue(true, for: char) }
            if char.uuid == Self.controlCharUUID {
                nonisolated(unsafe) let c = char
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.controlChar = c
                    self.send(.battery)
                    if self.wantsMeasuring { self.send(.startWeight) }   // resume after a reconnect
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == Self.dataChar, let data = characteristic.value,
              let packet = TindeqProtocol.parse(data) else { return }
        Task { @MainActor [weak self] in self?.ingest(packet) }
    }
}
#endif

// MARK: - Fake sensor (UI tests only)

/// A stand-in sensor for UI tests (`-uiTestFakeForceSensor`): "connected" at once and, while measuring,
/// streams a repeating 7 s hang at ~46 kg with 2 s off between — enough to drive the live force bar and
/// automatic rep detection on the simulator, which has no Bluetooth.
@MainActor
@Observable
final class FakeForceSensor: ForceSensorSource {
    private(set) var state: ForceSensorState = .connected
    let availability: BluetoothAvailability = .ready
    private(set) var latestKg: Double? = 0
    let batteryPercent: Int? = 82
    let isLowPower = false
    let connectedName: String? = "Tindeq Progressor (test)"
    let discovered: [BLEDevice] = []
    let hasRememberedSensor = true
    let rememberedName: String? = "Tindeq Progressor (test)"
    let isRememberedNearby = true
    let droppedWhileMeasuring = false
    @ObservationIgnored var onSample: ((ForceSample) -> Void)?
    private var task: Task<Void, Never>?

    func startScan() {}
    func stopScan() {}
    func connect(_ device: BLEDevice) {}
    func connectRemembered() {}
    func disconnect() {}
    func forget() {}
    func tare() {}

    func startMeasuring() {
        state = .measuring
        let start = Date()
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                let phase = t.truncatingRemainder(dividingBy: 9)
                let kg = phase < 7 ? 46 + sin(t * 5) * 0.8 : 0.3
                self.latestKg = kg
                self.onSample?(ForceSample(t: t, kg: kg))
            }
        }
    }

    func stopMeasuring() {
        task?.cancel()
        task = nil
        state = .connected
    }
}
