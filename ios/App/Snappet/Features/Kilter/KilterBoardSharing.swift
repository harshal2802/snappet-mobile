import Foundation

/// **Pure rules for sharing a Kilter board** (prompt 207). A board takes ONE Bluetooth connection, and a connected
/// board stops advertising — so while Snappet held the link for a whole session, nobody else (Snappet or the Kilter
/// app) could even find it (user's real-board test, 2026-10-26). Aurora boards keep the last climb lit after a
/// disconnect (user-confirmed), so Snappet now holds the board only while you're lighting climbs: after a short
/// idle it lets go, and the next light reconnects directly. Per board; off ⇒ stay connected (a home board).
enum KilterBoardSharing {
    /// The idle times to choose from. User's pick (2026-10-26): default 10 s, with longer options.
    static let idleOptions: [Int] = [10, 30, 60, 120, 300]
    static let defaultIdleSeconds = 10
    /// Lighting a released board reconnects directly; no answer by then ⇒ someone else is connected to it.
    static let relightTimeout: Duration = .seconds(5)

    /// A board's sharing setting: on unless switched off; the idle time snapped to an offered option.
    struct Setting: Equatable, Sendable {
        var letGoWhenIdle: Bool
        var idleSeconds: Int
        static let `default` = Setting(letGoWhenIdle: true, idleSeconds: defaultIdleSeconds)
    }

    static func setting(for board: RememberedBoard?) -> Setting {
        guard let board else { return .default }
        let seconds = board.idleSeconds.flatMap { s in idleOptions.contains(s) ? s : nil } ?? defaultIdleSeconds
        return Setting(letGoWhenIdle: board.letGoWhenIdle ?? true, idleSeconds: seconds)
    }

    /// When to let go after the last light, or `nil` to keep holding (sharing off).
    static func letGoAt(lastLight: Date, setting: Setting) -> Date? {
        setting.letGoWhenIdle ? lastLight.addingTimeInterval(TimeInterval(setting.idleSeconds)) : nil
    }

    /// "10 s", "1 min", "5 min".
    static func label(seconds: Int) -> String { seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min" }

    /// What the climber reads when lighting a released board gets no answer.
    static func busyMessage(board name: String?) -> String {
        "Someone else is on \(name ?? "the board"). A board takes one phone at a time — try again once they’ve lit their climb."
    }
}
