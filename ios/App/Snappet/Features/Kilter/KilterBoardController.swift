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
        case unsupported          // simulator / no BLE / permission denied
        case idle
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    // Aurora/Kilter board GATT (community-sourced — verify against hardware).
    private static let serviceUUID = CBUUID(string: "4488B571-7806-4DF6-BCFF-A2897E4953FF")
    private static let writeUUID = CBUUID(string: "4488B572-7806-4DF6-BCFF-A2897E4953FF")

    private(set) var state: State = .idle
    var isConnected: Bool { state == .connected }
    /// Notified when the connection comes up / goes down, so the module can open/close a session.
    var onConnectionChange: ((Bool) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    /// Holds set while waiting for the characteristic to be discovered.
    private var pendingHolds: [KilterHold]?

    /// Begin scanning for a board (lazily creates the central manager → triggers the permission prompt).
    func connect() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // nil queue → main
        }
        guard let central, central.state == .poweredOn else { return }   // startScan once powered on
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        state = .idle
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
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if state == .scanning || state == .idle { connect() }
            case .unsupported, .unauthorized:
                state = .unsupported
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            state = .failed(error?.localizedDescription ?? "Couldn't connect")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            writeChar = nil
            state = .idle
            onConnectionChange?(false)
        }
    }
}

extension KilterBoardController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.writeUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.writeUUID {
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
