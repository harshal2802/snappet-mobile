import SwiftUI

// MARK: - The camera while recording (prompt 256, issue #448 part 2)
//
// What a recording screen hands the pro camera (`RacketProCameraView.live`): the top line, the red timer, the view strip
// or the break's actions, Tag / Pause and Mark beside the stop square, and at most one banner (warm, interrupted, low
// space) or stop card (too hot, storage full) from the pure `RacketCameraBanner`. The covers build it from their machine
// and flow; the camera draws it in Apple Camera's layout, upright or sideways.

struct RacketCameraLive {
    struct Action {
        let title: String
        let id: String
        var label: String? = nil
        var enabled = true
        let action: () -> Void
    }

    enum Tone { case plain, amber, red }

    /// The top bar's centre.
    enum Centre {
        /// The red timer pill ("00:09:41", "01:48 left"); `a11y` is its accessibility label ("Recording 00:09:41").
        case timer(String, a11y: String, id: String)
        /// The break's amber line ("Game 2 in 0:45").
        case amber(String, id: String)
        /// Red text on a dark pill ("Stopped at 24:18").
        case stopped(String, id: String)
    }

    struct Banner {
        let tone: Tone
        let title: String
        let id: String
        var line: String? = nil
        var primary: Action? = nil
        var secondary: Action? = nil
    }

    /// A stop that takes over the picture (ProCameraHot; storage full).
    struct Card {
        let title: String
        let line: String
        let primary: Action?
        let secondary: Action?
    }

    var title: String
    var titleID: String
    var titleTone: Tone = .plain
    var centre: Centre?
    /// The quality can't change while a file is being written.
    var qualityLocked = true
    var showsLenses = true
    /// The view strip (DIM / CAMERA / STATS); nil ⇒ `stripActions` (the break's).
    var views: Binding<RacketRecordingShow>?
    var viewIDPrefix = "racket.rec.show"
    var stripActions: [Action] = []
    /// "Not recording. Lens and quality are unlocked."
    var notice: String? = nil
    /// A wide button above the strip ("New game starts").
    var above: Action? = nil
    var banner: Banner? = nil
    var card: Card? = nil
    var left: Action? = nil
    var right: Action? = nil
    /// The red square (stop); false ⇒ the red circle (start, during a break).
    var shutterStops = true
    let shutter: Action
    /// Dim: the big score and its caption on black.
    var dim: (score: String, caption: String)? = nil
    var dimScoreID = "racket.game.score"
    var dimCaptionID = "racket.game.caption"
    /// Something else in place of the picture (Stats, a tiebreak).
    var middle: AnyView? = nil
    /// The break: the thumbnail and Options in place of Tag and Mark.
    var thumbnailAndOptions = false

    /// The picture shows (not Dim, not Stats, not a stop card).
    var showsPicture: Bool { dim == nil && middle == nil && card == nil }
}

extension RacketCameraLive {
    /// The camera's banner for the pure decision: copy, tone and actions. `nextFormat` is "HD · 30 from next game"
    /// (nil when it changes nothing); `onDim` switches the view to Dim.
    static func banner(_ b: RacketCameraBanner, nextFormat: Action?, onDim: @escaping () -> Void,
                       onResume: @escaping () -> Void, onEnd: (title: String, action: () -> Void),
                       onFreeSpace: @escaping () -> Void) -> Banner? {
        switch b {
        case .none, .hot, .full: return nil
        case .warm(let f):
            return Banner(tone: .amber, title: RacketCameraBanner.warmLine(f), id: "racket.camera.warm",
                          primary: nextFormat, secondary: Action(title: "Dim", id: "racket.camera.warmDim", action: onDim))
        case .interrupted(let r, let saved):
            return Banner(tone: .red, title: RacketInterruptionCopy.title(r), id: "racket.camera.interrupted",
                          line: RacketInterruptionCopy.line(r, savedUpToSec: saved),
                          primary: Action(title: "Resume now", id: "racket.int.resume", action: onResume),
                          secondary: Action(title: onEnd.title, id: "racket.int.end", action: onEnd.action))
        case .lowSpace(let room):
            return Banner(tone: .amber, title: RacketCameraBanner.spaceLine(room), id: "racket.camera.lowSpace",
                          primary: nextFormat,
                          secondary: Action(title: "Free space", id: "racket.camera.freeSpace", action: onFreeSpace))
        }
    }

    /// The stop card (too hot / storage full), or nil.
    static func card(_ b: RacketCameraBanner, onResume: @escaping () -> Void, keepScoring: Action?,
                     onEnd: (title: String, action: () -> Void)) -> Card? {
        switch b {
        case .hot(let saved, let canResume):
            return Card(title: RacketInterruptionCopy.title(.tooHot), line: RacketInterruptionCopy.hotLine(savedUpToSec: saved),
                        primary: Action(title: "Resume filming when cool", id: "racket.camera.resumeCool",
                                        label: canResume ? "Resume filming" : "Resume filming when cool",
                                        enabled: canResume, action: onResume),
                        secondary: keepScoring ?? Action(title: onEnd.title, id: "racket.int.end", action: onEnd.action))
        case .full(let saved):
            return Card(title: RacketInterruptionCopy.title(.storageFull),
                        line: RacketInterruptionCopy.line(.storageFull, savedUpToSec: saved),
                        primary: Action(title: onEnd.title, id: "racket.int.end", action: onEnd.action),
                        secondary: keepScoring)
        default: return nil
        }
    }
}

#if DEBUG
/// UI tests only (`-uiTestCameraTrouble`): stand-ins for what a phone reports — heat rising and falling, a call starting
/// and ending — on the fake camera (the simulator has none of them).
struct RacketCameraTroubleButtons: View {
    let recorder: RacketRecorder
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(RacketRecorder.Simulated.allCases, id: \.self) { s in
                Button("T:\(s.rawValue)") { recorder.simulate(s) }.accessibilityIdentifier("racket.test.\(s.rawValue)")
            }
        }
        .font(.system(size: 9))
    }
}
#endif
