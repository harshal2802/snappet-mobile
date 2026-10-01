import Foundation

/// The training buddy's growth stage (prototype, prompt 147). Driven by the permanent level later;
/// the prototype lets you pick it directly.
enum BuddyStage: Int, CaseIterable, Sendable, Identifiable {
    case egg, hatchling, sprout, adult, legend

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .egg: "Egg"
        case .hatchling: "Hatchling"
        case .sprout: "Sprout"
        case .adult: "Adult"
        case .legend: "Legend"
        }
    }
}

/// Everything the 3D buddy needs to draw itself, derived from stage + Form + pause. Pure, so the
/// mapping is unit-tested and any art style (code-built creature now, model packs later) reads the
/// same numbers. Form never changes the stage: it only changes mood — colour, glow, energy, eyes.
struct BuddyLook: Equatable, Sendable {
    var stage: BuddyStage
    /// 0…1 — recent consistency. Low Form = tired, never smaller.
    var form: Double
    /// Pause mode (rest week, injury): asleep, Form held.
    var paused: Bool

    init(stage: BuddyStage, form: Double, paused: Bool = false) {
        self.stage = stage
        self.form = min(1, max(0, form))
        self.paused = paused
    }

    private var i: Int { stage.rawValue }

    /// Overall size: grows with stage only.
    var bodyScale: Double { [0.62, 0.72, 0.84, 0.96, 1.06][i] }

    /// Base colour: the egg is cream, then teal deepening to violet at Legend.
    var hue: Double { [0.11, 0.47, 0.50, 0.55, 0.75][i] }
    var saturation: Double {
        if stage == .egg { return 0.2 }
        return paused ? 0.3 : 0.25 + 0.55 * form
    }
    var brightness: Double { paused ? 0.55 : 0.55 + 0.4 * form }

    /// Emissive glow — later stages can glow brighter, but only when Form is high.
    var glow: Double { paused ? 0 : form * [0, 0.1, 0.2, 0.35, 0.6][i] }

    /// Idle bob: energetic when Form is high, a slow breath when resting.
    var bobHz: Double { paused ? 0.18 : 0.35 + 0.9 * form }
    var bobHeight: Double { paused ? 0.004 : 0.008 + 0.03 * form }

    /// 0 = closed, 1 = wide open. An egg only peeks.
    var eyeOpen: Double {
        if paused { return 0.06 }
        let open = 0.3 + 0.7 * form
        return stage == .egg ? min(open, 0.6) : open
    }

    /// Forward slump in radians when tired.
    var droop: Double { paused ? 0.12 : (1 - form) * 0.22 }

    var antennae: Int { [0, 0, 1, 2, 2][i] }
    var hasShellCup: Bool { stage == .hatchling }
    var hasArms: Bool { stage == .adult || stage == .legend }
    var hasCrown: Bool { stage == .legend }
    /// Orbiting sparks — earned by the top stages when Form is high.
    var sparks: Int {
        if paused { return 0 }
        switch stage {
        case .legend: return form >= 0.4 ? 3 : 1
        case .adult: return form >= 0.7 ? 1 : 0
        default: return 0
        }
    }

    var mood: String {
        if paused { return "Resting — Form is held" }
        switch form {
        case 0.75...: return "Fired up"
        case 0.45...: return "Steady"
        case 0.2...: return "Tired"
        default: return "Sleepy"
        }
    }
}
