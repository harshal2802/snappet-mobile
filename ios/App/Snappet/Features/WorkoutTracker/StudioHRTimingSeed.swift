#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import AVFoundation

/// Test-only seed for the heart-rate timing check in the running Studio (prompt 306).
///
/// `-uiTestSeedStudioHRTiming` (implies the fresh in-memory store, like its siblings) seeds one
/// completed `WorkoutSession` whose heart rate is a straight ramp, `bpm = 60 + seconds / 2`, so a
/// reading names the second it was taken at: a clip read 20 s too early shows 10 bpm too little.
/// It has three video clips, all playing the same generated 10 s video:
///
/// | Clip | Row | Capture time of rendition time `t` |
/// |---|---|---|
/// | A | never baked, offset 60 s | 60 + t |
/// | B | "Save to original" with the first 20 s of a 30 s recording trimmed off, offset 200 s | 200 + 20 + t |
/// | C | "Save to original" at 2× of a 20 s recording, offset 120 s | 120 + 2t |
///
/// The baked rows are written the way `StudioEditorViewModel.bake` writes them: the map comes
/// from `ClipBakePlan.timeMap` for the part the bake would have rendered, and the row values from
/// `ClipBakePlan.revertibleMediaUpdate`. Nothing is hand-written JSON.
///
/// The clips' `localIdentifier`s use the `uitest-generated://` scheme. `StudioComposer` resolves
/// that scheme to the generated video (`asset(forLocalIdentifier:)`), so the Studio has a real
/// preview and a real export on the simulator. No Photos identifier has that form, and the whole
/// file is DEBUG only.
enum StudioHRTimingSeed {
    static let argument = "-uiTestSeedStudioHRTiming"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static let routineID = UUID(uuidString: "5712D0DE-306A-0DEC-A57E-1234DEA00306")!
    static let routineName = "HR Timing Check"

    /// Long enough for clip B's window with its 30 s tail (ends at 260 s).
    static let sessionSeconds: Double = 300
    /// The length of the video every clip plays.
    static let videoSeconds: Double = 10

    /// The session's heart rate at `seconds` from its start.
    static func rampBPM(at seconds: Double) -> Double { 60 + seconds / 2 }

    enum Clip: String, CaseIterable, Sendable {
        case a, b, c

        var localIdentifier: String { StudioHRTimingSeed.scheme + rawValue }

        /// When the first frame of the RECORDING was filmed, in seconds from the session's start.
        var offsetSec: Double {
            switch self {
            case .a: return 60
            case .b: return 200
            case .c: return 120
            }
        }

        /// The recording's length before the bake.
        var recordedSeconds: Double {
            switch self {
            case .a: return StudioHRTimingSeed.videoSeconds
            case .b: return 30
            case .c: return 20
            }
        }

        /// The edit the bake rendered, as the clip the Studio had on its timeline. `nil` = never baked.
        func bakedPart(mediaID: UUID) -> TimelineClip? {
            switch self {
            case .a:
                return nil
            case .b:
                return TimelineClip(sessionMediaID: mediaID, localIdentifier: localIdentifier, isPhoto: false,
                                    order: 0, trimStart: 20, trimEnd: recordedSeconds)
            case .c:
                return TimelineClip(sessionMediaID: mediaID, localIdentifier: localIdentifier, isPhoto: false,
                                    order: 0, trimEnd: recordedSeconds, speed: 2)
            }
        }
    }

    // MARK: Seed

    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        // Never into the real store (prompt 320).
        guard isActive, UITestStore.isFreshStore(ProcessInfo.processInfo.arguments) else { return }
        let rid = routineID
        let existing = try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.routineID == rid }))
        guard existing?.isEmpty ?? true else { return }

        let startedAt = Date(timeIntervalSinceNow: -(sessionSeconds + 5 * 60))
        let exercises = [SessionExercise(
            exerciseId: "Bodyweight_Squat", targetSets: 1, targetReps: "12",
            targetRestSeconds: 60, targetWeightUnit: .kg,
            sets: [SetLog(actualReps: 12, actualWeight: nil, weightUnit: .kg,
                          completedAt: startedAt.addingTimeInterval(30))])]
        let session = WorkoutSession(
            routineID: rid, routineName: routineName, startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(sessionSeconds), exercises: exercises,
            hrSeries: rampSeries())
        context.insert(session)
        for row in mediaRows(sessionID: session.id) { context.insert(row) }
        try? context.save()
    }

    /// One sample a second over the whole session.
    static func rampSeries() -> [HRPoint] {
        stride(from: 0.0, through: sessionSeconds, by: 1).map { HRPoint(t: $0, bpm: rampBPM(at: $0)) }
    }

    /// The three rows. A baked row starts as the row of its recording and then gets what a
    /// "Save to original" writes, from the same pure functions the bake calls.
    static func mediaRows(sessionID: UUID) -> [SessionMedia] {
        Clip.allCases.map { clip in
            let row = SessionMedia(sessionID: sessionID, localIdentifier: clip.localIdentifier, kind: .video,
                                   offsetSec: clip.offsetSec, durationSec: clip.recordedSeconds,
                                   addedManually: false)
            guard let part = clip.bakedPart(mediaID: row.id) else { return row }
            let map = ClipBakePlan.timeMap(parts: [part], sourceDurations: [part.id: clip.recordedSeconds],
                                           transitions: [], existing: row.bakeTimeMap)
            let update = ClipBakePlan.revertibleMediaUpdate(
                oldOffsetSec: row.offsetSec, oldDurationSec: row.durationSec,
                renderedDurationSec: videoSeconds, timeMap: map, existing: row.bakeTimeMap)
            row.offsetSec = update.offsetSec
            row.durationSec = update.durationSec
            row.bakeTimeMap = update.timeMap
            row.isBaked = true
            return row
        }
    }

    // MARK: The generated video

    static let scheme = "uitest-generated://studio-hr-timing/"

    /// The video behind a seeded identifier, or `nil` for any other identifier (every real one).
    /// It is the 1 s golden fixture (`StudioGoldenSource.portraitA`, drawn in code) played ten
    /// times: one file, made on first use, off the main thread.
    static func asset(forLocalIdentifier id: String) async -> AVAsset? {
        guard id.hasPrefix(scheme), let url = await file.url() else { return nil }
        let unit = StudioGoldenSource.portraitA.seconds
        return try? await StudioGoldenRenderer.looped(url, seconds: unit,
                                                      times: Int((videoSeconds / unit).rounded()))
    }

    private static let file = GeneratedFile()

    private actor GeneratedFile {
        private var task: Task<URL?, Never>?

        func url() async -> URL? {
            if let task { return await task.value }
            let made = Task.detached(priority: .userInitiated) { () -> URL? in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("studio-hr-timing", isDirectory: true)
                guard let fixture = try? StudioGoldenRenderer.makeFixture([.portraitA], in: directory)
                else { return nil }
                return fixture.url(.portraitA)
            }
            task = made
            return await made.value
        }
    }
}

// MARK: - What the test reads

/// What the running Studio did, kept for the UI test of prompt 306 to read. Written from the
/// composer (off the main actor) and the baked-clip check; read by `StudioHRTimingDebugView`.
/// Nothing is recorded unless the app was launched with the seed argument.
final class StudioHRTimingDebug: @unchecked Sendable {
    static let shared = StudioHRTimingDebug()

    struct PlacedHR: Codable, Equatable, Sendable {
        var startSec: Double
        var durationSec: Double
        var visibleStartSec: Double?
        var visibleEndSec: Double?
        /// `[t, bpm]`, `t` in seconds from the start of the clip's heart-rate window.
        var samples: [[Double]]
        var hasTile: Bool
    }

    struct Probe: Codable, Equatable, Sendable {
        var localIdentifier: String
        /// `nil` = Photos does not know the asset.
        var hasEditedRendition: Bool?
        var currentDuration: Double?
    }

    struct Check: Codable, Equatable, Sendable {
        var rows: Int
        /// False when Photos gave no answer within the wait.
        var answered: Bool
        /// Rows Photos reported as having no edited video.
        var reverted: Int
        var seconds: Double
    }

    struct Report: Codable, Equatable, Sendable {
        var exports: Int = 0
        var lastExport: [PlacedHR] = []
        var probes: [Probe] = []
        var checks: [Check] = []
    }

    private let lock = NSLock()
    private var report = Report()

    var current: Report { lock.withLock { report } }

    /// The heart-rate tiles an export was given (`StudioComposer.placedHR`).
    func exportPlaced(_ placed: [PlacedClipHR]) {
        guard StudioHRTimingSeed.isActive else { return }
        let records = placed.map { p in
            PlacedHR(startSec: p.startSec, durationSec: p.durationSec,
                     visibleStartSec: p.visibleStartSec, visibleEndSec: p.visibleEndSec,
                     samples: p.samples.map { [Self.rounded($0.t), Self.rounded($0.bpm)] },
                     hasTile: p.tile != nil)
        }
        lock.withLock {
            report.exports += 1
            report.lastExport = records
        }
    }

    /// One answer of the app's own Photos probe.
    func probed(_ localIdentifier: String, _ said: BakedAssetProbe) {
        guard StudioHRTimingSeed.isActive else { return }
        let record = Probe(localIdentifier: localIdentifier, hasEditedRendition: said.hasEditedRendition,
                           currentDuration: said.currentDuration)
        lock.withLock {
            report.probes.removeAll { $0.localIdentifier == localIdentifier }
            report.probes.append(record)
        }
    }

    /// One finished question to Photos.
    func checked(rows: Int, answered: Bool, reverted: Int, seconds: Double) {
        guard StudioHRTimingSeed.isActive else { return }
        let record = Check(rows: rows, answered: answered, reverted: reverted, seconds: Self.rounded(seconds))
        lock.withLock { report.checks.append(record) }
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// Invisible accessibility elements over the Studio, only on a launch with the seed argument:
/// the exact playhead time, the bpm the preview tile shows at it (the tile's own values and
/// fraction, before rounding), the editor's phase, the export's state, and `StudioHRTimingDebug`.
struct StudioHRTimingDebugView: View {
    let vm: StudioEditorViewModel

    var body: some View {
        if StudioHRTimingSeed.isActive {
            let tile = vm.previewTile
            let bpm = vm.canvasHRTile == nil ? nil : tile.values.bpm(atFraction: tile.fraction)
            VStack(spacing: 0) {
                element("studioDebug.playhead", String(format: "%.3f", vm.currentTime))
                element("studioDebug.total", String(format: "%.3f", vm.totalDuration))
                element("studioDebug.previewBPM", bpm.map { String(format: "%.2f", $0) } ?? "none")
                element("studioDebug.phase", Self.phase(vm.state.phase))
                element("studioDebug.export", Self.export(vm.exportState))
                element("studioDebug.report", Self.json(StudioHRTimingDebug.shared.current))
            }
            .allowsHitTesting(false)
        }
    }

    private func element(_ id: String, _ text: String) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(id)
            .accessibilityLabel(text)
    }

    static func phase(_ phase: StudioEditorState.Phase) -> String {
        switch phase {
        case .loading: return "loading"
        case .ready: return "ready"
        case .checking: return "checking"
        case .rendering: return "rendering"
        case .finished: return "finished"
        case .clipMissing: return "clipMissing"
        }
    }

    static func export(_ state: ExportShareState) -> String {
        switch state {
        case .idle: return "idle"
        case .exporting: return "exporting"
        case .exported: return "exported"
        case .saving: return "saving"
        case .saved: return "saved"
        case .failed(let message): return "failed: \(message)"
        }
    }

    static func json(_ report: StudioHRTimingDebug.Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
#endif
