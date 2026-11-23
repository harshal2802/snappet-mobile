import XCTest
import SwiftData
@testable import Snappet

/// One undo step and one save per continuous gesture (prompt 299): the pure `UndoStack` transaction,
/// and the Studio view model's `beginGesture` / `endGesture` around slider ticks.
final class StudioUndoGestureTests: XCTestCase {

    // MARK: UndoStack transaction (pure)

    /// Many values inside one transaction make exactly one step, holding the value from before it.
    func testTransactionMakesOneStepHoldingThePreGestureValue() {
        var u = UndoStack(0)
        u.commit(1)
        u.beginTransaction()
        XCTAssertTrue(u.isInTransaction)
        for v in 2...40 { u.replaceCurrent(v) }
        XCTAssertEqual(u.current, 40)                  // the value follows the gesture live
        XCTAssertTrue(u.endTransactionIfChanged())
        XCTAssertFalse(u.isInTransaction)
        u.undo(); XCTAssertEqual(u.current, 1)         // one undo → the pre-gesture value
        u.undo(); XCTAssertEqual(u.current, 0)
        XCTAssertFalse(u.canUndo)
        u.redo(); u.redo(); XCTAssertEqual(u.current, 40)
    }

    /// A gesture that ends where it started, or never moved, leaves the stack untouched — redo too.
    func testTransactionWithNoChangeMakesNoStepAndKeepsRedo() {
        var u = UndoStack(0)
        u.commit(1); u.undo()                          // current 0, redo → 1
        u.beginTransaction()
        XCTAssertFalse(u.endTransactionIfChanged())    // touched, never moved
        u.beginTransaction()
        u.replaceCurrent(7); u.replaceCurrent(0)       // moved and came back
        XCTAssertFalse(u.endTransactionIfChanged())
        XCTAssertFalse(u.canUndo)
        XCTAssertTrue(u.canRedo)
        u.redo(); XCTAssertEqual(u.current, 1)
    }

    /// The redo branch survives opening a gesture and is cleared once, when the gesture is recorded.
    func testTransactionClearsRedoOnceWhenItRecordsAStep() {
        var u = UndoStack(0)
        u.commit(1); u.commit(2); u.undo()             // current 1, redo → 2
        u.beginTransaction()
        XCTAssertTrue(u.canRedo)
        u.replaceCurrent(5); u.replaceCurrent(6)
        u.endTransactionIfChanged()
        XCTAssertFalse(u.canRedo)
        u.undo(); XCTAssertEqual(u.current, 1)
        u.redo(); XCTAssertEqual(u.current, 6)         // the gesture's own redo is intact
    }

    /// Outside a transaction `replaceCurrent` is a plain commit, and ending nothing does nothing.
    func testReplaceOutsideATransactionIsAPlainCommit() {
        var u = UndoStack(0)
        u.replaceCurrent(1); u.replaceCurrent(2)
        u.undo(); XCTAssertEqual(u.current, 1)
        u.undo(); XCTAssertEqual(u.current, 0)
        XCTAssertFalse(u.endTransactionIfChanged())
        XCTAssertTrue(u.canRedo)
    }

    /// `commit`, `undo` and `redo` close an open transaction first, so a gesture is never lost and
    /// never left open. Beginning twice keeps the first pre-gesture value.
    func testCommitAndUndoCloseAnOpenTransaction() {
        var u = UndoStack(0)
        u.beginTransaction(); u.replaceCurrent(3)
        u.beginTransaction(); u.replaceCurrent(4)      // still the same gesture
        u.commit(9)                                    // closes it: steps hold 0, then 4
        XCTAssertFalse(u.isInTransaction)
        u.undo(); XCTAssertEqual(u.current, 4)
        u.undo(); XCTAssertEqual(u.current, 0)
        XCTAssertFalse(u.canUndo)

        var w = UndoStack(0)
        w.beginTransaction(); w.replaceCurrent(5)
        w.undo()                                       // the gesture becomes a step, then is undone
        XCTAssertEqual(w.current, 0)
        XCTAssertFalse(w.isInTransaction)
        w.redo(); XCTAssertEqual(w.current, 5)
    }

    /// A recorded gesture counts as one step against the history limit.
    func testTransactionRespectsLimit() {
        var u = UndoStack(0, limit: 2)
        u.commit(1); u.commit(2)
        u.beginTransaction()
        for v in 3...20 { u.replaceCurrent(v) }
        u.endTransactionIfChanged()
        u.undo(); u.undo()
        XCTAssertEqual(u.current, 1)
        XCTAssertFalse(u.canUndo)
    }

    // MARK: View model (in-memory store)

    @MainActor
    private func makeViewModel() throws -> (StudioEditorViewModel, StudioProject, ModelContainer) {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Gesture")
        project.clips = [TimelineClip(sessionMediaID: UUID(), localIdentifier: "A", isPhoto: false,
                                      order: 0, trimStart: 0, trimEnd: nil)]
        container.mainContext.insert(project)
        return (StudioEditorViewModel(project: project, context: container.mainContext), project, container)
    }

    /// Undo until nothing is left; the number of presses is the number of undo steps.
    @MainActor
    private func undoSteps(_ vm: StudioEditorViewModel) -> Int {
        var n = 0
        while vm.canUndo { vm.undoEdit(); n += 1 }
        return n
    }

    /// Thirty opacity ticks inside one drag: the view model follows every tick, the stored project
    /// is written once at the end, and one Undo restores the value from before the drag.
    @MainActor
    func testSliderTicksInsideOneGestureMakeOneUndoStepAndOneSave() throws {
        let (vm, project, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.addText("Hello")                            // step 1
        let id = try XCTUnwrap(vm.overlays.first?.id)
        let savedBefore = project.updatedAt

        vm.beginGesture()
        for tick in 1...30 { vm.setOverlayOpacity(id, 1 - Double(tick) * 0.02) }
        XCTAssertEqual(try XCTUnwrap(vm.overlays.first).opacity, 0.4, accuracy: 1e-9)   // live
        XCTAssertEqual(project.overlays.first?.opacity, 1)                               // not saved yet
        XCTAssertEqual(project.updatedAt, savedBefore)
        vm.endGesture()
        XCTAssertEqual(try XCTUnwrap(project.overlays.first).opacity, 0.4, accuracy: 1e-9)
        XCTAssertGreaterThan(project.updatedAt, savedBefore)
        let savedAfter = project.updatedAt
        vm.endGesture()                                // a second end does nothing
        XCTAssertEqual(project.updatedAt, savedAfter)

        vm.undoEdit()                                  // ONE undo → the pre-drag opacity
        XCTAssertEqual(vm.overlays.first?.opacity, 1)
        XCTAssertEqual(project.overlays.first?.opacity, 1)
        XCTAssertEqual(undoSteps(vm), 1)               // only "add text" is left
        XCTAssertTrue(vm.overlays.isEmpty)
    }

    /// The Size slider and the HR tile opacity slider take the same path.
    @MainActor
    func testSizeAndTileOpacityDragsAreOneStepEach() throws {
        let (vm, project, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.addText("Hello")                            // step 1
        let id = try XCTUnwrap(vm.overlays.first?.id)
        vm.updateHROverlay(HROverlayConfig(normalizedX: 0.5, normalizedY: 0.8, scale: 0.4,
                                           colorHex: "#FF0000", showBPM: true, zoneColored: false,
                                           tile: HRTile.make(template: .hero)))   // step 2
        XCTAssertEqual(vm.hrTile?.opacity, 1)

        vm.beginGesture()
        for tick in 1...20 { vm.setOverlayScale(id, 1 + Double(tick) * 0.05) }
        vm.endGesture()                                // step 3
        XCTAssertEqual(try XCTUnwrap(project.overlays.first).scale, 2, accuracy: 1e-9)

        vm.beginGesture()
        for tick in 1...20 { vm.setTileOpacity(1 - Double(tick) * 0.01) }
        XCTAssertEqual(try XCTUnwrap(vm.hrTile).opacity, 0.8, accuracy: 1e-9)   // live
        XCTAssertEqual(project.hrOverlay?.tile?.opacity, 1)                      // not saved mid-drag
        vm.endGesture()                                // step 4
        XCTAssertEqual(try XCTUnwrap(project.hrOverlay?.tile).opacity, 0.8, accuracy: 1e-9)

        XCTAssertEqual(undoSteps(vm), 4)
    }

    /// With no gesture open (a VoiceOver adjust, a pinch that ends on the canvas) each call is a
    /// plain step that saves at once, as before. A drag that ends where it began makes no step.
    @MainActor
    func testTicksOutsideAGestureAndAnUnchangedDrag() throws {
        let (vm, project, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.addText("Hello")
        let id = try XCTUnwrap(vm.overlays.first?.id)
        vm.setOverlayOpacity(id, 0.5)
        XCTAssertEqual(project.overlays.first?.opacity, 0.5)
        vm.setOverlayOpacity(id, 0.25)
        let saved = project.updatedAt

        vm.beginGesture()
        vm.setOverlayOpacity(id, 0.9); vm.setOverlayOpacity(id, 0.25)
        vm.endGesture()
        XCTAssertEqual(project.updatedAt, saved)       // nothing changed → no save, no step
        XCTAssertEqual(undoSteps(vm), 3)
    }

    /// Undo during an open drag closes the drag first; a different edit during a drag is its own
    /// step and is saved; a drag cannot begin, and its ticks do nothing, while a bake renders.
    @MainActor
    func testUndoOtherEditsAndBakeLockDuringAGesture() throws {
        let (vm, project, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.addText("Hello")
        let id = try XCTUnwrap(vm.overlays.first?.id)

        vm.beginGesture()
        vm.setOverlayOpacity(id, 0.6); vm.setOverlayOpacity(id, 0.3)
        vm.undoEdit()                                  // drag recorded, then undone
        XCTAssertEqual(vm.overlays.first?.opacity, 1)
        XCTAssertTrue(vm.canRedo)
        vm.redoEdit()
        XCTAssertEqual(vm.overlays.first?.opacity, 0.3)

        vm.beginGesture()
        vm.setOverlayOpacity(id, 0.7)
        vm.rename("Other")                             // closes the drag, then its own step
        XCTAssertEqual(project.title, "Other")
        XCTAssertEqual(project.overlays.first?.opacity, 0.7)
        vm.setOverlayOpacity(id, 0.1)                  // the drag is closed → a plain step, saved
        XCTAssertEqual(project.overlays.first?.opacity, 0.1)

        vm.bakeState = .baking
        vm.beginGesture()
        vm.setOverlayOpacity(id, 0.9)
        vm.endGesture()
        XCTAssertEqual(vm.overlays.first?.opacity, 0.1)
        XCTAssertEqual(project.overlays.first?.opacity, 0.1)
        vm.bakeState = .idle
        XCTAssertEqual(undoSteps(vm), 5)               // add, drag, drag, rename, plain tick
    }
}
