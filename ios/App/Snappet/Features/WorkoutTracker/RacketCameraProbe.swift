#if DEBUG
import SwiftUI

/// Debug-only (device feedback round 2, "the camera view is dark"): `-racketCameraProbe` opens a match's camera check
/// straight from launch, so the preview can be checked on a phone and its `racket.camera` log read with
/// `xcrun devicectl device process launch --console`. Shows the preview only; nothing is recorded. Not in Release.
struct RacketCameraProbe: View {
    static let argument = "-racketCameraProbe"
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private let ex: SessionExercise = {
        var e = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [], displayName: "Probe",
                                kindRaw: SetKind.duration.rawValue)
        e.disciplineRaw = WorkoutDiscipline.racket.rawValue
        RacketMatchParams(sport: .tableTennis).apply(to: &e)
        return e
    }()

    var body: some View {
        RacketGameCover(ex: ex, start: .camera, defaults: RacketRecordingDefaults(),
                        onRecordingMode: { _ in }, onFirstServer: { _, _ in }, onUnit: { _, _ in },
                        onPartSaved: { _, _ in }, onLog: { _ in }, onRecordEverything: { _ in },
                        onMatchOver: { _ in }, onClose: {})
    }
}
#endif
