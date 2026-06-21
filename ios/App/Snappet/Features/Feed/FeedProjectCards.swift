import Foundation

// MARK: - Recap Feed — project/grade milestone cards (F6 follow-on, pure)
//
// Two log-scanning milestone recipes that the F6 insight menu deferred (see FeedInsightCards):
//   • b2 firstAtGrade — the first-ever send at a grade band, but ONLY as a *backfill* (a harder
//     grade was already sent before it). The first send at a band that IS the all-time max at that
//     moment is a b1 grade PR (handled in FeedComposer.gradePRCards), so b2 skips it to avoid dupes.
//   • g1 projectSent — a climb (by climbUUID) that went .project → .sent/.flash; sessions counts the
//     distinct sessions it was a project in before the send.
//
// Pure value logic (Foundation only) — degrade-by-absence: a card is simply never produced when its
// trigger is missing. Per-climb cards carry FeedContentIdentity.climb(uuid:) as their contentId.
enum FeedProjectCards {

    static func cards(logs: [KilterClimbLog], now: Date, calendar: Calendar, anchor: Date) -> [FeedCard] {
        firstAtGradeCards(logs: logs, now: now) + projectSentCards(logs: logs, now: now)
    }

    // MARK: b2 — first-ever send at a grade band (backfill only)

    private static func firstAtGradeCards(logs: [KilterClimbLog], now: Date) -> [FeedCard] {
        // Sends only, in chronological order (stable on loggedAt).
        let sends = logs.filter { $0.isSend }
            .sorted { $0.loggedAt < $1.loggedAt }
        guard !sends.isEmpty else { return [] }

        var maxSoFar: Double? = nil          // hardest difficulty sent strictly before the current send
        var seenGrades: Set<String> = []     // grade bands whose first send we've already passed
        var out: [FeedCard] = []

        for send in sends {
            let grade = send.gradeLabel
            let isFirstAtBand = !seenGrades.contains(grade)
            seenGrades.insert(grade)
            defer { maxSoFar = max(maxSoFar ?? send.difficulty, send.difficulty) }

            guard isFirstAtBand else { continue }
            // Emit b2 only when a HARDER grade was already sent before this band's first send
            // (a backfill of an easier grade). If this is the all-time max at the time, it's a b1 PR.
            guard let prevMax = maxSoFar, prevMax > send.difficulty else { continue }

            let payload = FirstAtGradePayload(grade: grade, climbName: send.climbName)
            out.append(FeedCard(
                id: "b2-\(send.climbUUID)-\(grade)",
                contentId: FeedContentIdentity.climb(uuid: send.climbUUID),
                kind: .b2FirstAtGrade,
                category: .milestone,
                salience: 0.60,
                anchorDate: min(send.loggedAt, now),
                sourceRefs: [ActivityRef(objectKind: "climb", ref: send.climbUUID)],
                payload: .firstAtGrade(payload),
                shareHint: .sendCard))
        }
        return out
    }

    // MARK: g1 — a climb that went project → sent

    private static func projectSentCards(logs: [KilterClimbLog], now: Date) -> [FeedCard] {
        // Group by climb identity.
        var byClimb: [String: [KilterClimbLog]] = [:]
        for log in logs { byClimb[log.climbUUID, default: []].append(log) }

        var out: [FeedCard] = []
        for (uuid, climbLogs) in byClimb {
            let ordered = climbLogs.sorted { $0.loggedAt < $1.loggedAt }
            // The first send/flash for this climb.
            guard let send = ordered.first(where: { $0.isSend }) else { continue }
            // It only counts as a "project sent" if it was logged as a project earlier.
            let priorProjects = ordered.filter { $0.status == .project && $0.loggedAt < send.loggedAt }
            guard !priorProjects.isEmpty else { continue }

            // Distinct sessions it was a project in before the send (logs without a sessionId each
            // count as their own ad-hoc occurrence so a single nil-session project still reads as 1).
            var sessionKeys: Set<String> = []
            for p in priorProjects {
                sessionKeys.insert(p.sessionId?.uuidString ?? "adhoc-\(p.loggedAt.timeIntervalSinceReferenceDate)")
            }
            let sessions = max(1, sessionKeys.count)

            let payload = ProjectSentPayload(grade: send.gradeLabel, climbName: send.climbName, sessions: sessions)
            out.append(FeedCard(
                id: "g1-\(uuid)",
                contentId: FeedContentIdentity.climb(uuid: uuid),
                kind: .g1ProjectSent,
                category: .milestone,
                salience: 0.85,
                anchorDate: min(send.loggedAt, now),
                sourceRefs: [ActivityRef(objectKind: "climb", ref: uuid)],
                payload: .projectSent(payload),
                shareHint: .sendCard))
        }
        // Deterministic order (dictionary iteration is unstable): newest send first, then uuid.
        return out.sorted {
            $0.anchorDate != $1.anchorDate ? $0.anchorDate > $1.anchorDate : $0.id < $1.id
        }
    }
}
