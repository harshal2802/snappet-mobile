import XCTest
@testable import Snappet

/// Unit tests for the **pure** studio editor operations (no device, no SwiftData): structural edits
/// keep `order` contiguous, removing a clip drops its transition, split produces adjacent clips (and
/// no-ops on degenerate cuts / photos), transitions set/clear, and the generic undo/redo stack.
final class StudioProjectEditorTests: XCTestCase {

    private func empty() -> StudioProjectSnapshot {
        StudioProjectSnapshot(title: "T", aspectRaw: "portrait9x16", backgroundRaw: "black",
                              clips: [], transitions: [], overlays: [], audioTracks: [])
    }
    private func video(_ order: Int, id: UUID = UUID(), trimStart: Double = 0, trimEnd: Double? = nil,
                       speed: Double = 1) -> TimelineClip {
        TimelineClip(id: id, sessionMediaID: nil, localIdentifier: "v\(order)", isPhoto: false,
                     order: order, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
    }

    // MARK: - add / remove / move

    func testAddClipAppendsAndIndexes() {
        var s = empty()
        s = StudioProjectEditor.addClip(s, video(0))
        s = StudioProjectEditor.addClip(s, video(0))   // order overwritten on add
        XCTAssertEqual(StudioGeometry.ordered(s.clips).map(\.order), [0, 1])
    }

    func testRemoveClipReindexesAndDropsTransition() {
        let a = video(0), b = video(1), c = video(2)
        var s = empty(); s.clips = [a, b, c]
        s.transitions = [StudioTransition(afterClipID: a.id, kind: .dissolve)]
        s = StudioProjectEditor.removeClip(s, id: a.id)
        XCTAssertEqual(StudioGeometry.ordered(s.clips).map(\.localIdentifier), ["v1", "v2"])
        XCTAssertEqual(StudioGeometry.ordered(s.clips).map(\.order), [0, 1])   // contiguous again
        XCTAssertTrue(s.transitions.isEmpty)                                   // a's transition gone
    }

    func testMoveClipReorders() {
        let a = video(0), b = video(1), c = video(2)
        var s = empty(); s.clips = [a, b, c]
        s = StudioProjectEditor.moveClip(s, id: c.id, toIndex: 0)
        XCTAssertEqual(StudioGeometry.ordered(s.clips).map(\.localIdentifier), ["v2", "v0", "v1"])
        XCTAssertEqual(StudioGeometry.ordered(s.clips).map(\.order), [0, 1, 2])
    }

    // MARK: - trim / speed / filter

    func testTrimAndSpeedAndFilter() {
        let a = video(0, trimEnd: 10)
        var s = empty(); s.clips = [a]
        s = StudioProjectEditor.trimClip(s, id: a.id, start: 2, end: 8)
        s = StudioProjectEditor.setClipSpeed(s, id: a.id, speed: 99)        // clamped
        s = StudioProjectEditor.setClipFilter(s, id: a.id, filter: .vivid, intensity: 2)  // clamped
        let c = s.clips[0]
        XCTAssertEqual(c.trimStart, 2); XCTAssertEqual(c.trimEnd, 8)
        XCTAssertEqual(c.speed, 4.0)
        XCTAssertEqual(c.filter, .vivid); XCTAssertEqual(c.filterIntensity, 1)
    }

    // MARK: - split

    func testSplitProducesAdjacentClips() {
        let a = video(0, trimStart: 0, trimEnd: 10)
        var s = empty(); s.clips = [a]
        s = StudioProjectEditor.splitClip(s, id: a.id, atOutputOffset: 4, sourceDuration: 10)
        let seq = StudioGeometry.ordered(s.clips)
        XCTAssertEqual(seq.count, 2)
        XCTAssertEqual(seq[0].trimStart, 0); XCTAssertEqual(seq[0].trimEnd, 4)
        XCTAssertEqual(seq[1].trimStart, 4); XCTAssertEqual(seq[1].trimEnd, 10)
        XCTAssertEqual(seq.map(\.order), [0, 1])
        XCTAssertNotEqual(seq[0].id, seq[1].id)
    }

    func testSplitRespectsSpeed() {
        // 2× speed: an output offset of 2s is 4s of source.
        let a = video(0, trimStart: 0, trimEnd: 10, speed: 2)
        var s = empty(); s.clips = [a]
        s = StudioProjectEditor.splitClip(s, id: a.id, atOutputOffset: 2, sourceDuration: 10)
        XCTAssertEqual(StudioGeometry.ordered(s.clips)[0].trimEnd, 4, accuracy: 1e-9)
    }

    func testDegenerateSplitIsNoOp() {
        let a = video(0, trimStart: 0, trimEnd: 10)
        var s = empty(); s.clips = [a]
        XCTAssertEqual(StudioProjectEditor.splitClip(s, id: a.id, atOutputOffset: 0, sourceDuration: 10).clips.count, 1)
        XCTAssertEqual(StudioProjectEditor.splitClip(s, id: a.id, atOutputOffset: 10, sourceDuration: 10).clips.count, 1)
    }

    func testPhotoIsNotSplit() {
        let p = TimelineClip(sessionMediaID: nil, localIdentifier: "p", isPhoto: true, order: 0, photoDurationSec: 5)
        var s = empty(); s.clips = [p]
        XCTAssertEqual(StudioProjectEditor.splitClip(s, id: p.id, atOutputOffset: 2, sourceDuration: nil).clips.count, 1)
    }

    // MARK: - transitions

    func testSetAndClearTransition() {
        let a = video(0)
        var s = empty(); s.clips = [a]
        s = StudioProjectEditor.setTransition(s, afterClipID: a.id, kind: .dissolve, durationSec: 0.8)
        XCTAssertEqual(s.transitions.count, 1)
        XCTAssertEqual(s.transitions[0].kind, .dissolve)
        s = StudioProjectEditor.setTransition(s, afterClipID: a.id, kind: .none)   // clears
        XCTAssertTrue(s.transitions.isEmpty)
    }

    // MARK: - undo / redo

    func testUndoRedoStack() {
        var u = UndoStack(0)
        XCTAssertFalse(u.canUndo); XCTAssertFalse(u.canRedo)
        u.commit(1); u.commit(2)
        XCTAssertEqual(u.current, 2); XCTAssertTrue(u.canUndo)
        u.undo(); XCTAssertEqual(u.current, 1); XCTAssertTrue(u.canRedo)
        u.undo(); XCTAssertEqual(u.current, 0)
        u.redo(); XCTAssertEqual(u.current, 1)
        u.commit(9)                            // commit after undo clears the redo branch
        XCTAssertEqual(u.current, 9); XCTAssertFalse(u.canRedo)
    }

    func testUndoStackRespectsLimit() {
        var u = UndoStack(0, limit: 2)
        u.commit(1); u.commit(2); u.commit(3)  // only the last 2 priors are retained
        u.undo(); u.undo()
        XCTAssertEqual(u.current, 1)           // can't go back past the trimmed history
        XCTAssertFalse(u.canUndo)
    }
}
