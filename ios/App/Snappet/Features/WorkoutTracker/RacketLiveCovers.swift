import SwiftUI

/// Which racket cover is open over the live player right now (prompt 263). The covers (`RacketRecordingCover`,
/// `RacketDrillCover`, `RacketGameCover`) register when they set up and leave when they disappear, so:
/// - the Finish intent / `snappet://finish` link can refuse while one is open (F4: finishing would tear the cover down
///   without ending its recording) and the open cover shows why (`racketFinishRefusal`);
/// - crash recovery (`RacketRecordingRecovery`) never touches the log of an entry that is recording right now (F14).
@MainActor
@Observable
final class RacketLiveCovers {
    static let shared = RacketLiveCovers()

    /// Exercise id → the open cover's kind (one at a time in practice; a map so a late disappear can't clear a newer one).
    private(set) var open: [UUID: LiveCoverKind] = [:]
    /// The newest registration, whose cover shows a refusal.
    private(set) var newest: UUID?
    /// The refusal the open cover shows, until OK.
    var refusal: FinishRefusal?

    func opened(_ exerciseID: UUID, _ kind: LiveCoverKind) {
        open[exerciseID] = kind
        newest = exerciseID
    }

    func closed(_ exerciseID: UUID) {
        open[exerciseID] = nil
        if newest == exerciseID { newest = open.keys.first }
        if open.isEmpty { refusal = nil }
    }

    func isOpen(_ exerciseID: UUID) -> Bool { open[exerciseID] != nil }

    /// The open cover's kind (nil ⇒ none open).
    var openKind: LiveCoverKind? { newest.flatMap { open[$0] } ?? open.values.first }

    /// The Finish intent / link arrived while a cover is open: nothing finishes; returns true when it refused.
    func refuseFinishIfOpen() -> Bool {
        guard let r = LiveFinish.refusal(openCover: openKind) else { return false }
        refusal = r
        return true
    }
}

private struct RacketFinishRefusalAlert: ViewModifier {
    let exerciseID: UUID
    @State private var covers = RacketLiveCovers.shared

    func body(content: Content) -> some View {
        content.alert(covers.refusal?.title ?? "",
                      isPresented: Binding(get: { covers.refusal != nil && covers.newest == exerciseID },
                                           set: { if !$0 { covers.refusal = nil } })) {
            Button("OK", role: .cancel) { covers.refusal = nil }
                .accessibilityIdentifier("racket.finishRefused.ok")
        } message: {
            Text(covers.refusal?.message ?? "")
        }
    }
}

extension View {
    /// The open racket cover's "Session not finished" alert (prompt 263, F4).
    func racketFinishRefusal(exerciseID: UUID) -> some View {
        modifier(RacketFinishRefusalAlert(exerciseID: exerciseID))
    }
}
