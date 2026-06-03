import Foundation

/// Persists the user's chosen Bluetooth heart-rate band so it **reconnects automatically**
/// on the next workout / app launch — the fix for "I had to manually re-pick my band every
/// time". Backed by `UserDefaults` (on-device only, like every Snappet store); the
/// `UserDefaults` instance is injectable so the selection/auto-connect rules can be
/// unit-tested against an isolated suite with no device and no real defaults.
@MainActor
final class BandMemory {
    private let defaults: UserDefaults
    private let idKey = "snappet.ble.rememberedBandID"
    private let nameKey = "snappet.ble.rememberedBandName"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The `CBPeripheral.identifier` of the band the user last used, if any.
    var rememberedID: UUID? {
        get { defaults.string(forKey: idKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: idKey) }
    }

    /// The friendly name to show for the remembered band before it's rediscovered.
    var rememberedName: String? {
        get { defaults.string(forKey: nameKey) }
        set { defaults.set(newValue, forKey: nameKey) }
    }

    /// Whether a band has been remembered (used to gate auto-prepare so the very first use
    /// is still a deliberate, prompt-on-open action and later launches are automatic).
    var hasRemembered: Bool { rememberedID != nil }

    func remember(id: UUID, name: String) {
        rememberedID = id
        rememberedName = name
    }

    func forget() {
        rememberedID = nil
        rememberedName = nil
    }
}

/// Pure BLE-band list + auto-connect rules, isolated here so they are unit-testable with
/// **no `CoreBluetooth`, no device, no band** (the same honesty bar as the HR-measurement
/// parser and the source-selection rule). The live source feeds these its discovered list
/// and remembered id; the picker renders the result.
enum BLEBands {

    /// Merge the bands iOS reports as **already connected** (`retrieveConnectedPeripherals`,
    /// i.e. a band paired in iOS Settings / actively connected — the ones that never show up
    /// in an advertising scan) with the bands found by **scanning**, de-duplicated by id.
    /// System-connected entries win (and sort first) so "ready right now" bands lead the list.
    static func merge(systemConnected: [BLEDevice], scanned: [BLEDevice]) -> [BLEDevice] {
        var result = systemConnected
        let known = Set(systemConnected.map(\.id))
        for device in scanned where !known.contains(device.id) {
            result.append(device)
        }
        return result
    }

    /// The list the picker renders: the discovered bands, plus the remembered band synthesized
    /// as a row when it hasn't been rediscovered yet (so a previously-used band is always
    /// visible — and tappable — even if it's still waking up). Remembered-but-unseen leads the
    /// list; otherwise discovery order is preserved.
    static func displayList(discovered: [BLEDevice],
                            rememberedID: UUID?,
                            rememberedName: String?) -> [BLEDevice] {
        guard let rememberedID else { return discovered }
        if discovered.contains(where: { $0.id == rememberedID }) { return discovered }
        let synthetic = BLEDevice(id: rememberedID,
                                  name: rememberedName ?? "Heart-rate band",
                                  isSystemConnected: false)
        return [synthetic] + discovered
    }

    /// Which visible band to connect **without the user tapping anything**:
    ///   1. the remembered band, if it's visible (the "reconnect my usual band" path);
    ///   2. otherwise, if exactly one band is already connected to iOS, that one (the
    ///      "you clearly have one band, just use it" path);
    ///   3. otherwise `nil` — there's a genuine choice to make, so leave it to the user.
    static func bandToAutoConnect(remembered: UUID?, visible: [BLEDevice]) -> BLEDevice? {
        if let remembered, let match = visible.first(where: { $0.id == remembered }) {
            return match
        }
        let systemConnected = visible.filter(\.isSystemConnected)
        if systemConnected.count == 1 { return systemConnected[0] }
        return nil
    }
}
