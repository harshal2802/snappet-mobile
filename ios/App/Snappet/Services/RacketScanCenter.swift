import Foundation
import Observation
import UIKit

/// **The rally scan queue** (prompt 248, issue #438 step 5). One scan at a time, across every session. Progress and the
/// time left are live here; each scan's state, progress and results are written to its `RacketScanRecord` on the
/// recording log, so Your videos and Analyzing read the same thing after a relaunch.
///
/// - Closing Analyzing doesn't stop a scan ("Do it later"). Stop pauses it; Resume picks up where it stopped (the motion
///   chunks already read are cached by `RacketMotionReader`).
/// - Leaving the app: a background task gives the scan iOS's few extra seconds; when they run out the scan pauses and
///   resumes when Snappet is active again. Long scans in the background (BGProcessingTask) are not in this step.
/// - Heat: `RacketMotionReader` slows down at `serious` and pauses at `critical`; the scan resumes when the phone has
///   cooled to `fair`.
/// - "Scan all on charger": those scans wait until the phone is charging.
/// The decisions (what the guesses are, how they merge with your tags) are pure: `RacketModelHooks.swift`.
@MainActor
@Observable
final class RacketScanCenter {
    static let shared = RacketScanCenter()

    /// Why a scan is held in the queue without running.
    enum Hold: Equatable { case none, background, heat }

    struct Job {
        let recordID: UUID
        let exerciseID: UUID
        let store: RacketVideoStore
        var hold: Hold = .none
    }

    /// The scan running now (its record id).
    private(set) var runningID: UUID?
    /// Live fraction per record while scanning.
    private(set) var live: [UUID: Double] = [:]
    /// Seconds left for the running scan.
    private(set) var eta: Double?
    /// Record ids waiting their turn, in order.
    var queuedIDs: [UUID] { jobs.map(\.recordID).filter { $0 != runningID } }

    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopReason: String?
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var rate: [(wall: Date, done: Double)] = []
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// UI tests: the synthetic signal instead of Photos video (`-uiTestStubRallySignal`).
    static var useSyntheticSignal: Bool { ProcessInfo.processInfo.arguments.contains(RacketSyntheticMotionSource.argument) }

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RacketScanCenter.shared.release(.background) }
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = ProcessInfo.processInfo.thermalState
                if s == .nominal || s == .fair { RacketScanCenter.shared.release(.heat) }
            }
        })
        observers.append(nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RacketScanCenter.shared.kick() }
        })
    }

    // MARK: Queue

    /// Find rallies (or Re-scan) on these parts with `model`. A part already scanning is left alone; a paused scan of
    /// the same part and model resumes. Returns the record ids.
    @discardableResult
    func enqueue(_ refs: [RacketPartRef], model: RallyModelInfo, compare: Bool = false, waitForCharger: Bool = false,
                 store: RacketVideoStore, now: Date = .now) -> [UUID] {
        var ids: [UUID] = []
        for ref in refs {
            guard let log = store.ex(ref.exerciseID)?.racketRecordingLog else { continue }
            let existing = log.scans(partStart: ref.startSec, partEnd: ref.endSec)
            if let active = existing.last(where: \.isActive), jobs.contains(where: { $0.recordID == active.id }) {
                ids.append(active.id)
                continue
            }
            if let paused = existing.last(where: { ($0.status == .paused || $0.isActive) && $0.modelID == model.id
                                                     && $0.modelVersion == model.version }) {
                store.updateLog(ref.exerciseID) { l in
                    l.updateScan(paused.id) { $0.statusRaw = RacketScanRecord.Status.queued.rawValue; $0.note = nil
                        $0.waitForCharger = waitForCharger ? true : nil }
                }
                add(Job(recordID: paused.id, exerciseID: ref.exerciseID, store: store))
                ids.append(paused.id)
                continue
            }
            let hasApplied = log.appliedScan(partStart: ref.startSec, partEnd: ref.endSec) != nil
            let rec = RacketScanRecord(modelID: model.id, modelVersion: model.version, modelName: model.name,
                                       partStart: ref.startSec, partEnd: ref.endSec, startedAt: now,
                                       statusRaw: RacketScanRecord.Status.queued.rawValue,
                                       compare: compare && hasApplied ? true : nil,
                                       waitForCharger: waitForCharger ? true : nil)
            store.updateLog(ref.exerciseID) { $0.scans = ($0.scans ?? []) + [rec] }
            add(Job(recordID: rec.id, exerciseID: ref.exerciseID, store: store))
            ids.append(rec.id)
        }
        kick()
        return ids
    }

    /// Resume a paused scan.
    func resume(_ recordID: UUID, exerciseID: UUID, store: RacketVideoStore) {
        guard !jobs.contains(where: { $0.recordID == recordID }) else { kick(); return }
        store.updateLog(exerciseID) { l in
            l.updateScan(recordID) { $0.statusRaw = RacketScanRecord.Status.queued.rawValue; $0.note = nil }
        }
        add(Job(recordID: recordID, exerciseID: exerciseID, store: store))
        kick()
    }

    /// Stop: the running scan pauses where it is; a waiting one leaves the queue (paused).
    func stop(_ recordID: UUID) {
        if runningID == recordID {
            stopReason = "Stopped by you"
            task?.cancel()
            return
        }
        guard let i = jobs.firstIndex(where: { $0.recordID == recordID }) else { return }
        let job = jobs.remove(at: i)
        write(job) { $0.statusRaw = RacketScanRecord.Status.paused.rawValue; $0.note = "Stopped by you" }
    }

    func stopAll(in session: WorkoutSession) {
        let ids = Set(session.exercises.flatMap { $0.racketRecordingLog?.allScans.map(\.id) ?? [] })
        for id in jobs.map(\.recordID) where ids.contains(id) && id != runningID { stop(id) }
        if let r = runningID, ids.contains(r) { stop(r) }
    }

    func isQueued(_ recordID: UUID) -> Bool { jobs.contains { $0.recordID == recordID } }

    /// After a relaunch, records left "running" / "queued" with no job here are paused (they resume on Resume).
    func settle(_ store: RacketVideoStore) {
        for ex in store.session.exercises {
            guard let log = ex.racketRecordingLog else { continue }
            for r in log.allScans where r.isActive && !isQueued(r.id) {
                store.updateLog(ex.id) { l in
                    l.updateScan(r.id) { $0.statusRaw = RacketScanRecord.Status.paused.rawValue
                        $0.note = "Stopped when Snappet closed" }
                }
            }
        }
    }

    private func add(_ job: Job) {
        guard !jobs.contains(where: { $0.recordID == job.recordID }) else { return }
        jobs.append(job)
    }

    private func release(_ hold: Hold) {
        var any = false
        for i in jobs.indices where jobs[i].hold == hold {
            jobs[i].hold = .none
            write(jobs[i]) { $0.statusRaw = RacketScanRecord.Status.queued.rawValue; $0.note = nil }
            any = true
        }
        if any { kick() }
    }

    private var charging: Bool {
        let s = UIDevice.current.batteryState
        return s == .charging || s == .full
    }

    fileprivate func kick() {
        guard runningID == nil else { return }
        if jobs.contains(where: { record($0)?.waitForCharger == true }) { UIDevice.current.isBatteryMonitoringEnabled = true }
        guard let job = jobs.first(where: { j in
            j.hold == .none && (record(j)?.waitForCharger != true || charging)
        }) else { return }
        run(job)
    }

    // MARK: Running

    private func record(_ job: Job) -> RacketScanRecord? {
        job.store.ex(job.exerciseID)?.racketRecordingLog?.allScans.first { $0.id == job.recordID }
    }

    private func write(_ job: Job, _ body: (inout RacketScanRecord) -> Void) {
        job.store.updateLog(job.exerciseID) { $0.updateScan(job.recordID, body) }
    }

    private func run(_ job: Job) {
        guard let rec = record(job), let log = job.store.ex(job.exerciseID)?.racketRecordingLog,
              let sport = job.store.ex(job.exerciseID)?.racketSport,
              let info = RacketCapabilityRegistry.model(id: rec.modelID, version: rec.modelVersion),
              let model = RacketRallyModels.model(for: info) else {
            jobs.removeAll { $0.recordID == job.recordID }
            write(job) { $0.statusRaw = RacketScanRecord.Status.failed.rawValue; $0.note = "This model isn’t on the phone any more" }
            kick()
            return
        }
        runningID = job.recordID
        live[job.recordID] = rec.fraction
        eta = nil
        rate = []
        lastSaved = rec.doneSec
        stopReason = nil
        write(job) { $0.statusRaw = RacketScanRecord.Status.running.rawValue; $0.note = nil }
        beginBackground()

        let request = RallyScanRequest(sport: sport, startSec: rec.partStart, endSec: rec.partEnd,
                                       anchors: RacketScanAnchors.anchors(log, from: rec.partStart, to: rec.partEnd))
        let source: RallyFrameSource = Self.useSyntheticSignal ? RacketSyntheticMotionSource()
            : RacketMotionReader(segments: RacketVideoMap.segments(start: rec.partStart, end: rec.partEnd, log: log),
                                 cacheKey: "rec\(Int(log.startedAt.timeIntervalSince1970))")
        let id = job.recordID
        // Off the main actor: decoding blocks its thread.
        let work = Task.detached(priority: .utility) { () -> Result<[RallyGuess], Error> in
            do {
                let g = try await model.scan(request, source: source) { p in
                    await RacketScanCenter.shared.report(id, p)
                }
                return .success(g)
            } catch {
                return .failure(error)
            }
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            self?.finish(job, result)
        }
    }

    fileprivate func report(_ id: UUID, _ p: RallyScanProgress) {
        guard runningID == id, let job = jobs.first(where: { $0.recordID == id }) else { return }
        live[id] = p.fraction
        let now = Date()
        rate.append((now, p.doneSec))
        rate.removeAll { now.timeIntervalSince($0.wall) > 60 }
        if let first = rate.first, rate.count >= 2 {
            let done = p.doneSec - first.done, wall = now.timeIntervalSince(first.wall)
            eta = RacketScanETA.remaining(doneSec: max(done, 0), totalSec: max(done, 0) + (p.totalSec - p.doneSec),
                                          elapsedWallSec: wall)
        }
        // Keep the record's progress for a relaunch, every 10 %.
        if p.doneSec - lastSaved >= p.totalSec * 0.1 || p.doneSec >= p.totalSec {
            lastSaved = p.doneSec
            write(job) { $0.doneSec = p.doneSec }
        }
    }

    private func finish(_ job: Job, _ result: Result<[RallyGuess], Error>) {
        defer {
            runningID = nil
            live[job.recordID] = nil
            eta = nil
            task = nil
            endBackground()
            kick()
        }
        let reason = stopReason
        stopReason = nil
        switch result {
        case .success(let guesses):
            jobs.removeAll { $0.recordID == job.recordID }
            complete(job, guesses)
        case .failure(let error):
            if let e = error as? RallyScanError, e == .tooHot {
                hold(job, .heat, note: e.errorDescription)
            } else if error is CancellationError || Task.isCancelled || reason != nil {
                if reason == nil {
                    // Cancelled without a user Stop: leaving the app (background time ran out).
                    hold(job, .background, note: "Paused when Snappet left the screen")
                } else {
                    jobs.removeAll { $0.recordID == job.recordID }
                    write(job) { $0.statusRaw = RacketScanRecord.Status.paused.rawValue; $0.note = reason }
                }
            } else {
                jobs.removeAll { $0.recordID == job.recordID }
                let note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                write(job) { $0.statusRaw = RacketScanRecord.Status.failed.rawValue; $0.note = note }
            }
        }
    }

    private func hold(_ job: Job, _ h: Hold, note: String?) {
        if let i = jobs.firstIndex(where: { $0.recordID == job.recordID }) { jobs[i].hold = h }
        write(job) { $0.statusRaw = RacketScanRecord.Status.paused.rawValue; $0.note = note }
    }

    /// Store the results; put them on the timeline unless they wait for ModelCompare.
    private func complete(_ job: Job, _ guesses: [RallyGuess]) {
        job.store.updateLog(job.exerciseID) { l in
            guard let rec = l.allScans.first(where: { $0.id == job.recordID }) else { return }
            let waits = rec.compare == true && l.appliedScan(partStart: rec.partStart, partEnd: rec.partEnd) != nil
            l.updateScan(job.recordID) {
                $0.statusRaw = RacketScanRecord.Status.done.rawValue
                $0.guesses = guesses
                $0.doneSec = $0.partEnd - $0.partStart
                $0.finishedAt = .now
                $0.note = nil
            }
            if !waits { Self.applyResults(&l, recordID: job.recordID) }
        }
        Haptics.success()
    }

    /// Put a finished scan's guesses on its part ("Use v3", or straight after a scan with nothing to compare).
    static func applyResults(_ l: inout RacketRecordingLog, recordID: UUID) {
        guard let rec = l.allScans.first(where: { $0.id == recordID }), let guesses = rec.guesses else { return }
        l.rallies = RacketRallyGuessMerge.apply(guesses, source: RacketModelSource.raw(id: rec.modelID, version: rec.modelVersion),
                                                to: l.allRallies, partStart: rec.partStart, partEnd: rec.partEnd)
        for other in l.scans(partStart: rec.partStart, partEnd: rec.partEnd) {
            l.updateScan(other.id) { $0.applied = other.id == recordID ? true : ($0.applied == true ? false : $0.applied) }
        }
        l.updateScan(recordID) { $0.compare = nil }
    }

    /// "Keep v2": the new results stay stored (available to compare again), the old ones stay on the timeline.
    static func keepEarlier(_ l: inout RacketRecordingLog, recordID: UUID) {
        l.updateScan(recordID) { $0.compare = nil; $0.applied = false }
    }

    // MARK: Background

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Rally scan") {
            MainActor.assumeIsolated { RacketScanCenter.shared.backgroundExpired() }
        }
    }

    private func backgroundExpired() {
        // Cancel; `finish` holds the job for `.background` and it resumes when Snappet is active again.
        if let id = runningID, let job = jobs.first(where: { $0.recordID == id }) {
            write(job) { $0.statusRaw = RacketScanRecord.Status.paused.rawValue; $0.note = "Paused when Snappet left the screen" }
        }
        task?.cancel()
        endBackground()
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}
