import Foundation

/// Per-layout memory of the user's physical board size (`product_size_id`) — the fix for real-user
/// feedback "resets board to 12 x 14". The old model kept ONE global `kilter.productSizeId`, and the
/// root/Settings `syncBoardSize()` overwrote it with the layout default (the lowest
/// `product_size_id` — the 12×14) whenever the stored value wasn't valid for the *current* layout:
/// on every layout switch, and on every appear while the catalog was unreadable (an empty size list
/// fails the validity check). Storing the choice **per layout** and resolving staleness at *read*
/// time means browsing another layout can never destroy the size you picked for yours.
///
/// `UserDefaults`-backed (on-device only, no `@Model` — the same "avoid the backup tax" stance as
/// `KilterBoardMemory`); injectable so the remember/recall rules unit-test against an isolated
/// suite. The legacy global `kilter.productSizeId` key stays as "the size currently in effect" for
/// the render/LED paths — this map is the memory *behind* it.
@MainActor
final class KilterSizeMemory {
    private let defaults: UserDefaults
    /// JSON map `layoutId (string) → product_size_id`.
    private let mapKey = "kilter.productSizeByLayout"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var map: [Int: Int] {
        get {
            guard let data = defaults.data(forKey: mapKey),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        set {
            let encodable = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(encodable) { defaults.set(data, forKey: mapKey) }
        }
    }

    /// The size last chosen for a layout, or `nil` when the layout never had one.
    func recall(forLayout layoutId: Int) -> Int? { map[layoutId] }

    /// Record the size in effect for a layout — called whenever the selection lands on a valid size
    /// (user pick, board-memory restore, or first-visit seed) so the map mirrors the last good choice.
    func remember(sizeId: Int, forLayout layoutId: Int) {
        var m = map
        m[layoutId] = sizeId
        map = m
    }

    // MARK: - Pure resolution rule (separately unit-tested, no UserDefaults / no device)

    /// The size to select for a layout, given what's remembered for it, what's currently in effect,
    /// and what the installed catalog offers:
    ///   • `available` empty (catalog unreadable / mid-reload) → `nil` = **leave the selection
    ///     alone** — this transient state is exactly what used to stomp a chosen size back to the
    ///     12×14 default;
    ///   • the layout's remembered size wins when still offered (returning to a layout restores
    ///     *its* size);
    ///   • else a still-valid current size carries over (first visit to a layout that shares it);
    ///   • else the layout default (lowest id) — the only *legitimate* reset (e.g. a catalog swap
    ///     removed the size); callers may surface that instead of failing silently.
    nonisolated static func choose(remembered: Int?, current: Int, available: [Int]) -> Int? {
        guard !available.isEmpty else { return nil }
        if let remembered, available.contains(remembered) { return remembered }
        if available.contains(current) { return current }
        return available.min()
    }
}
