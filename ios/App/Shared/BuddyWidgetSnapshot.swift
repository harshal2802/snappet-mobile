import Foundation

/// What the buddy widgets show (progression P4, prompt 152): level, stage, mood, streak, up next. The app
/// publishes it to the App Group whenever Home re-derives progression; the widgets never touch SwiftData.
/// Widgets can't run RealityKit, so the buddy itself is a pre-rendered still picked by `imageName`.
struct BuddyWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = BuddyWidgetSnapshot.currentVersion
    /// `BuddyStage.rawValue` (0 egg … 4 legend).
    var stage: Int
    var stageTitle: String
    var level: Int
    var xpIntoLevel: Int
    var levelCost: Int
    var form: Double
    var mood: String
    var paused: Bool
    var pausedUntil: Date?
    var hatched: Bool
    var streakWeeks: Int
    var freezes: Int
    var upNextName: String?
    var upNextStart: Date?
    var upNextXP: Int?
    var updatedAt: Date

    var fraction: Double { Double(xpIntoLevel) / Double(max(1, levelCost)) }

    /// The still to show: `buddy-<stage>-<mood>` (an unhatched buddy is always the egg).
    var imageName: String { Self.imageName(stage: hatched ? stage : 0, form: form, paused: paused) }

    static let stageKeys = ["egg", "hatchling", "sprout", "adult", "legend"]
    static let moodKeys = ["fired", "steady", "tired", "sleepy", "resting"]

    static func moodKey(form: Double, paused: Bool) -> String {
        if paused { return "resting" }
        switch form {
        case 0.75...: return "fired"
        case 0.45...: return "steady"
        case 0.2...: return "tired"
        default: return "sleepy"
        }
    }

    static func imageName(stage: Int, form: Double, paused: Bool) -> String {
        "buddy-\(stageKeys[min(max(stage, 0), stageKeys.count - 1)])-\(moodKey(form: form, paused: paused))"
    }

    static let placeholder = BuddyWidgetSnapshot(
        stage: 3, stageTitle: "Adult", level: 12, xpIntoLevel: 590, levelCost: 700, form: 0.82, mood: "Fired up",
        paused: false, pausedUntil: nil, hatched: true, streakWeeks: 5, freezes: 1,
        upNextName: "Push Day", upNextStart: nil, upNextXP: 130, updatedAt: .distantPast)
}

enum BuddyWidgetStore {
    static let fileName = "buddy-widget-snapshot.json"
    static let kind = "BuddyWidget"

    static func encode(_ s: BuddyWidgetSnapshot) throws -> Data { try JSONEncoder().encode(s) }

    /// nil for corrupt bytes or a newer contract than this binary understands.
    static func decode(_ data: Data) -> BuddyWidgetSnapshot? {
        guard let s = try? JSONDecoder().decode(BuddyWidgetSnapshot.self, from: data),
              s.version <= BuddyWidgetSnapshot.currentVersion else { return nil }
        return s
    }

    static var fileURL: URL? { WidgetSnapshotStore.containerURL?.appendingPathComponent(fileName) }

    static func write(_ s: BuddyWidgetSnapshot) {
        guard let fileURL, let data = try? encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func read() -> BuddyWidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data)
    }
}
