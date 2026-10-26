import Foundation

/// The boards the climber says they climb on (prompt 205) — listed when downloading the catalog ("Gym ·
/// 12 × 12", "Home · 8 × 12"), so the download keeps every climb that fits **any** of them, and offered as
/// one-tap answers to "which of your boards is this?" the first time each physical board connects.
///
/// Distinct from `KilterBoardMemory` (physical boards this phone has connected to, keyed by Bluetooth id):
/// a "my board" is the climber's own description and gets **linked** to a physical board on first connect.
struct KilterMyBoard: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var layoutId: Int
    var productSizeId: Int
    /// The physical board (`CBPeripheral.identifier`) this was matched to on first connect, if any.
    var linkedBoardID: UUID?
}

/// UserDefaults-backed list of `KilterMyBoard` (UI-test launches use a scratch suite — the prompt-133 rule).
enum KilterMyBoards {
    static let key = "kilter.myBoards"

    static var defaults: UserDefaults {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: { $0.hasPrefix("-uiTest") }),
              let suite = UserDefaults(suiteName: "snappet.uitest.kilterMyBoards") else { return .standard }
        return suite
    }

    static func decode(_ data: Data?) -> [KilterMyBoard] {
        guard let data, let list = try? JSONDecoder().decode([KilterMyBoard].self, from: data) else { return [] }
        return list
    }

    static func load(_ d: UserDefaults = defaults) -> [KilterMyBoard] { decode(d.data(forKey: key)) }

    static func save(_ boards: [KilterMyBoard], _ d: UserDefaults = defaults) {
        d.set(try? JSONEncoder().encode(boards), forKey: key)
    }

    /// Boards not yet matched to a physical board — the "which of your boards is this?" answers.
    static func unlinked(_ boards: [KilterMyBoard]) -> [KilterMyBoard] { boards.filter { $0.linkedBoardID == nil } }

    /// Link `myBoardID` to a physical board (and unlink any other entry pointing at that board).
    static func link(_ myBoardID: UUID, to boardID: UUID, in boards: [KilterMyBoard]) -> [KilterMyBoard] {
        boards.map { b in
            var b = b
            if b.id == myBoardID { b.linkedBoardID = boardID }
            else if b.linkedBoardID == boardID { b.linkedBoardID = nil }
            return b
        }
    }

    /// A starting name for a new entry: the size ("12 × 12 (with kickboard)"), numbered if already used.
    static func suggestedName(sizeName: String, existing: [KilterMyBoard]) -> String {
        let names = Set(existing.map(\.name))
        if !names.contains(sizeName) { return sizeName }
        var n = 2
        while names.contains("\(sizeName) \(n)") { n += 1 }
        return "\(sizeName) \(n)"
    }
}
