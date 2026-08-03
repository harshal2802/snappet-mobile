import Foundation
import SwiftData

/// Test-only seed for the **Recap feed clip-export E2E** (PR R11): a single completed climbing
/// session carrying a synthetic HR series, one logged send, and one **bundled** video clip — so the
/// Recap feed's a1 session card shows clips and the Share sheet's "Animate" path can run the REAL
/// `ReelExporter.export` (AVFoundation composition + export) **hermetically on the simulator**, with
/// no Photos library and no device.
///
/// The clip's `localIdentifier` is a sentinel `uitest-bundled://recap-uitest-clip.mov` rather than a
/// real PHAsset id; `ReelExporter.avAsset(forLocalIdentifier:)` resolves that scheme to the clip
/// bundled in `Resources/TestAssets`. That fallback is unreachable for any real asset (no production
/// `localIdentifier` ever uses the scheme), so this has **zero production impact**.
///
/// **Strictly test-arg-guarded**: it only runs when launched with `-uiTestSeedRecapClip` (a sibling
/// to `-uiTestFreshStore`, which it implies — `SnappetApp` always builds a fresh in-memory store for
/// it). A normal/production launch never reaches this code. Idempotent: it no-ops if a `KilterSession`
/// with `sessionID` already exists.
enum RecapClipSeed {
    /// The launch argument that enables the seed.
    static let argument = "-uiTestSeedRecapClip"

    /// Whether this process was launched into the seeded hermetic E2E.
    ///
    /// Read by `ClipExportCoordinator.animate` to skip the **Photos save** — the one step of the
    /// Animate pipeline that is not hermetic. `PHPhotoLibrary.requestAuthorization` puts up a system
    /// dialog on a fresh simulator, and an `XCUITest` interruption monitor only fires on the *next*
    /// interaction with the app; the test is parked in `waitForExistence` by the time the render
    /// finishes, so nothing ever dismisses it and the await hangs until the test times out. Skipping
    /// the save keeps this type's stated promise ("hermetically on the simulator, with no Photos
    /// library") and still exercises the whole render — the composition and export are what the E2E
    /// is proving.
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// The sentinel `localIdentifier` scheme for the bundled test clip (resolved by ReelExporter).
    static let bundledScheme = "uitest-bundled://"

    /// The bundled clip resource name (a `.mov` in `Resources/TestAssets`), without extension.
    static let bundledClipResource = "recap-uitest-clip"

    /// A fixed session id so the seed is idempotent and the test can recognise *the* seeded session.
    static let sessionID = UUID(uuidString: "5712D0DE-FEED-0DEC-A57E-1234DEA0C11D")!

    /// The fixed climb id the logged send + the bundled clip are tied to.
    static let climbUUID = "uitest-recap-climb-1"

    /// Seed the recap clip session if the launch arg is present and it isn't already there. Called from
    /// `SnappetApp.init()` against the fresh in-memory container, before any UI appears.
    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let sid = sessionID
        let existing = try? context.fetch(
            FetchDescriptor<KilterSession>(predicate: #Predicate { $0.id == sid }))
        guard (existing?.isEmpty ?? true) else { return }

        // A 30-minute session that just ended, with a rising synthetic HR curve so the card/detail
        // HR section + the burned scorebug overlay render on the simulator (no live HR source there).
        let duration: TimeInterval = 30 * 60
        let startedAt = Date(timeIntervalSinceNow: -duration)
        let endedAt = Date()

        let session = KilterSession(
            id: sid, startedAt: startedAt, endedAt: endedAt, angle: 40, source: "manual",
            hrSeries: syntheticHRSeries(durationSec: duration, sampleEverySec: 5),
            maxHR: 190, restHR: 55, metricsSourceRaw: "appleWatch",
            title: "Recap Clip Demo")
        context.insert(session)

        // One logged send inside the session (gives the card its hardest-send grade + eligibility:
        // climbSessionCards requires ≥1 logged climb with this sessionId).
        let send = KilterLogEntry(
            climbUUID: climbUUID, climbName: "Recap Test Climb", angle: 40,
            difficulty: 16, gradeLabel: "V5", status: .sent, attempts: 2,
            date: startedAt.addingTimeInterval(120), sessionId: sid,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120))
        context.insert(send)

        // One bundled video clip — `localIdentifier` is the sentinel scheme so ReelExporter resolves
        // it from the app bundle (no Photos). 3s clip captured ~1 min into the session.
        let media = SessionMedia(
            sessionID: sid,
            localIdentifier: bundledScheme + bundledClipResource + ".mov",
            kind: .video, offsetSec: 60, durationSec: 3,
            assignedClimbUUID: climbUUID)
        context.insert(media)

        try? context.save()
    }

    // MARK: - Synthetic HR

    /// A deterministic HR curve rising ~90 → 150 bpm over the session, `t` seconds from `startedAt`
    /// (engine convention — same timeline + `HRPoint` composite the rest of the suite uses). No
    /// randomness, so the chart/overlay render identically on every run.
    static func syntheticHRSeries(durationSec: TimeInterval, sampleEverySec: Double) -> [HRPoint] {
        guard durationSec > 0, sampleEverySec > 0 else { return [] }
        var points: [HRPoint] = []
        var t: Double = 0
        while t <= durationSec {
            let f = t / durationSec                 // 0…1 across the session
            points.append(HRPoint(t: t, bpm: (90 + f * 60).rounded()))   // 90 → 150
            t += sampleEverySec
        }
        return points
    }
}
