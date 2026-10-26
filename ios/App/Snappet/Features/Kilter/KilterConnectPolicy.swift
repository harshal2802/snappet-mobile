import Foundation

/// **Pure** decisions behind connecting to a Kilter board (prompt 204) — which advertising board to pick,
/// when to stop looking, whether a failed attempt is retried, and what to tell the climber when it isn't.
/// `KilterBoardController` owns the CoreBluetooth side; this owns the judgement calls so they're unit-tested
/// without a radio (`KilterConnectPolicyTests`).
///
/// What it fixes (device reports: "fails to connect often or takes a long time"):
///  * the remembered-board path used to be a dead end — `retrievePeripherals(withIdentifiers:)` hands back a
///    peripheral even when that board is asleep, out of range or its id went stale, and the attempt then
///    waited out the 12 s watchdog and FAILED without ever scanning. Now the remembered board is tried
///    *while* scanning, and a board found in the scan wins after a short grace;
///  * the first name-matching advert was taken, even a neighbour's board across the gym — now a known board
///    connects at once, otherwise the strongest signal seen in a short window wins;
///  * a transient GATT failure (didFailToConnect, a drop during discovery — routine on BLE) ended the
///    attempt, sometimes silently back to idle — now it retries once before failing, with a reason.
enum KilterConnectPolicy {

    /// An advertising board seen during the scan.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        /// dBm; CoreBluetooth reports 127 when unavailable.
        var rssi: Int
        /// Connected before (`KilterBoardMemory` / the last board) — preferred over any stranger.
        var isKnown: Bool
    }

    /// How long to keep collecting adverts after the first unknown board shows up, so the nearest board
    /// wins over the first one heard.
    static let selectionWindow: Duration = .milliseconds(1200)
    /// How long the remembered board's pending connect gets before a *different* board from the scan is
    /// accepted instead (an asleep remembered board must not block a working one).
    static let rememberedGrace: Duration = .seconds(3)
    static let scanTimeout: Duration = .seconds(15)
    static let connectTimeout: Duration = .seconds(10)
    static let retryDelay: Duration = .milliseconds(600)
    /// How long a dropped board gets to come back on its own before Snappet lets it go. A board takes one
    /// connection at a time, so an endless reconnect would hold a shared gym board long after you've left.
    static let reconnectWindow: Duration = .seconds(60)
    /// Why the board was let go (the strip's subtitle).
    static let gaveUpReconnectMessage = "The board dropped and didn't come back, so Snappet let it go. Tap Connect to reconnect."
    /// Attempts per tap of Connect (the first + one automatic retry).
    static let maxAttempts = 2
    /// Weaker than this is the far side of a big gym — ignored unless nothing else is there.
    static let farRSSI = -92

    /// The board to connect to: the strongest KNOWN board, else the strongest usable signal. A board with
    /// an unavailable RSSI (127) sorts last but is still usable when it's all there is.
    static func pick(_ candidates: [Candidate]) -> Candidate? {
        func strength(_ c: Candidate) -> Int { c.rssi == 127 ? Int.min / 2 : c.rssi }
        if let known = candidates.filter(\.isKnown).max(by: { strength($0) < strength($1) }) { return known }
        let near = candidates.filter { $0.rssi == 127 || $0.rssi >= farRSSI }
        return (near.isEmpty ? candidates : near).max { strength($0) < strength($1) }
    }

    /// Connect the moment this board is heard (no selection window): it's one we've connected before.
    static func connectsImmediately(_ c: Candidate) -> Bool { c.isKnown }

    /// Prompt 205 (user's Q2: "whenever 2+ boards are in range"): the boards worth offering — everything not
    /// at the far edge of the gym (unless that's all there is), strongest first.
    static func nearby(_ candidates: [Candidate]) -> [Candidate] {
        func strength(_ c: Candidate) -> Int { c.rssi == 127 ? Int.min / 2 : c.rssi }
        let near = candidates.filter { $0.rssi == 127 || $0.rssi >= farRSSI }
        return (near.isEmpty ? candidates : near).sorted { strength($0) > strength($1) }
    }

    /// Ask which board instead of picking: two or more boards are in range.
    static func showsChooser(_ candidates: [Candidate]) -> Bool { nearby(candidates).count >= 2 }

    /// Signal strength as 0…4 bars for the chooser.
    static func bars(rssi: Int) -> Int {
        switch rssi {
        case 127: return 1
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        default: return 1
        }
    }

    /// How long "Flash" keeps a board's corners lit before letting it go.
    static let flashDuration: Duration = .seconds(5)

    /// Where an attempt stopped.
    enum Stage: Equatable, Sendable {
        /// Nothing board-like was heard.
        case scan
        /// A board was chosen but the link never came up / dropped before the board was ready.
        case connect
        /// Linked, but the board's lighting service / characteristic wasn't found.
        case discovery
    }

    /// Retry automatically? Not for an empty scan (scanning again won't make a board appear) and not past
    /// `maxAttempts`.
    static func shouldRetry(after stage: Stage, attempt: Int) -> Bool {
        stage != .scan && attempt < maxAttempts
    }

    /// What the climber reads when the attempt finally fails.
    static func failureMessage(_ stage: Stage, sawOtherBoards: Bool = false) -> String {
        switch stage {
        case .scan:
            return "No board found. Check it's switched on, and that no other phone or the Kilter app "
                + "is connected to it — a board takes one connection at a time."
        case .connect:
            return sawOtherBoards
                ? "Found a board but couldn't hold the connection. Move closer and try again."
                : "Couldn't reach the board. Move closer and try again."
        case .discovery:
            return "Connected, but the board didn't answer. Switch it off and on, then try again."
        }
    }
}
