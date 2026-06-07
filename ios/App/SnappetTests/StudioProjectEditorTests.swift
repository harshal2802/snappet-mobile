import XCTest
import CoreGraphics
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

    // MARK: - overlay position (WYSIWYG drag commit)

    func testSetOverlayPositionMovesTheRightOverlayAndClamps() {
        let a = OverlayItem(kind: .text, content: "A")
        let b = OverlayItem(kind: .text, content: "B")
        var s = empty(); s.overlays = [a, b]
        // Move b within bounds.
        s = StudioProjectEditor.setOverlayPosition(s, id: b.id, position: CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(s.overlays.first { $0.id == b.id }?.position, CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(s.overlays.first { $0.id == a.id }?.position, CGPoint(x: 0.5, y: 0.5))  // a untouched
        // Out-of-bounds drag clamps into the unit square.
        s = StudioProjectEditor.setOverlayPosition(s, id: a.id, position: CGPoint(x: 1.8, y: -0.4))
        XCTAssertEqual(s.overlays.first { $0.id == a.id }?.position, CGPoint(x: 1, y: 0))
    }

    func testSetOverlayPositionUnknownIDIsNoOp() {
        let a = OverlayItem(kind: .text, content: "A")
        var s = empty(); s.overlays = [a]
        s = StudioProjectEditor.setOverlayPosition(s, id: UUID(), position: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(s.overlays.first?.position, CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - clip adjust (colour)

    func testSetClipAdjustStoresAndClearsNeutral() {
        let c = video(0)
        var s = empty(); s.clips = [c]
        s = StudioProjectEditor.setClipAdjust(s, id: c.id,
                                              adjust: ClipAdjust(brightness: 0.2, contrast: 1, saturation: 1))
        XCTAssertEqual(s.clips.first?.adjust?.brightness, 0.2)
        // A neutral adjust is stored as nil (compositor skips the Core Image pass).
        s = StudioProjectEditor.setClipAdjust(s, id: c.id, adjust: .neutral)
        XCTAssertNil(s.clips.first?.adjust)
    }

    // MARK: - clip volume + overlay opacity/keyframes (audio + animation)

    func testSetClipVolumeStoresAndFullClearsToNil() {
        let c = video(0)
        var s = empty(); s.clips = [c]
        s = StudioProjectEditor.setClipVolume(s, id: c.id, volume: 0.3)
        XCTAssertEqual(s.clips.first?.volume, 0.3)
        s = StudioProjectEditor.setClipVolume(s, id: c.id, volume: 1.0)   // full = nil (mix-free)
        XCTAssertNil(s.clips.first?.volume)
        s = StudioProjectEditor.setClipVolume(s, id: c.id, volume: -1)    // clamps to 0 (mute)
        XCTAssertEqual(s.clips.first?.volume, 0)
    }

    func testSetOverlayScaleClamps() {
        // Text/sticker/climb-name font scale: ranges past 1 (bigger text), clamped to 0.2…6.
        let ov = OverlayItem(kind: .climbName, content: "5c · 40°")
        var s = empty(); s.overlays = [ov]
        s = StudioProjectEditor.setOverlayScale(s, id: ov.id, scale: 2.5)
        XCTAssertEqual(s.overlays.first?.scale, 2.5)
        s = StudioProjectEditor.setOverlayScale(s, id: ov.id, scale: 99)  // clamps to 6
        XCTAssertEqual(s.overlays.first?.scale, 6)
        s = StudioProjectEditor.setOverlayScale(s, id: ov.id, scale: 0)   // clamps to 0.2
        XCTAssertEqual(s.overlays.first?.scale, 0.2)
    }

    // MARK: - base-video collage frame

    func testSetAndClearBaseFrameClampsAndToggles() {
        var s = empty()
        XCTAssertNil(s.baseFrame)
        s = StudioProjectEditor.setBaseFrame(s, center: CGPoint(x: 0.5, y: 0.3),
                                             size: CGSize(width: 0.8, height: 0.45))
        XCTAssertEqual(s.baseFrame?.center, CGPoint(x: 0.5, y: 0.3))
        XCTAssertEqual(s.baseFrame?.size, CGSize(width: 0.8, height: 0.45))
        // Out-of-range centre clamps to the unit square; size clamps each axis to 0.1…1.
        s = StudioProjectEditor.setBaseFrame(s, center: CGPoint(x: 1.4, y: -0.2),
                                             size: CGSize(width: 0.02, height: 9))
        XCTAssertEqual(s.baseFrame?.center, CGPoint(x: 1, y: 0))
        XCTAssertEqual(s.baseFrame?.size, CGSize(width: 0.1, height: 1))
        // Clearing restores the full-canvas (legacy) behaviour.
        s = StudioProjectEditor.clearBaseFrame(s)
        XCTAssertNil(s.baseFrame)
    }

    func testStudioFrameRectIsFull() {
        XCTAssertTrue(StudioFrameRect(centerX: 0.5, centerY: 0.5, width: 1, height: 1).isFull)
        XCTAssertFalse(StudioFrameRect.half.isFull)   // half-height cell is not "full"
    }

    func testOverlayOpacityKeyframesAddSortedAndReplaceSameTime() {
        let ov = OverlayItem(kind: .text, content: "A", endSec: 5)
        var s = empty(); s.overlays = [ov]
        s = StudioProjectEditor.addOverlayOpacityKeyframe(s, id: ov.id, timeSec: 3, value: 0)
        s = StudioProjectEditor.addOverlayOpacityKeyframe(s, id: ov.id, timeSec: 1, value: 1)
        XCTAssertEqual(s.overlays.first?.opacityKeyframes.map(\.timeSec), [1, 3])   // sorted
        // A keyframe at ~the same time replaces, not duplicates.
        s = StudioProjectEditor.addOverlayOpacityKeyframe(s, id: ov.id, timeSec: 1.01, value: 0.5)
        XCTAssertEqual(s.overlays.first?.opacityKeyframes.count, 2)
        XCTAssertEqual(s.overlays.first?.opacityKeyframes.first?.value, 0.5)
    }

    func testRichTextStyleSettersUpdateTheOverlay() {
        let ov = OverlayItem(kind: .climbName, content: "Pez")
        var s = empty(); s.overlays = [ov]
        // Colour + highlight (set, then clear).
        s = StudioProjectEditor.setOverlayColor(s, id: ov.id, hex: "#FF3B30")
        XCTAssertEqual(s.overlays.first?.colorHex, "#FF3B30")
        s = StudioProjectEditor.setOverlayHighlight(s, id: ov.id, hex: "#0A84FF")
        XCTAssertEqual(s.overlays.first?.highlightHex, "#0A84FF")
        s = StudioProjectEditor.setOverlayHighlight(s, id: ov.id, hex: nil)
        XCTAssertNil(s.overlays.first?.highlightHex)
        // Font preset.
        s = StudioProjectEditor.setOverlayFont(s, id: ov.id, font: .serif)
        XCTAssertEqual(s.overlays.first?.font, .serif)
        // Bold / italic are set independently (nil leaves the other unchanged).
        s = StudioProjectEditor.setOverlayStyle(s, id: ov.id, bold: false)
        XCTAssertEqual(s.overlays.first?.bold, false)
        XCTAssertEqual(s.overlays.first?.italic, false)   // untouched
        s = StudioProjectEditor.setOverlayStyle(s, id: ov.id, italic: true)
        XCTAssertEqual(s.overlays.first?.italic, true)
        XCTAssertEqual(s.overlays.first?.bold, false)      // untouched
    }

    func testOverlayDefaultsAreMigrationSafe() {
        // A freshly-decoded/old overlay defaults: system font, bold, not italic, no highlight.
        let ov = OverlayItem(kind: .text, content: "Hi")
        XCTAssertEqual(ov.font, .system)
        XCTAssertTrue(ov.bold)
        XCTAssertFalse(ov.italic)
        XCTAssertNil(ov.highlightHex)
    }

    func testOverlayDecodesFromPreStyleJSON() throws {
        // An overlay persisted BEFORE the rich-text fields (no highlightHex / fontRaw / boldRaw /
        // italicRaw). Swift's synthesized Decodable throws `keyNotFound` for a missing NON-optional key,
        // so these MUST stay optional — this guards the migration crash (StudioProject.overlays decode).
        let json = """
        {"id":"\(UUID().uuidString)","kindRaw":"climbName","content":"Pez","startSec":0,"endSec":3,\
        "normalizedX":0.5,"normalizedY":0.85,"scale":1,"rotationDegrees":0,"opacity":1,\
        "colorHex":"#FFFFFF","opacityKeyframes":[]}
        """.data(using: .utf8)!
        let ov = try JSONDecoder().decode(OverlayItem.self, from: json)
        XCTAssertEqual(ov.content, "Pez")
        XCTAssertEqual(ov.font, .system)   // defaults applied via the non-optional accessors
        XCTAssertTrue(ov.bold)
        XCTAssertFalse(ov.italic)
        XCTAssertNil(ov.highlightHex)
    }

    func testSetOverlayContentReplacesText() {
        let ov = OverlayItem(kind: .climbName, content: "Old")
        var s = empty(); s.overlays = [ov]
        s = StudioProjectEditor.setOverlayContent(s, id: ov.id, content: "New\nLine")
        XCTAssertEqual(s.overlays.first?.content, "New\nLine")
        // Unknown id is a no-op.
        s = StudioProjectEditor.setOverlayContent(s, id: UUID(), content: "X")
        XCTAssertEqual(s.overlays.first?.content, "New\nLine")
    }

    func testSetOverlayTimeRangeClampsAndKeepsMinLength() {
        let ov = OverlayItem(kind: .text, content: "A", startSec: 0, endSec: 3)
        var s = empty(); s.overlays = [ov]
        s = StudioProjectEditor.setOverlayTimeRange(s, id: ov.id, start: 2, end: 6)
        XCTAssertEqual(s.overlays.first?.startSec, 2); XCTAssertEqual(s.overlays.first?.endSec, 6)
        // Negative start clamps to 0; an inverted/collapsed range keeps a 0.2s minimum length.
        s = StudioProjectEditor.setOverlayTimeRange(s, id: ov.id, start: -1, end: -1)
        XCTAssertEqual(s.overlays.first?.startSec, 0)
        XCTAssertEqual(s.overlays.first?.endSec ?? 0, 0.2, accuracy: 1e-9)
    }

    func testSetOverlayFrameWritesPerAxisSizeAndClamps() {
        let ov = OverlayItem(kind: .video, content: "pip")
        var s = empty(); s.overlays = [ov]
        s = StudioProjectEditor.setOverlayFrame(s, id: ov.id, center: CGPoint(x: 0.25, y: 0.5),
                                                size: CGSize(width: 0.5, height: 1))
        XCTAssertEqual(s.overlays.first?.position, CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(s.overlays.first?.pipSize, CGSize(width: 0.5, height: 1))
        // Out-of-range size clamps each axis to 0.1…1; centre clamps to the unit square.
        s = StudioProjectEditor.setOverlayFrame(s, id: ov.id, center: CGPoint(x: 1.5, y: -0.2),
                                                size: CGSize(width: 0, height: 9))
        XCTAssertEqual(s.overlays.first?.position, CGPoint(x: 1, y: 0))
        XCTAssertEqual(s.overlays.first?.pipSize, CGSize(width: 0.1, height: 1))
    }

    func testApplyPiPGridTilesVideoOverlaysInOrder() {
        let a = OverlayItem(kind: .video, content: "a")
        let txt = OverlayItem(kind: .text, content: "skip")   // non-video is left alone
        let b = OverlayItem(kind: .video, content: "b")
        var s = empty(); s.overlays = [a, txt, b]
        s = StudioProjectEditor.applyPiPGrid(s, preset: .sideBySide)
        XCTAssertEqual(s.overlays.first { $0.id == a.id }?.position, CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(s.overlays.first { $0.id == b.id }?.position, CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(s.overlays.first { $0.id == a.id }?.pipSize, CGSize(width: 0.5, height: 1))
        XCTAssertEqual(s.overlays.first { $0.id == txt.id }?.position, CGPoint(x: 0.5, y: 0.5))  // untouched
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
        XCTAssertEqual(StudioGeometry.ordered(s.clips)[0].trimEnd ?? -1, 4, accuracy: 1e-9)
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
