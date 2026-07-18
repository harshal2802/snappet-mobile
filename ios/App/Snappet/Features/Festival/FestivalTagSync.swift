import Foundation
import SwiftData

/// The thin @MainActor edge of festival tagging (festival prompt 03): walks a pack's dance
/// sessions, pulls in Camera-app footage by the padded session window (the #283 pattern — silent,
/// authorized-only, never prompting), snapshots everything to plain values, runs the pure
/// `FestivalSetMatcher` + `FestivalTagging.plan`, and writes the result back as `FestivalClipTag`
/// rows. Idempotent and cheap — safe to call from the schedule's `.task`, the review sheet, set
/// detail, and after End-the-night. All DECISIONS live in `FestivalTagging`; this file only
/// fetches, adapts, and saves.
@MainActor
enum FestivalTagSync {

    /// One pass's working set, kept so the review sheet can render without re-fetching: every
    /// clip's assignment (by media id), its stamp (for time labels + timeline ticks), and the
    /// below-threshold queue in capture order.
    struct Snapshot {
        /// What a review row needs to draw its thumbnail without another fetch.
        struct ClipInfo {
            var localIdentifier: String
            var isVideo: Bool
            var durationSec: Double?
        }

        var assignments: [UUID: FestivalSetMatcher.Assignment] = [:]
        var stamps: [UUID: ClipStamp] = [:]
        var clipInfo: [UUID: ClipInfo] = [:]
        var needsYou: [UUID] = []

        var isEmpty: Bool { stamps.isEmpty }
    }

    /// Run one tagging pass for `pack`. `discover` is the Photos edge (nil under tests / when the
    /// caller doesn't want I/O); it only ever runs with full authorization — a background pass must
    /// never prompt.
    @discardableResult
    static func refresh(pack: FestivalPack, packID: String, context: ModelContext,
                        mediaService: SessionMediaService? = nil, now: Date = .now) async -> Snapshot {
        // 1 — the pack's dance sessions, via its attendance rows (capture rides "I'm here").
        let attendance = fetchAttendance(packID: packID, context: context)
        let sessionIDs = Array(Set(attendance.map(\.sessionID)))
        guard !sessionIDs.isEmpty else { return Snapshot() }
        let sessions = fetchSessions(ids: sessionIDs, context: context)

        // 2 — silent Camera-app discovery into SessionMedia (authorized-only; the ±90 s padded
        // window; the GLOBAL dedup set so an asset never lands in two sessions).
        if let mediaService, mediaService.canAutoDiscover {
            for session in sessions {
                let known = SessionMedia.allIdentifiers(in: context)
                if let found = try? await mediaService.discover(
                    startedAt: session.startedAt, completedAt: session.completedAt,
                    existingIdentifiers: known), !found.isEmpty {
                    for c in found {
                        context.insert(SessionMedia(
                            sessionID: session.id, localIdentifier: c.localIdentifier,
                            kind: c.kind, offsetSec: c.offsetSec, durationSec: c.durationSec,
                            addedManually: false))
                    }
                }
            }
        }

        // 3 — snapshot media → stamps (absolute capture instants) per session.
        var stampsByID: [UUID: ClipStamp] = [:]
        var clipInfo: [UUID: Snapshot.ClipInfo] = [:]
        for session in sessions {
            let sid = session.id
            let rows = (try? context.fetch(FetchDescriptor<SessionMedia>(
                predicate: #Predicate { $0.sessionID == sid }))) ?? []
            let snapshots = rows.map {
                FestivalTagging.MediaSnapshot(mediaID: $0.id, offsetSec: $0.offsetSec,
                                              durationSec: $0.durationSec, isReel: $0.isReel)
            }
            for row in rows where !row.isReel {
                clipInfo[row.id] = Snapshot.ClipInfo(localIdentifier: row.localIdentifier,
                                                     isVideo: row.kind == .video,
                                                     durationSec: row.durationSec)
            }
            for stamp in FestivalTagging.stamps(for: snapshots, sessionStart: session.startedAt) {
                if let id = UUID(uuidString: stamp.id) { stampsByID[id] = stamp }
            }
        }

        // 4 — match (attendance stretches ride along as hints; boost, never override).
        let hints = attendance.map { $0.hint(now: now) }
        let assignments = FestivalSetMatcher.assignments(
            for: stampsByID.values.sorted { $0.captureDate < $1.captureDate },
            in: pack, hints: hints)

        // 5 — plan against the existing rows and write the deltas.
        let existingRows = fetchTags(packID: packID, context: context)
        let existing = existingRows.map {
            FestivalTagging.ExistingTag(mediaID: $0.mediaID, setID: $0.setID, source: $0.source)
        }
        let plan = FestivalTagging.plan(assignments: assignments, existing: existing)
        apply(plan, packID: packID, existingRows: existingRows,
              sessionIDByMedia: sessionIDByMedia(sessions: sessions, context: context),
              context: context)

        var snapshot = Snapshot()
        snapshot.stamps = stampsByID
        snapshot.clipInfo = clipInfo
        for a in assignments {
            guard let id = UUID(uuidString: a.clipID) else { continue }
            snapshot.assignments[id] = a
        }
        let sticky = Set(existingRows.filter { $0.source != .auto }.map(\.mediaID))
        snapshot.needsYou = plan.reviewMediaIDs
            .filter { !sticky.contains($0) }
            .sorted { (stampsByID[$0]?.captureDate ?? .distantPast)
                    < (stampsByID[$1]?.captureDate ?? .distantPast) }
        return snapshot
    }

    /// A user decision from the review sheet: tag `mediaID` to `set` (Change › / a needs-you pick)
    /// — sticky forever after.
    static func resolve(mediaID: UUID, to set: FestivalSet, packID: String,
                        context: ModelContext) {
        let rows = fetchTags(packID: packID, context: context)
        if let row = rows.first(where: { $0.mediaID == mediaID }) {
            row.setID = set.id
            row.artist = set.artist
            row.stage = set.stage
            row.confidence = 1
            row.reason = "your pick"
            row.source = .user
        } else if let sessionID = sessionID(forMedia: mediaID, context: context) {
            context.insert(FestivalClipTag(packID: packID, setID: set.id, artist: set.artist,
                                           stage: set.stage, mediaID: mediaID,
                                           sessionID: sessionID, confidence: 1,
                                           reason: "your pick", source: .user))
        }
        try? context.save()
    }

    /// "Not from a set" — a sticky resolution that excludes the clip from every payoff surface
    /// and keeps the auto pass from re-proposing it.
    static func resolveNotASet(mediaID: UUID, packID: String, context: ModelContext) {
        let rows = fetchTags(packID: packID, context: context)
        if let row = rows.first(where: { $0.mediaID == mediaID }) {
            row.source = .none
            row.confidence = 0
            row.reason = "not from a set"
        } else if let sessionID = sessionID(forMedia: mediaID, context: context) {
            let tag = FestivalClipTag(packID: packID, setID: UUID(), artist: "", stage: "",
                                      mediaID: mediaID, sessionID: sessionID, confidence: 0,
                                      reason: "not from a set", source: .none)
            context.insert(tag)
        }
        try? context.save()
    }

    /// "Looks right · keep all" — confirm every auto tag among `mediaIDs` (they become sticky
    /// `user` rows, so later passes leave them alone even if a lineup revision moves a window).
    static func keepAll(mediaIDs: [UUID], packID: String, context: ModelContext) {
        let rows = fetchTags(packID: packID, context: context)
        for row in rows where row.source == .auto && mediaIDs.contains(row.mediaID) {
            row.source = .user
        }
        try? context.save()
    }

    // MARK: - Private plumbing

    private static func apply(_ plan: FestivalTagging.Plan, packID: String,
                              existingRows: [FestivalClipTag],
                              sessionIDByMedia: [UUID: UUID],
                              context: ModelContext) {
        guard !plan.upserts.isEmpty || !plan.staleMediaIDs.isEmpty else { return }
        let byMedia = Dictionary(existingRows.map { ($0.mediaID, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var changed = false
        for up in plan.upserts {
            if let row = byMedia[up.mediaID] {
                // Only auto rows reach here (the plan skipped sticky ones) — re-place in place,
                // and ONLY when something actually moved: an idempotent pass must not dirty the
                // store (every @Query on tags across the app re-renders on a save).
                guard row.setID != up.set.id || row.confidence != up.confidence
                    || row.reason != up.reason else { continue }
                row.setID = up.set.id
                row.artist = up.set.artist
                row.stage = up.set.stage
                row.confidence = up.confidence
                row.reason = up.reason
                changed = true
            } else if let sessionID = sessionIDByMedia[up.mediaID] {
                context.insert(FestivalClipTag(
                    packID: packID, setID: up.set.id, artist: up.set.artist, stage: up.set.stage,
                    mediaID: up.mediaID, sessionID: sessionID,
                    confidence: up.confidence, reason: up.reason, source: .auto))
                changed = true
            }
        }
        for stale in plan.staleMediaIDs {
            if let row = byMedia[stale], row.source == .auto {
                context.delete(row)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    static func fetchAttendance(packID: String, context: ModelContext) -> [FestivalAttendance] {
        (try? context.fetch(FetchDescriptor<FestivalAttendance>(
            predicate: #Predicate { $0.packID == packID }))) ?? []
    }

    static func fetchTags(packID: String, context: ModelContext) -> [FestivalClipTag] {
        (try? context.fetch(FetchDescriptor<FestivalClipTag>(
            predicate: #Predicate { $0.packID == packID }))) ?? []
    }

    static func fetchSessions(ids: [UUID], context: ModelContext) -> [WorkoutSession] {
        (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { ids.contains($0.id) }))) ?? []
    }

    private static func sessionIDByMedia(sessions: [WorkoutSession],
                                         context: ModelContext) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for session in sessions {
            let sid = session.id
            let rows = (try? context.fetch(FetchDescriptor<SessionMedia>(
                predicate: #Predicate { $0.sessionID == sid }))) ?? []
            for row in rows { out[row.id] = sid }
        }
        return out
    }

    private static func sessionID(forMedia mediaID: UUID, context: ModelContext) -> UUID? {
        (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.id == mediaID })))?.first?.sessionID
    }
}
