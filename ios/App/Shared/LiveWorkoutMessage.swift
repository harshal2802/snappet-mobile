import Foundation

/// The wire shape shared by the phone (`AppleWatchMetricsSource`) and the watch
/// (`WatchConnectivityLink`). Compiled into **both** targets (see `project.yml`):
/// keeping one source of truth for the message keys means the relay can't drift
/// between the two sides.
///
/// `WCSession` only carries property-list types (`[String: Any]`), so each message
/// encodes to / decodes from a plain dictionary. The `kind` key discriminates the
/// messages the relay needs (decisions.md 2026-06-01):
///   - `start(activityType:)` — phone → watch: begin an `HKWorkoutSession` of this
///     `HKWorkoutActivityType` raw value.
///   - `stop` — phone → watch: end the session.
///   - `pause` / `resume` — **bidirectional** control: either side can pause/resume the
///     live workout (the watch pauses its `HKWorkoutSession`; the phone freezes its
///     overlay + Live Activity). The receiver applies the state *without* echoing it back,
///     so a pause tapped on either device can't ping-pong (live-workout-studio next pass).
///   - `metrics(hrBpm:energyKcal:t:)` — watch → phone: a streamed live sample, `t`
///     seconds since the watch session started (the phone re-bases this onto the
///     `WorkoutSession.startedAt` timeline when buffering).
enum LiveWorkoutMessage: Equatable, Sendable {
    /// `maxHR` carries the user's resolved max HR (Phase 2) so the watch face tints its HR zone off
    /// the same personalized ceiling as the phone; `restHR` (Phase 4) lets the watch compute the
    /// live recovery-ready nudge. Both `nil` → the watch falls back to `defaultMaxHR` and shows no
    /// nudge — back-compatible with senders that don't include them.
    case start(activityType: UInt, maxHR: Double?, restHR: Double?)
    case stop
    case pause
    case resume
    case metrics(hrBpm: Double, energyKcal: Double, t: Double)

    private enum Key {
        static let kind = "kind"
        static let activityType = "activityType"
        static let maxHR = "maxHR"
        static let restHR = "restHR"
        static let hrBpm = "hrBpm"
        static let energyKcal = "energyKcal"
        static let t = "t"
    }

    private enum Kind: String {
        case start, stop, pause, resume, metrics
    }

    /// Property-list dictionary suitable for `WCSession.sendMessage`/`transferUserInfo`.
    var payload: [String: Any] {
        switch self {
        case .start(let activityType, let maxHR, let restHR):
            var d: [String: Any] = [Key.kind: Kind.start.rawValue, Key.activityType: activityType]
            if let maxHR { d[Key.maxHR] = maxHR }   // omitted when unknown (back-compat)
            if let restHR { d[Key.restHR] = restHR }
            return d
        case .stop:
            return [Key.kind: Kind.stop.rawValue]
        case .pause:
            return [Key.kind: Kind.pause.rawValue]
        case .resume:
            return [Key.kind: Kind.resume.rawValue]
        case .metrics(let hrBpm, let energyKcal, let t):
            return [
                Key.kind: Kind.metrics.rawValue,
                Key.hrBpm: hrBpm,
                Key.energyKcal: energyKcal,
                Key.t: t,
            ]
        }
    }

    /// Decode a received `WCSession` payload, or `nil` if it isn't one of ours.
    init?(payload: [String: Any]) {
        guard let raw = payload[Key.kind] as? String, let kind = Kind(rawValue: raw) else {
            return nil
        }
        switch kind {
        case .start:
            guard let type = payload[Key.activityType] as? UInt else { return nil }
            self = .start(activityType: type, maxHR: payload[Key.maxHR] as? Double,
                          restHR: payload[Key.restHR] as? Double)
        case .stop:
            self = .stop
        case .pause:
            self = .pause
        case .resume:
            self = .resume
        case .metrics:
            // Require every field — a missing/mistyped value must drop the message, not
            // decode as a phantom 0-bpm sample that poisons the HR buffer.
            guard let hr = payload[Key.hrBpm] as? Double,
                  let kcal = payload[Key.energyKcal] as? Double,
                  let t = payload[Key.t] as? Double else { return nil }
            self = .metrics(hrBpm: hr, energyKcal: kcal, t: t)
        }
    }
}
