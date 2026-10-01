import Foundation

/// Hangboard protocols (prompt 140, wireframe frames 1–2, 10): the built-in presets, the plain-English
/// summary every protocol reads back as, and the adaptive duration step the editor's steppers use.
/// Pure (Foundation only) → unit-tested. The structure itself stays `TimedExerciseSpec` (Shared/), so
/// nothing about how a protocol is stored, shared over QR, or backed up changes.
extension TimedExerciseSpec {

    // MARK: - Built-in hangboard presets (PRE-FILL ONLY — a user edit is never snapped back)

    /// Max hangs: 3 sets × 3 hangs of 7 s, 2 min between hangs, 4 min between sets.
    static var maxHangs: TimedExerciseSpec {
        TimedExerciseSpec(mode: .repeaters, workSec: 7, restSec: 120, reps: 3, sets: 3,
                          restBetweenSetsSec: 240, leadInSec: 5)
    }

    /// Endurance repeaters: 10 s on / 6 s off × 24, 2 sets, 6 min between sets.
    static var enduranceRepeaters: TimedExerciseSpec {
        TimedExerciseSpec(mode: .repeaters, workSec: 10, restSec: 6, reps: 24, sets: 2,
                          restBetweenSetsSec: 360, leadInSec: 5)
    }

    /// Contact: 3 sets × 5 reps, each rep until you tap done, 30 s between reps, 3 min between sets.
    static var contact: TimedExerciseSpec {
        TimedExerciseSpec(mode: .repeaters, workSec: 0, restSec: 30, reps: 5, sets: 3,
                          restBetweenSetsSec: 180, leadInSec: 5, selfPacedWork: true)
    }

    /// Abrahangs: low-load hangs, 10 s on / 20 s off × 20, one set.
    static var abrahangs: TimedExerciseSpec {
        TimedExerciseSpec(mode: .repeaters, workSec: 10, restSec: 20, reps: 20, sets: 1, leadInSec: 5)
    }

    // MARK: - Plain-English summary

    /// "3 sets × 3 hangs of 7 s · 2 min between hangs · 4 min between sets · about 25 min" — the one line a
    /// protocol reads back as in the editor and on a routine block. `summary` stays the compact form.
    var sentence: String {
        switch mode {
        case .openCountUp:
            return "Open hold, counted up"
        case .maxHang, .countDown:
            return workSec > 0 ? "One hold of \(Self.spoken(workSec))" : "Open hold, counted up"
        case .emom:
            var s = "An effort at the top of every minute for \(reps) min"
            if sets > 1 { s += " · \(sets) sets" }
            return s + total
        case .repeaters, .tabata:
            let noun = isSelfPaced ? "rep" : (mode == .tabata ? "interval" : "hang")
            var s = sets > 1 ? "\(sets) sets × " : ""
            s += isSelfPaced ? "\(reps) \(noun)\(reps == 1 ? "" : "s"), each until you tap done"
                             : "\(reps) \(noun)\(reps == 1 ? "" : "s") of \(Self.spoken(workSec))"
            if reps > 1, restSec > 0 { s += " · \(Self.spoken(restSec)) between \(noun)s" }
            if sets > 1, restBetweenSetsSec > 0 { s += " · \(Self.spoken(restBetweenSetsSec)) between sets" }
            return s + total
        }
    }

    private var total: String {
        guard let t = totalSeconds, t >= 60 else { return "" }
        let mins = " · about \(Int((Double(t) / 60).rounded())) min"
        return isSelfPaced ? mins + " + your reps" : mins
    }

    /// 7 → "7 s", 120 → "2 min", 150 → "2:30".
    static func spoken(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// How far one tap of a duration stepper moves (prompt 140): fine where precision matters, coarse where
/// it doesn't — a 2-minute rest used to take 120 taps of ±1 s.
enum DurationStep {
    static func step(from seconds: Int, up: Bool) -> Int {
        // Step by the band you're moving within, so 30 → 29 goes down by 1 and 30 → 35 up by 5.
        let v = up ? seconds : max(0, seconds - 1)
        switch v {
        case ..<30: return 1
        case ..<120: return 5
        case ..<600: return 15
        default: return 60
        }
    }

    static func next(_ seconds: Int, up: Bool, range: ClosedRange<Int>) -> Int {
        let s = step(from: seconds, up: up)
        return min(range.upperBound, max(range.lowerBound, seconds + (up ? s : -s)))
    }
}

/// Routine blocks are **copies** of a preset (prompt 140, wireframe frame 10C): editing the preset never
/// changes a routine silently. This finds the copies that are still identical to the preset's old
/// protocol — the ones "Update routines too?" may update. A copy the user has customised since is left alone.
enum ProtocolCopies {
    /// The library id a block made from a saved preset carries (`LibraryBuilder`).
    static func exerciseID(forPreset id: UUID) -> String { "timed:\(id.uuidString)" }

    static func matchingBlockIndices(in blocks: [RoutineExercise], presetID: UUID,
                                     oldSpec: TimedExerciseSpec) -> [Int] {
        let key = exerciseID(forPreset: presetID)
        return blocks.indices.filter { blocks[$0].exerciseId == key && blocks[$0].timedSpec == oldSpec }
    }
}
