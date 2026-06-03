import CoreBluetooth
import Foundation
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

    // Aurora/Kilter board GATT (community-sourced — verify against hardware).
    // `nonisolated(unsafe)`: CBUUID isn't Sendable, but these are immutable constants, so the
    // pure (nonisolated) `isLikelyBoard` matcher can read `serviceUUID` safely.
    nonisolated(unsafe) private static let serviceUUID = CBUUID(string: "4488B571-7806-4DF6-BCFF-A2897E4953FF")
    nonisolated(unsafe) private static let writeUUID = CBUUID(string: "4488B572-7806-4DF6-BCFF-A2897E4953FF")

    /// How long to look for a board before giving up, and how long a single GATT
    /// connect + discovery may take. CoreBluetooth's own `connect(_:)` never times out, so without
    /// these a missing/asleep board leaves the UI wedged on "Connecting…" forever (the reported bug).
    private static let scanTimeout: Duration = .seconds(12)
    private static let connectTimeout: Duration = .seconds(12)

    private(set) var state: State = .idle
    var isConnected: Bool { state == .connected }
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
    /// Watchdog that fails the attempt if scan/connect/discovery stalls.
    private var timeout: Task<Void, Never>?

    /// Whether an advertising peripheral looks like an Aurora-family board (Kilter/Tension/etc).
    /// Pure so it can be unit-tested off-device. Aurora boards generally do **not** advertise their
    /// primary service UUID, only a local name — so name matching is the primary signal and scanning
    /// filtered by service UUID (the old behavior) would never discover them.
    nonisolated static func isLikelyBoard(name: String?, advertisedServiceUUIDs: [CBUUID]) -> Bool {
        if advertisedServiceUUIDs.contains(serviceUUID) { return true }
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
        case .poweredOn: beginScan()
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .scanning   // .unknown / .resetting — wait for didUpdateState
        }
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
        guard isConnected, let peripheral, let writeChar else {
            pendingHolds = holds
            return
        }
        send(holds, to: peripheral, characteristic: writeChar)
    }

    private func send(_ holds: [KilterHold], to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let payload = holds.compactMap { hold -> (position: Int, colorHex: String)? in
            guard let pos = hold.ledPosition else { return nil }
            return (pos, hold.colorHex)
        }
        let mode: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        for message in KilterProtocol.messages(for: payload) {
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
                // or `.idle`) → kick off the real scan. Don't disturb an in-flight connect/connected.
                if wantsToConnect && state != .connecting && state != .connected { beginScan() }
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
        nonisolated(unsafe) let central = central
        nonisolated(unsafe) let peripheral = peripheral
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // CBUUID isn't Sendable; the assumeIsolated closure runs synchronously on this (main) thread.
        nonisolated(unsafe) let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            guard state == .scanning,
                  Self.isLikelyBoard(name: localName ?? peripheral.name,
                                     advertisedServiceUUIDs: advertisedServices) else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
            startTimeout(Self.connectTimeout,
                         message: "Couldn't reach the board. Move closer and try again.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            // Keep the watchdog running across service/characteristic discovery — that's where a board
            // with an unexpected GATT layout would otherwise hang silently.
            startTimeout(Self.connectTimeout,
                         message: "Connected, but the board didn't respond. Try again.")
            peripheral.discoverServices([Self.serviceUUID])
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
            for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
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

/// Tracks the active board session so logged ascents can be grouped in History. Created at the module
/// root and shared via the environment. A session opens when a board connects (source `"ble"`) or
/// when the user starts one manually, and closes on disconnect / when the user ends it.
@MainActor
@Observable
final class KilterSessionManager {
    private(set) var current: KilterSession?
    var isActive: Bool { current != nil }
    var currentId: UUID? { current?.id }

    func start(angle: Int, source: String, in context: ModelContext) {
        guard current == nil else { return }
        let session = KilterSession(angle: angle, source: source)
        context.insert(session)
        try? context.save()
        current = session
    }

    func end(in context: ModelContext) {
        guard let session = current else { return }
        session.endedAt = .now
        try? context.save()
        current = nil
    }
}
