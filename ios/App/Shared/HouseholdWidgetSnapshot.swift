import Foundation

/// What the household widget and the watch show (household prompt 04): the pet, the goal, your chores today
/// and any running power hour. The app publishes it to the App Group (widget) and as WatchConnectivity
/// application context (watch); neither surface touches SwiftData.
struct HouseholdWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Chore: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        var emoji: String
        /// "S" / "M" / "L".
        var effort: String
        var done: Bool
        var overdueDays: Int
    }

    struct PowerHour: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
        var done: Int
        var target: Int
    }

    var version = HouseholdWidgetSnapshot.currentVersion
    var householdName: String
    var petName: String
    var level: Int
    /// `BuddyStage.rawValue`.
    var stage: Int
    var mood: Double
    var paused: Bool
    var goalDone: Int
    /// 0 = no goal this week.
    var goalTarget: Int
    /// Mine today: not done first, at most a handful.
    var chores: [Chore]
    var powerHour: PowerHour?
    var updatedAt: Date

    /// The pet's still, from the buddy stills (an egg until level 2).
    var imageName: String { BuddyWidgetSnapshot.imageName(stage: stage, form: mood, paused: paused) }

    var remaining: Int { chores.filter { !$0.done }.count }

    static let placeholder = HouseholdWidgetSnapshot(
        householdName: "Our home", petName: "Biscuit", level: 7, stage: 2, mood: 0.8, paused: false,
        goalDone: 28, goalTarget: 40,
        chores: [Chore(id: UUID(), name: "Dishes", emoji: "🍽️", effort: "S", done: true, overdueDays: 0),
                 Chore(id: UUID(), name: "Bins out", emoji: "🗑️", effort: "S", done: false, overdueDays: 0),
                 Chore(id: UUID(), name: "Hoover", emoji: "🧹", effort: "M", done: false, overdueDays: 0)],
        powerHour: nil, updatedAt: .distantPast)
}

enum HouseholdWidgetStore {
    static let fileName = "household-widget-snapshot.json"
    static let kind = "HouseholdWidget"

    static func encode(_ s: HouseholdWidgetSnapshot) throws -> Data { try JSONEncoder().encode(s) }

    /// nil for corrupt bytes or a newer contract than this binary understands.
    static func decode(_ data: Data) -> HouseholdWidgetSnapshot? {
        guard let s = try? JSONDecoder().decode(HouseholdWidgetSnapshot.self, from: data),
              s.version <= HouseholdWidgetSnapshot.currentVersion else { return nil }
        return s
    }

    static var fileURL: URL? { WidgetSnapshotStore.containerURL?.appendingPathComponent(fileName) }

    static func write(_ s: HouseholdWidgetSnapshot) {
        guard let fileURL, let data = try? encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func read() -> HouseholdWidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data)
    }

    static func remove() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// A chore ticked (or unticked) away from the app: in a widget or on the watch. Records the ABSOLUTE
/// desired state and when it was tapped, so applying it is idempotent and the op carries the real time.
struct ChoreToggle: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var choreID: UUID
    var desired: Bool
    var requestedAt: Date

    init(id: UUID = UUID(), choreID: UUID, desired: Bool, requestedAt: Date = Date()) {
        self.id = id
        self.choreID = choreID
        self.desired = desired
        self.requestedAt = requestedAt
    }
}

/// The App-Group outbox of chore toggles: one file per tap (no cross-process read-modify-write), the
/// `WidgetOutbox` pattern. The app applies them and removes only what it applied.
enum ChoreOutbox {
    static var directoryURL: URL? {
        WidgetSnapshotStore.containerURL?.appendingPathComponent("chore-outbox", isDirectory: true)
    }

    static func append(_ toggle: ChoreToggle) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(toggle) else { return }
        try? data.write(to: dir.appendingPathComponent("\(toggle.id.uuidString).json"), options: .atomic)
    }

    static func pending() -> [ChoreToggle] {
        guard let dir = directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(ChoreToggle.self, from: $0) } }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    static func remove(ids: [UUID]) {
        guard let dir = directoryURL else { return }
        for id in ids { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json")) }
    }
}

/// Watch ↔ phone household messages (property-list dictionaries, like `LiveWorkoutMessage`).
enum HouseholdWatchMessage: Equatable, Sendable {
    /// Phone → watch, as application context: the latest snapshot (JSON).
    case snapshot(Data)
    /// Watch → phone: a tick or untick.
    case toggle(ChoreToggle)

    private static let kindKey = "householdKind"

    var payload: [String: Any] {
        switch self {
        case .snapshot(let data):
            return [Self.kindKey: "snapshot", "data": data]
        case .toggle(let t):
            return [Self.kindKey: "toggle", "id": t.id.uuidString, "chore": t.choreID.uuidString,
                    "desired": t.desired, "at": t.requestedAt.timeIntervalSince1970]
        }
    }

    init?(payload: [String: Any]) {
        switch payload[Self.kindKey] as? String {
        case "snapshot":
            guard let data = payload["data"] as? Data else { return nil }
            self = .snapshot(data)
        case "toggle":
            guard let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let chore = (payload["chore"] as? String).flatMap(UUID.init(uuidString:)),
                  let desired = payload["desired"] as? Bool,
                  let at = payload["at"] as? Double else { return nil }
            self = .toggle(ChoreToggle(id: id, choreID: chore, desired: desired, requestedAt: Date(timeIntervalSince1970: at)))
        default:
            return nil
        }
    }
}
