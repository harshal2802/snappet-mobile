import Foundation

/// A clip as the matcher sees it: an opaque id, the capture instant, and (when known) how long the
/// camera rolled. Deliberately NOT `PHAsset`/`FeedMedia` — prompt 03 adapts real session media into
/// these values (the #283 session-media-window pattern), which is what keeps the matcher pure.
struct ClipStamp: Sendable, Equatable {
    var id: String
    var captureDate: Date
    var duration: TimeInterval?

    /// The clip's span; a photo (no duration) is a zero-length interval at its capture instant.
    var interval: DateInterval {
        DateInterval(start: captureDate, duration: max(0, duration ?? 0))
    }
}

///"I'm here" evidence from a dance session (prompt 02's data): the user said they were at `setID`
/// during `interval`. A hint *boosts* an assignment the time evidence already supports and breaks
/// ties between live candidates — it never overrides what the timestamps say.
struct FestivalSessionHint: Sendable, Equatable {
    var setID: UUID
    var interval: DateInterval
}

/// The keystone of the Festival feature: assigns clips to artists' sets by timestamp × set-window
/// overlap, with a stated confidence and a machine-readable reason. A set is an interval and every clip
/// has a timestamp — that's the whole trick — so the hard part is exactly the ambiguity this scores:
/// two stages live at once, a clip in the gap between sets, a long clip straddling adjacent sets.
/// Ambiguity lowers confidence below `autoTagThreshold` and floats to the review sheet (wireframe
/// frame 9); it is never silently guessed.
///
/// Pure Foundation, value-in/value-out → the confidence table unit-tests without a simulator.
enum FestivalSetMatcher {

    // MARK: Confidence semantics (one source of truth — the review UI reads these)

    /// At or above this, a tag applies silently; below it, the clip floats to "Needs you". The ONE
    /// constant that separates auto from ask — prompt 03's review sheet reads it from here.
    static let autoTagThreshold = 0.8
    /// A lone set contains the clip → this is as sure as time evidence gets.
    static let withinSetConfidence = 0.97
    /// Ceiling when ≥2 sets overlap the clip. Deliberately below `autoTagThreshold`: two-stages-live is
    /// never auto-tagged, hint or no hint (acceptance criterion of festival prompt 01).
    static let multipleLiveCap = 0.65
    /// Gap confidence at a set's edge, decaying linearly to the floor over `gapDecaySeconds`
    /// ("between stages → 62%" at ~6 min in the wireframe caption). Always below the auto threshold —
    /// a clip in a gap always asks.
    static let gapEdgeConfidence = 0.70
    static let gapFloorConfidence = 0.30
    static let gapDecaySeconds: TimeInterval = 1800
    /// What a corroborating hint adds; clamped to `maxConfidence` (or `multipleLiveCap` when ≥2 live).
    static let hintBoost = 0.1
    static let maxConfidence = 0.99

    // MARK: Output

    struct Assignment: Sendable, Equatable {
        let clipID: String
        /// The tagged set — `nil` only for `.outsideSchedule`.
        let set: FestivalSet?
        let confidence: Double
        let reason: Reason

        var isAutoTag: Bool { self.set != nil && confidence >= FestivalSetMatcher.autoTagThreshold }
    }

    /// Why the matcher chose (or didn't) — the review sheet's row captions, as data.
    enum Reason: Sendable, Equatable {
        /// Exactly one set overlaps the clip.
        case withinSet
        /// No set was live; the clip sits in the gap between these two (assigned the nearer).
        case betweenSets(before: FestivalSet, after: FestivalSet)
        /// ≥2 sets overlap the clip's span — usually two stages live, or a long clip straddling
        /// adjacent sets on one stage. Sorted by start (then artist) for stable review rows.
        case multipleStagesLive([FestivalSet])
        /// Outside every festival day window, or in a day with no set before/after to lean on.
        case outsideSchedule
    }

    // MARK: Matching

    static func assignments(for clips: [ClipStamp], in pack: FestivalPack,
                            hints: [FestivalSessionHint] = []) -> [Assignment] {
        assignments(for: clips, days: pack.days, utcOffsetSeconds: pack.utcOffsetSeconds, hints: hints)
    }

    static func assignments(for clips: [ClipStamp], on day: FestivalDay, utcOffsetSeconds: Int,
                            hints: [FestivalSessionHint] = []) -> [Assignment] {
        assignments(for: clips, days: [day], utcOffsetSeconds: utcOffsetSeconds, hints: hints)
    }

    static func assignments(for clips: [ClipStamp], days: [FestivalDay], utcOffsetSeconds: Int,
                            hints: [FestivalSessionHint] = []) -> [Assignment] {
        clips.map { assignment(for: $0, days: days, utcOffsetSeconds: utcOffsetSeconds, hints: hints) }
    }

    static func assignment(for clip: ClipStamp, days: [FestivalDay], utcOffsetSeconds: Int,
                           hints: [FestivalSessionHint] = []) -> Assignment {
        let t = clip.captureDate
        // The hint that covers this clip's capture instant, if any.
        let hint = hints.first { $0.interval.contains(t) }
        let allSets = days.flatMap(\.allSets)
        let candidates = allSets.filter { overlap(of: clip, with: $0) > 0 }

        switch candidates.count {
        case 1:
            var confidence = withinSetConfidence
            if hint?.setID == candidates[0].id {
                confidence = min(maxConfidence, confidence + hintBoost)
            }
            return Assignment(clipID: clip.id, set: candidates[0], confidence: confidence,
                              reason: .withinSet)

        case 2...:
            return multipleLiveAssignment(for: clip, candidates: candidates, hint: hint)

        default:
            return gapAssignment(for: clip, days: days, utcOffsetSeconds: utcOffsetSeconds, hint: hint)
        }
    }

    // MARK: - The ambiguous paths

    /// ≥2 sets overlap the clip. Chosen by hint (if the hinted set is a candidate — a tie-break, never
    /// an override), else by greatest overlap with the clip's span, else (instant clips) by nearest set
    /// midpoint. Confidence is the chosen candidate's share of the evidence, scaled into
    /// `0…multipleLiveCap` — structurally incapable of auto-tagging.
    private static func multipleLiveAssignment(for clip: ClipStamp, candidates: [FestivalSet],
                                               hint: FestivalSessionHint?) -> Assignment {
        let t = clip.captureDate
        let hasDuration = (clip.duration ?? 0) > 0
        // Evidence weight per candidate: overlap seconds for rolling clips; inverse midpoint distance
        // (clamped to ≥60 s so a dead-center clip doesn't take the whole share) for instants.
        let weights: [Double] = candidates.map { set in
            if hasDuration { return overlap(of: clip, with: set) }
            let mid = set.start.addingTimeInterval(set.end.timeIntervalSince(set.start) / 2)
            return 1 / max(60, abs(t.timeIntervalSince(mid)))
        }
        let total = weights.reduce(0, +)

        var bestIndex = 0
        if let hinted = candidates.firstIndex(where: { $0.id == hint?.setID }) {
            bestIndex = hinted
        } else {
            for i in candidates.indices where weights[i] > weights[bestIndex]
                || (weights[i] == weights[bestIndex] && candidates[i].start < candidates[bestIndex].start) {
                bestIndex = i
            }
        }

        var confidence = total > 0 ? multipleLiveCap * (weights[bestIndex] / total) : 0
        if candidates[bestIndex].id == hint?.setID {
            confidence = min(multipleLiveCap, confidence + hintBoost)
        }
        let sorted = candidates.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist
        }
        return Assignment(clipID: clip.id, set: candidates[bestIndex], confidence: confidence,
                          reason: .multipleStagesLive(sorted))
    }

    /// No set was live at the clip. If it falls inside a festival day *between* two sets, lean toward
    /// the nearer edge with confidence decaying over `gapDecaySeconds` — always below the auto
    /// threshold, so gaps always ask. Before the day's first set, after its last, or outside every day
    /// window entirely → `.outsideSchedule` (campsite footage isn't anyone's set).
    private static func gapAssignment(for clip: ClipStamp, days: [FestivalDay], utcOffsetSeconds: Int,
                                      hint: FestivalSessionHint?) -> Assignment {
        let t = clip.captureDate
        let outside = Assignment(clipID: clip.id, set: nil, confidence: 0, reason: .outsideSchedule)

        guard let day = days.first(where: {
            $0.window(utcOffsetSeconds: utcOffsetSeconds)?.contains(t) == true
        }) else { return outside }

        let sets = day.allSets
        guard let before = sets.filter({ $0.end <= t }).max(by: { $0.end < $1.end }),
              let after = sets.filter({ $0.start >= clip.interval.end })
                  .min(by: { $0.start < $1.start }) else { return outside }

        let dBefore = t.timeIntervalSince(before.end)
        let dAfter = after.start.timeIntervalSince(t)
        var chosen = dBefore <= dAfter ? before : after
        // A hint naming one side is a tie-breaker toward that side — still gap-scored, never boosted
        // past what the (weak) time evidence supports.
        if let hint, hint.setID == before.id || hint.setID == after.id {
            chosen = hint.setID == before.id ? before : after
        }
        let d = chosen.id == before.id ? dBefore : dAfter
        let confidence = max(gapFloorConfidence,
                             gapEdgeConfidence
                                 - (gapEdgeConfidence - gapFloorConfidence)
                                 * min(1, d / gapDecaySeconds))
        return Assignment(clipID: clip.id, set: chosen, confidence: confidence,
                          reason: .betweenSets(before: before, after: after))
    }

    /// Seconds of the clip's span a set covers. A zero-length clip (photo) "overlaps" a set when the
    /// set's half-open window `[start, end)` contains the instant — half-open so a photo at the exact
    /// handover between back-to-back sets counts only toward the one starting.
    private static func overlap(of clip: ClipStamp, with set: FestivalSet) -> TimeInterval {
        let i = clip.interval
        if i.duration == 0 {
            return set.start <= i.start && i.start < set.end ? 1 : 0
        }
        return max(0, min(set.end, i.end).timeIntervalSince(max(set.start, i.start)))
    }
}
