import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the **pure** `StudioEntry` selection/seeding behind the module-level Video
/// Studio entry (#74) — no SwiftData container, no view (`findOrCreateProject`, the thin
/// ModelContext edge, is exercised by the walkthrough UI test). Plus the fitness-card
/// disambiguation guarantees: distinct display titles, stable persisted ids.
final class StudioEntryTests: XCTestCase {

    // MARK: - Helpers

    private func session(_ name: String, daysAgo: Double) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        return WorkoutSession(routineName: name, startedAt: start,
                              completedAt: start.addingTimeInterval(3600))
    }

    private func video(_ sessionID: UUID, offset: Double, duration: Double = 12) -> SessionMedia {
        SessionMedia(sessionID: sessionID, localIdentifier: "vid-\(sessionID)-\(offset)",
                     kind: .video, offsetSec: offset, durationSec: duration)
    }

    private func photo(_ sessionID: UUID, offset: Double) -> SessionMedia {
        SessionMedia(sessionID: sessionID, localIdentifier: "pic-\(sessionID)-\(offset)",
                     kind: .photo, offsetSec: offset)
    }

    /// A posted highlight reel row (highlights P2/P5): a video whose `reelTitle` marks it.
    private func reel(_ sessionID: UUID, title: String = "Highlights") -> SessionMedia {
        let m = SessionMedia(sessionID: sessionID, localIdentifier: "reel-\(sessionID)-\(title)",
                             kind: .video, offsetSec: 0, durationSec: 28)
        m.reelTitle = title
        return m
    }

    // MARK: - candidates

    func testCandidatesKeepOnlyVideoBearingSessionsNewestFirst() {
        let old = session("Push Day", daysAgo: 9)
        let mid = session("Leg Day", daysAgo: 5)
        let new = session("Pull Day", daysAgo: 1)
        let photoOnly = session("Mobility", daysAgo: 0.5)
        let media = [video(old.id, offset: 10), video(new.id, offset: 4),
                     video(mid.id, offset: 8), video(mid.id, offset: 30),
                     photo(photoOnly.id, offset: 2)]

        let out = StudioEntry.candidates(history: [old, mid, new, photoOnly], media: media)
        XCTAssertEqual(out.map(\.title), ["Pull Day", "Leg Day", "Push Day"],
                       "newest first; the photo-only session must not appear")
        XCTAssertEqual(out.map(\.videoCount), [1, 2, 1])
        XCTAssertEqual(out.first?.sessionID, new.id)
        XCTAssertEqual(out.first?.startedAt, new.startedAt)
    }

    func testCandidatesAreCappedAtLimit() {
        let sessions = (0..<5).map { session("S\($0)", daysAgo: Double($0)) }
        let media = sessions.map { video($0.id, offset: 1) }
        XCTAssertEqual(StudioEntry.candidates(history: sessions, media: media).count, 3,
                       "default limit is 3 — the dashboard card is a summary, not a second History")
        XCTAssertEqual(StudioEntry.candidates(history: sessions, media: media, limit: 5).count, 5)
    }

    func testCandidatesEmptyWithNoMediaOrNoHistory() {
        let s = session("Push Day", daysAgo: 1)
        XCTAssertTrue(StudioEntry.candidates(history: [s], media: []).isEmpty)
        XCTAssertTrue(StudioEntry.candidates(history: [], media: [video(s.id, offset: 1)]).isEmpty,
                      "media pointing at no listed session yields nothing")
    }

    // MARK: - videoCounts / videoSessionIDs

    func testVideoCountsIgnorePhotos() {
        let a = UUID(), b = UUID()
        let media = [video(a, offset: 1), video(a, offset: 2), photo(a, offset: 3),
                     photo(b, offset: 1)]
        XCTAssertEqual(StudioEntry.videoCounts(media: media), [a: 2])
        XCTAssertEqual(StudioEntry.videoSessionIDs(media: media), [a],
                       "a photo-only session has nothing for the studio's main track")
    }

    // MARK: - seedClips

    func testSeedClipsAreSessionScopedVideosInCaptureOrder() {
        let mine = UUID(), other = UUID()
        let media = [video(mine, offset: 30, duration: 5), video(other, offset: 1),
                     video(mine, offset: 10, duration: 8), photo(mine, offset: 0)]

        let clips = StudioEntry.seedClips(for: mine, media: media)
        XCTAssertEqual(clips.count, 2, "other sessions' clips and photos are excluded")
        XCTAssertEqual(clips.map(\.order), [0, 1], "order indexes the capture sequence")
        XCTAssertEqual(clips.map(\.trimEnd), [8, 5], "earlier capture first; trimEnd = duration")
        XCTAssertEqual(clips[0].sessionMediaID, media[2].id)
        XCTAssertFalse(clips.contains { $0.isPhoto })
    }

    // MARK: - Posted reels are OUTPUT, not footage (highlights P5)

    func testSeedClipsExcludePostedReels() {
        let sid = UUID()
        let footage = video(sid, offset: 10, duration: 8)
        let media = [reel(sid), footage]

        let clips = StudioEntry.seedClips(for: sid, media: media)
        XCTAssertEqual(clips.map(\.sessionMediaID), [footage.id],
                       "a posted reel must never seed the Studio timeline — editing a render is odd, "
                       + "and its burned scorebug would double-draw under the live overlay")
    }

    func testVideoCountsAndCandidatesIgnoreReels() {
        let s = session("Push Day", daysAgo: 1)
        let reelOnly = session("Watch Import", daysAgo: 0.5)
        let media = [video(s.id, offset: 5), reel(s.id), reel(reelOnly.id)]

        XCTAssertEqual(StudioEntry.videoCounts(media: media), [s.id: 1],
                       "counting a reel would light up a Studio entry whose seed is empty")
        XCTAssertEqual(StudioEntry.videoSessionIDs(media: media), [s.id])
        let out = StudioEntry.candidates(history: [s, reelOnly], media: media)
        XCTAssertEqual(out.map(\.sessionID), [s.id],
                       "a reel-only session offers no Studio candidate")
        XCTAssertEqual(out.first?.videoCount, 1)
    }

    // MARK: - Late-clip reconcile: a deleted clip stays deleted (prompt 296)

    private func reconciled(_ clips: [TimelineClip], removed: [UUID]? = nil,
                            _ footage: [SessionMedia], scope: Set<UUID>? = nil) -> StudioEntry.Reconciled? {
        StudioEntry.reconciled(clips: clips, removedMediaIDs: removed, footage: footage, scope: scope)
    }

    /// Media that was never on the timeline (filmed after the project was made) is still added,
    /// after the existing clips, in capture order.
    func testReconcileAddsMediaThatWasNeverOnTheTimeline() {
        let sid = UUID()
        let a = video(sid, offset: 10), late2 = video(sid, offset: 90), late1 = video(sid, offset: 40)
        let clips = StudioEntry.seedClips(for: sid, media: [a])
        let out = reconciled(clips, [a, late2, late1])
        XCTAssertEqual(out?.clips.map(\.sessionMediaID), [a.id, late1.id, late2.id])
        XCTAssertEqual(out?.clips.map(\.order), [0, 1, 2])
        XCTAssertEqual(out?.clips.last?.localIdentifier, late2.localIdentifier)
        XCTAssertNil(out?.removedMediaIDs)
        XCTAssertNil(reconciled(out?.clips ?? [], [a, late2, late1]), "a second open changes nothing")
    }

    /// The finding: a clip the user deleted is not "new footage" on the next open.
    func testReconcileDoesNotAddBackADeletedClip() {
        let sid = UUID()
        let a = video(sid, offset: 10), b = video(sid, offset: 40)
        let clips = StudioEntry.seedClips(for: sid, media: [a])          // b was deleted
        XCTAssertNil(reconciled(clips, removed: [b.id], [a, b]),
                     "the whole-project studio leaves the deleted clip out")
        // …while media filmed later is still added next to it.
        let late = video(sid, offset: 70)
        let out = reconciled(clips, removed: [b.id], [a, b, late])
        XCTAssertEqual(out?.clips.map(\.sessionMediaID), [a.id, late.id])
        XCTAssertEqual(out?.removedMediaIDs, [b.id])
    }

    /// A scope that still shows a clip brings nothing back (the feed's "Edit all clips" of a post).
    func testReconcileKeepsADeletionInAScopeThatStillShowsAClip() {
        let sid = UUID()
        let a = video(sid, offset: 10), b = video(sid, offset: 40)
        let clips = StudioEntry.seedClips(for: sid, media: [a])
        XCTAssertNil(reconciled(clips, removed: [b.id], [a, b], scope: [a.id, b.id]))
    }

    /// "Edit this clip" on a deleted clip: the scope would be empty, so the clip comes back and
    /// the deletion is forgotten. A deleted clip outside the scope stays deleted.
    func testReconcileBringsBackADeletedClipWhenItsScopeWouldBeEmpty() {
        let sid = UUID()
        let a = video(sid, offset: 10), b = video(sid, offset: 40), c = video(sid, offset: 70)
        let clips = StudioEntry.seedClips(for: sid, media: [a])          // b and c were deleted
        let out = reconciled(clips, removed: [b.id, c.id], [a, b, c], scope: [b.id])
        XCTAssertEqual(out?.clips.map(\.sessionMediaID), [a.id, b.id])
        XCTAssertEqual(out?.removedMediaIDs, [c.id], "only the opened clip is forgotten")
        XCTAssertEqual(out?.clips.last?.trimEnd, b.durationSec, "it comes back as a fresh clip")
    }

    /// The Studio has no "add clip", so a project with every clip deleted would be a dead end.
    /// The whole-project studio starts over instead.
    func testReconcileStartsOverWhenEveryClipWasDeleted() {
        let sid = UUID()
        let a = video(sid, offset: 40), b = video(sid, offset: 10)
        let out = reconciled([], removed: [a.id, b.id], [a, b])
        XCTAssertEqual(out?.clips.map(\.sessionMediaID), [b.id, a.id])
        XCTAssertNil(out?.removedMediaIDs)
    }

    /// A stale record can never hide a clip that is on the timeline: the timeline wins and the
    /// record is dropped.
    func testReconcileDropsARecordForMediaThatIsOnTheTimeline() {
        let sid = UUID()
        let a = video(sid, offset: 10)
        let clips = StudioEntry.seedClips(for: sid, media: [a])
        let out = reconciled(clips, removed: [a.id], [a])
        XCTAssertEqual(out?.clips, clips)
        XCTAssertNil(out?.removedMediaIDs)
    }

    func testFootageIsSessionVideosWithoutReels() {
        let sid = UUID(), other = UUID()
        let a = video(sid, offset: 1)
        let media = [a, photo(sid, offset: 2), reel(sid), video(other, offset: 3)]
        XCTAssertEqual(StudioEntry.footage(for: sid, media: media).map(\.id), [a.id])
        XCTAssertEqual(StudioEntry.footage(for: nil, media: media).count, 2,
                       "nil = media is already session-scoped (Kilter)")
    }

    /// The whole path on a stored project: delete in the editor → reopen (whole project) keeps
    /// it deleted → "Edit this clip" brings it back; and undoing the delete forgets the deletion.
    @MainActor
    func testDeletedClipStaysDeletedAcrossReopenAndUndoForgetsIt() throws {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let sid = UUID()
        let a = video(sid, offset: 10), b = video(sid, offset: 40)
        let project = StudioEntry.resolveProject(forSessionID: sid, title: "S", media: [a, b], context: context)
        let clipB = try XCTUnwrap(project.clips.first { $0.sessionMediaID == b.id })

        let vm = StudioEditorViewModel(project: project, context: context)
        vm.select(clipB.id)
        vm.deleteSelected()
        XCTAssertEqual(project.removedMediaIDs, [b.id])

        let reopened = StudioEntry.resolveProject(forSessionID: sid, title: "S", media: [a, b], context: context)
        XCTAssertEqual(reopened.clips.map(\.sessionMediaID), [a.id], "it does not come back")
        let editAll = StudioEntry.resolveProject(forSessionID: sid, title: "S", media: [a, b],
                                                 scope: [a.id, b.id], context: context)
        XCTAssertEqual(editAll.clips.map(\.sessionMediaID), [a.id])

        vm.undoEdit()
        XCTAssertNil(project.removedMediaIDs, "undoing the delete forgets the deletion")
        XCTAssertEqual(project.clips.count, 2)
        vm.redoEdit()
        XCTAssertEqual(project.removedMediaIDs, [b.id])

        let scoped = StudioEntry.resolveProject(forSessionID: sid, title: "S", media: [a, b],
                                                scope: [b.id], context: context)
        XCTAssertEqual(scoped.clips.map(\.sessionMediaID), [a.id, b.id], "opening the clip brings it back")
        XCTAssertNil(scoped.removedMediaIDs)
    }

    // MARK: - Fitness-card disambiguation (#74)

    @MainActor
    func testFitnessModuleTitlesAreDistinctAndIdsStable() {
        // Display titles may be renamed; persisted ids must NOT — they key UsageRecords + routes.
        // ("workout", the retired Workout Reels tile, is gone from the registry entirely —
        // highlights P3; old UsageRecords with that id render via the capitalized-raw fallback.)
        XCTAssertEqual(WorkoutTrackerModule.id, "workout-log")
        XCTAssertEqual(WorkoutTrackerModule.module.id, "workout-log")
        XCTAssertNil(ModuleRegistry.all.first { $0.id == "workout" },
                     "the Workout Reels tile is retired — reels are session actions + the weekly cut")
        XCTAssertTrue(WorkoutTrackerModule.module.subtitle.localizedCaseInsensitiveContains("studio"),
                      "the tracker's card must advertise the video studio (#74)")
    }
}
