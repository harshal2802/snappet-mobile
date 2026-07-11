import Foundation

/// A coarse, on-device place bucket — a lat/long rounded to ~110 m squares (3 decimals) so the app can
/// say "you're at your usual gym" **without ever reverse-geocoding or networking the location**. Stored
/// raw; the value never leaves the phone. Equatable + `matches` give the pure place-match its test seam.
struct CoarsePlace: Codable, Equatable, Sendable {
    /// Latitude rounded to `decimals` places (the stored bucket — never the precise fix).
    let lat: Double
    /// Longitude rounded to `decimals` places.
    let lon: Double

    /// 3 decimals ≈ 110 m at the equator — fine enough to tell two gyms apart, coarse enough that the
    /// stored value is not a precise location. Fixed so two buckets are comparable for equality.
    static let decimals = 3

    /// Bucket a raw fix into a coarse place (the ONLY way a place is created — there is no precise init,
    /// so a precise coordinate can never be persisted by accident).
    init(latitude: Double, longitude: Double) {
        let f = pow(10.0, Double(Self.decimals))
        self.lat = (latitude * f).rounded() / f
        self.lon = (longitude * f).rounded() / f
    }

    /// Whether a (freshly bucketed) place is the same square as this one — the recall test for an
    /// arrival suggestion. Same square == same gym for this feature's purposes.
    func matches(_ other: CoarsePlace) -> Bool { lat == other.lat && lon == other.lon }
}

/// Everything this phone remembers about one physical board it has connected to before, keyed by the
/// stable `CBPeripheral.identifier`. Persisted as JSON inside `UserDefaults` (on-device only, like every
/// Snappet store) so there's **no new `@Model` / no SwiftData schema or backup change** — the same
/// "avoid the backup tax" stance `BandMemory` takes.
struct RememberedBoard: Codable, Equatable, Sendable {
    /// The Kilter layout (`kilter.layout`) last used on this board.
    var layoutId: Int
    /// The physical board size (`product_size_id`, `kilter.productSizeId`) last used on this board.
    var productSizeId: Int
    /// Every angle the user has **explicitly confirmed/adjusted** on this board, in order —
    /// `mostFrequentAngle` reads this to pre-select the usual angle (still always a one-tap confirm, never
    /// silently applied). A plain connect the climber ignores appends nothing, so the pre-select can't
    /// self-reinforce; the history only moves when the user acts in the ribbon.
    var angleHistory: [Int]
    /// A friendly, renameable name shown in the confirm ribbon / Settings ("8×12 Home"). Seeds the
    /// session's gym default.
    var label: String
    /// The `#serial` token parsed from the advertised local name, if the board advertised one — a
    /// cross-check that survives a phone reinstall (which mints a fresh `CBPeripheral.identifier`).
    var serial: String?
    /// The coarse place this board was last seen at, for the pre-connect arrival suggestion. `nil` until
    /// location is available; never precise, never uploaded.
    var coarsePlace: CoarsePlace?
    /// When this board was last connected — newest-first ordering for the Settings list + arrival pick.
    var lastSeen: Date
    /// Whether the user has **confirmed this board's layout + size on the wall** via the "Set up this board"
    /// verifier (prompt 120). `remember(...)` fires on every connect and learns a board with the *current
    /// global* layout/size, which is only a guess — so a plain remembered board isn't yet trustworthy. This
    /// flag is the "the LEDs actually matched" signal that gates the first-light setup prompt. Optional so a
    /// board stored by a pre-120 build (no key) still decodes — it reads back `nil` ⇒ unverified ⇒ prompted
    /// once, which is exactly right (it was learned from a guess).
    var verifiedSetup: Bool? = nil

    /// The most-frequently-confirmed angle on this board (the pre-select), or `nil` with no history.
    var usualAngle: Int? { KilterBoardMemory.mostFrequentAngle(angleHistory) }
    /// Whether the user has confirmed this board's layout/size on the wall (see ``verifiedSetup``).
    var isVerified: Bool { verifiedSetup == true }
}

/// Persists the physical Kilter boards this phone has connected to so a return visit **restores the
/// board's layout + size and pre-selects the usual angle automatically** — the fix for "I re-pick my
/// board every single time". Backed by `UserDefaults` (on-device only); the instance is injectable so
/// the remember/recall rules unit-test against an isolated suite with no device and no real defaults.
///
/// This is the multi-board generalization of the single `kilter.lastBoardID` key
/// `KilterBoardController` writes for its own adopt path. That key only ever held a bare identifier (no
/// layout/size/angle), so it can't seed a restore — a board remembered only by a pre-P1 build is simply
/// re-learned on its first reconnect under the new build (nothing is lost, nothing is migrated).
@MainActor
final class KilterBoardMemory {
    private let defaults: UserDefaults
    /// JSON map `peripheralIdentifier.uuidString → RememberedBoard`.
    private let mapKey = "kilter.rememberedBoards"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - Stored map

    /// The full remembered-board map, keyed by `CBPeripheral.identifier`.
    var boards: [UUID: RememberedBoard] {
        get {
            guard let data = defaults.data(forKey: mapKey),
                  let decoded = try? JSONDecoder().decode([String: RememberedBoard].self, from: data)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        set {
            let encodable = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            if let data = try? JSONEncoder().encode(encodable) {
                defaults.set(data, forKey: mapKey)
            }
        }
    }

    /// Remembered boards, newest-seen first — the order the Settings list + arrival pick use.
    var rememberedSorted: [(id: UUID, board: RememberedBoard)] {
        boards.map { (id: $0.key, board: $0.value) }.sorted { $0.board.lastSeen > $1.board.lastSeen }
    }

    var isEmpty: Bool { boards.isEmpty }

    // MARK: - Recall

    /// Recall a board for an arriving connection. **Identifier first** (the stable per-install key); if
    /// that misses, fall back to a **serial cross-check** so a board survives a phone reinstall (which
    /// mints a new `CBPeripheral.identifier` but the board keeps its `#serial`). When more than one entry
    /// shares the serial, pick the **most-recently-seen** one so the result is deterministic. A board only
    /// remembered by a pre-P1 build (the bare `kilter.lastBoardID` identifier, no stored layout/size) has
    /// no map entry, so recall misses and it's simply re-learned on first reconnect.
    func recall(identifier: UUID, serial: String? = nil) -> RememberedBoard? {
        let map = boards
        if let direct = map[identifier] { return direct }
        if let serial, !serial.isEmpty {
            return map.values
                .filter { $0.serial == serial }
                .max { $0.lastSeen < $1.lastSeen }
        }
        return nil
    }

    // MARK: - Mutation

    /// Remember (or update) a board's **identity** on a confirmed connect — layout, size, `lastSeen`, and
    /// any newly-known serial / coarse place (never clobbering a value we already had). It does **not**
    /// touch `angleHistory`: a connect the climber ignores must not reinforce the pre-selected angle, so
    /// the angle is recorded only when the user explicitly confirms/adjusts it via ``confirmAngle``. A
    /// brand-new board is created here with an empty history (no pre-select) and the given default label.
    /// Preserves a user-renamed `label` unless an explicit one is passed.
    func remember(identifier: UUID,
                  layoutId: Int,
                  productSizeId: Int,
                  label: String? = nil,
                  defaultLabel: String? = nil,
                  serial: String? = nil,
                  coarsePlace: CoarsePlace? = nil,
                  at date: Date = .now) {
        var map = boards
        var board = map[identifier] ?? RememberedBoard(
            layoutId: layoutId, productSizeId: productSizeId, angleHistory: [],
            label: label ?? defaultLabel ?? Self.defaultLabel(layoutId: layoutId, serial: serial),
            serial: serial, coarsePlace: coarsePlace, lastSeen: date)
        board.layoutId = layoutId
        board.productSizeId = productSizeId
        if let label { board.label = label }                 // explicit rename only
        if let serial, !serial.isEmpty { board.serial = serial }   // never drop a known serial
        if let coarsePlace { board.coarsePlace = coarsePlace }     // never drop a known place
        board.lastSeen = date
        map[identifier] = board
        boards = map
    }

    /// Record an angle the user **explicitly confirmed/adjusted** for a board (the ribbon's "Got it"),
    /// appending it to `angleHistory` so `usualAngle`/`mostFrequentAngle` track the climber's real habit.
    /// No-op for an unknown id (a confirm only fires for a board we just remembered on connect).
    func confirmAngle(identifier: UUID, angle: Int, at date: Date = .now) {
        var map = boards
        guard var board = map[identifier] else { return }
        board.angleHistory.append(angle)
        board.lastSeen = date
        map[identifier] = board
        boards = map
    }

    /// Confirm a board's **layout + size from the "Set up this board" verifier** (prompt 120): the user
    /// cycled layouts/sizes, watched the wall, and tapped "This looks right". Sets the confirmed layout/size
    /// and flips ``RememberedBoard/verifiedSetup`` true, so future connects trust the restore and the
    /// first-light prompt never fires again for this board. The board is normally already remembered (a
    /// connect precedes any light), so the merge preserves serial / place / angle history; a defensive
    /// insert covers the (unexpected) unremembered case. An explicit `label` renames.
    func confirmSetup(identifier: UUID, layoutId: Int, productSizeId: Int,
                      label: String? = nil, at date: Date = .now) {
        var map = boards
        var board = map[identifier] ?? RememberedBoard(
            layoutId: layoutId, productSizeId: productSizeId, angleHistory: [],
            label: label ?? Self.defaultLabel(layoutId: layoutId, serial: nil),
            serial: nil, coarsePlace: nil, lastSeen: date, verifiedSetup: true)
        board.layoutId = layoutId
        board.productSizeId = productSizeId
        board.verifiedSetup = true
        if let label { board.label = label }
        board.lastSeen = date
        map[identifier] = board
        boards = map
    }

    /// Rename a board's friendly label (Settings). No-op for an unknown id.
    func rename(identifier: UUID, to label: String) {
        var map = boards
        guard var board = map[identifier] else { return }
        board.label = label
        map[identifier] = board
        boards = map
    }

    /// Forget a board entirely — the next connect re-remembers it from scratch (this is "Forget" in
    /// Settings). The pre-P1 `kilter.lastBoardID` key is owned by `KilterBoardController` (its adopt
    /// path), holds no memory data, and is never consulted by recall, so it's left untouched here.
    func forget(identifier: UUID) {
        var map = boards
        map[identifier] = nil
        boards = map
    }

    // MARK: - Pure rules (separately unit-tested, no UserDefaults / no device)

    /// Parse the `#serial` token out of an Aurora advertised local name of the shape
    /// `"<name>#<serial>@<api>"` (e.g. `"Kilter#A1B2C3@3"`). Returns `nil` when there's no `#serial`
    /// segment. Pure + `nonisolated` so it runs in the BLE delegate and in tests with no actor hop.
    nonisolated static func serial(fromLocalName name: String?) -> String? {
        guard let name, let hash = name.firstIndex(of: "#") else { return nil }
        let afterHash = name[name.index(after: hash)...]
        let serial = afterHash.prefix { $0 != "@" }
        let trimmed = serial.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The most-frequently-confirmed angle in a history, breaking ties toward the **most recent** of the
    /// tied angles (the climber's current habit wins over an equally-old one). `nil` for empty history.
    nonisolated static func mostFrequentAngle(_ history: [Int]) -> Int? {
        guard !history.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for angle in history { counts[angle, default: 0] += 1 }
        let maxCount = counts.values.max()!
        // Among the angles tied at the max count, pick the one that appears latest in history.
        let tied = Set(counts.filter { $0.value == maxCount }.keys)
        return history.last { tied.contains($0) }
    }

    /// A reasonable default label for a never-renamed board — the serial when known, else a generic
    /// "Kilter board". Settings lets the user rename it to "8×12 Home" etc.
    nonisolated static func defaultLabel(layoutId: Int, serial: String?) -> String {
        if let serial, !serial.isEmpty { return "Board \(serial)" }
        return "Kilter board"
    }
}

/// Pure place-match rules, isolated so they unit-test with **no `CoreLocation`, no device** (the same
/// honesty bar as `BLEBands` / `isLikelyBoard`). The live `KilterLocationService` feeds these its
/// current fix + the remembered boards; the view renders the suggestion.
enum KilterPlaceMatcher {
    /// The best remembered board to suggest for a current coarse place: among boards whose stored place
    /// is the **same coarse square**, the most-recently-seen one (so a board you used today wins over an
    /// older one at the same gym). `nil` when nothing matches — the graceful BLE-only fall-through.
    static func suggestion(for place: CoarsePlace,
                           in boards: [(id: UUID, board: RememberedBoard)]) -> (id: UUID, board: RememberedBoard)? {
        boards
            .filter { $0.board.coarsePlace?.matches(place) == true }
            .max { $0.board.lastSeen < $1.board.lastSeen }
    }
}

/// Whether the pre-connect **arrival suggestion** ("set up your usual board?") should be raised for a fresh
/// coarse fix. Pure so the once-per-place suppression rule unit-tests with no CoreLocation and no device.
///
/// The bug it fixes: the "already dealt with this" flag lived only in `@State`, so it reset on every app
/// open and the card re-popped at the same gym right after the climber tapped "Set it up". The gate persists
/// a **resolved-place marker** instead: the card is suppressed while the climber is at the place they just
/// resolved it for, but the marker CLEARS the moment a fix lands on a *different* coarse square — so moving
/// to another gym, or returning to a prior one, re-arms the suggestion (the climber's explicit "I still want
/// it when I switch gyms and come back").
enum KilterArrivalGate {
    struct Outcome: Equatable {
        /// Whether to raise the suggestion card now.
        var showSuggestion: Bool
        /// The resolved-place marker to persist after this evaluation (nil = re-armed / not yet resolved).
        var resolvedPlace: CoarsePlace?
        /// The transient "dismissed this visit" flag after this evaluation.
        var dismissedThisVisit: Bool
    }

    /// Decide from a fresh coarse `place`, the last `resolved` place, whether the card was `dismissedThisVisit`,
    /// and whether a remembered board exists here (`hasMatch`).
    static func evaluate(place: CoarsePlace, resolved: CoarsePlace?,
                         dismissedThisVisit: Bool, hasMatch: Bool) -> Outcome {
        // Same square we already resolved this visit → stay quiet, keep the marker.
        if let resolved, resolved.matches(place) {
            return Outcome(showSuggestion: false, resolvedPlace: resolved, dismissedThisVisit: dismissedThisVisit)
        }
        // A different square than the marker means the climber moved → this is a fresh visit: drop the marker
        // and re-arm the transient dismiss so the new place can suggest.
        let dismissed = resolved == nil ? dismissedThisVisit : false
        guard !dismissed, hasMatch else {
            return Outcome(showSuggestion: false, resolvedPlace: nil, dismissedThisVisit: dismissed)
        }
        return Outcome(showSuggestion: true, resolvedPlace: nil, dismissedThisVisit: dismissed)
    }
}
