import XCTest
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
