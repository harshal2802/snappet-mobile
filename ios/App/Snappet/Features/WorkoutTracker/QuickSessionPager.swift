import Foundation

/// Pure page / rail / plan logic for the Quick Session **full-screen pager** (prompt 109).
///
/// The pager shows one exercise per page, swiped L↔R in added order, with a session **overview**
/// page on the left edge and an **add-exercise** page past the last exercise. This type owns every
/// decision the shell needs that isn't rendering: the page list, the rail-chip model (the page
/// indicator), plan progress + the plan-complete nudge, the plan default, and the history-drawer
/// deltas. No SwiftUI/SwiftData imports — unit-tested in `SnappetTests` without a simulator.
enum QuickSessionPager {

    // MARK: - Pages

    /// One pager page. `Hashable` so it can drive `TabView(selection:)` tags directly.
    enum Page: Hashable, Sendable {
        case overview
        case exercise(UUID)
        case add
    }

    /// The page list: overview, then every exercise **in added order**, then the add page.
    static func pages(for exercises: [SessionExercise]) -> [Page] {
        [.overview] + exercises.map { .exercise($0.id) } + [.add]
    }

    /// The page for a just-added exercise (the shell auto-advances here): its `.exercise` page,
    /// or the add page when the id isn't in the session (defensive).
    static func page(for exerciseID: UUID, in exercises: [SessionExercise]) -> Page {
        exercises.contains { $0.id == exerciseID } ? .exercise(exerciseID) : .add
    }

    // MARK: - Plan progress

    /// The plan row's state for one exercise: sets done vs the optional planned count.
    struct PlanState: Equatable, Sendable {
        var done: Int
        /// `nil` ⇒ no plan (open-ended exercise) — the plan row shows a plain logged count.
        var planned: Int?

        var isComplete: Bool { planned.map { $0 > 0 && done >= $0 } ?? false }

        /// "set 3 of 5" while working a plan · "5 of 5 ✓" complete · "3 sets" with no plan.
        func label(noun: String = "set") -> String {
            if let planned, planned > 0 {
                return isComplete ? "\(planned) of \(planned) ✓"
                                  : "\(noun) \(min(done + 1, planned)) of \(planned)"
            }
            return done == 1 ? "1 \(noun)" : "\(done) \(noun)s"
        }
    }

    /// The plan state for an exercise, or `nil` when the plan axis doesn't apply (climbs — attempts
    /// aren't planned; the climb page shows the attempt count instead).
    static func planState(for ex: SessionExercise) -> PlanState? {
        guard ex.discipline != .climb else { return nil }
        return PlanState(done: ex.completedSetCount, planned: ex.plannedSets)
    }

    /// The per-discipline noun for plan labels and ledgers ("set" / "leg" / "round").
    static func effortNoun(for ex: SessionExercise) -> String {
        switch ex.discipline {
        case .run:   return "leg"
        case .climb: return "attempt"
        default:     return ex.timedSpec?.mode.isStructured == true ? "round" : "set"
        }
    }

    /// Default plan for a fresh exercise: how many sets the user logged **last time** they did this
    /// exercise (most recent completed session containing it), or `nil` when there's no precedent.
    /// Ad-hoc entities (exerciseId `adhoc-*`) match by display name since their catalog id is shared.
    static func defaultPlan(exerciseId: String, displayName: String?,
                            history: [WorkoutSession]) -> Int? {
        lastSessionSets(exerciseId: exerciseId, displayName: displayName, history: history)
            .map(\.count)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - The plan-complete nudge

    /// The next exercise worth advancing to after `id`: scans forward (then wraps) for the first
    /// exercise that is **unfinished** — an incomplete plan, or nothing logged yet. `nil` when every
    /// other exercise is done (the nudge then offers Finish instead).
    static func nextIncomplete(after id: UUID, in exercises: [SessionExercise]) -> UUID? {
        guard let idx = exercises.firstIndex(where: { $0.id == id }) else { return nil }
        let ordered = exercises[(idx + 1)...] + exercises[..<idx]
        return ordered.first(where: isUnfinished)?.id
    }

    /// Unfinished = an explicit plan not yet met, or no logged effort at all.
    static func isUnfinished(_ ex: SessionExercise) -> Bool {
        if let planned = ex.plannedSets, planned > 0 { return ex.completedSetCount < planned }
        return ex.completedSetCount == 0
    }

    // MARK: - Rail chips (the page indicator)

    /// One chip in the exercise rail. `page` doubles as the stable identity.
    struct RailChip: Equatable, Identifiable, Sendable {
        var page: Page
        /// SF Symbol for the chip (discipline symbol; overview/add have their own).
        var symbol: String
        /// Short title — a climb shows its grade, everything else the name's first word.
        var title: String
        /// Mini progress ("2/5" with a plan, "3" logged without one); `nil` when nothing logged.
        var detail: String?
        /// Plan met — the chip renders its done state (✓ tint).
        var done: Bool
        var id: Page { page }
    }

    /// Build the rail: overview chip · one chip per exercise (added order) · the add chip.
    /// `names` resolves an exercise's display name (the resolver is platform-side).
    static func railChips(for exercises: [SessionExercise],
                          names: (SessionExercise) -> String) -> [RailChip] {
        var chips: [RailChip] = [RailChip(page: .overview, symbol: "circle.grid.2x2",
                                          title: "Overview", detail: nil, done: false)]
        for ex in exercises {
            let plan = planState(for: ex)
            let detail: String? = {
                if let plan, let planned = plan.planned, planned > 0 { return "\(plan.done)/\(planned)" }
                let n = ex.completedSetCount
                return n > 0 ? "\(n)" : nil
            }()
            chips.append(RailChip(
                page: .exercise(ex.id),
                symbol: ex.discipline == .climb ? ex.climbType.symbol : ex.discipline.symbol,
                title: railTitle(for: ex, name: names(ex)),
                detail: detail,
                done: plan?.isComplete ?? false))
        }
        chips.append(RailChip(page: .add, symbol: "plus", title: "Add", detail: nil, done: false))
        return chips
    }

    /// A chip-sized title: a climb reads as its grade ("V5"); everything else as the name's first
    /// word, ellipsized past 10 characters so the rail never scrolls for one long name.
    static func railTitle(for ex: SessionExercise, name: String) -> String {
        if ex.discipline == .climb, let grade = ex.climbGradeLabel, !grade.isEmpty { return grade }
        let word = name.split(separator: " ").first.map(String.init) ?? name
        return word.count > 10 ? String(word.prefix(9)) + "…" : word
    }

    // MARK: - Page-recorded clip routing (prompt 113, #273)

    /// One attach batch for clips recorded from a page's record button: where they file, and in
    /// what order.
    struct PageClipGroup: Equatable, Sendable {
        /// The exercise to pin to — the page the recorder was **presented** from. `nil` ⇒ that
        /// exercise was deleted while the Photos save was in flight; the clips file to the
        /// session unassigned instead (a recorded clip is never dropped).
        var exerciseID: UUID?
        var clips: [RecordedClip]
    }

    /// Route queued page recordings to their attach targets. `queued` is keyed by the exercise
    /// whose page the recorder was opened on (the record-time owner) — the CURRENT page plays no
    /// part, so swiping away during the async Photos save can neither re-pin a clip to the wrong
    /// exercise nor discard it (the old shared-binding bug, #273). Owners no longer in the
    /// session route to `exerciseID: nil`. Clips sort by capture time within a group; groups by
    /// their earliest capture, so multi-owner batches attach in recording order.
    static func pageClipAttachPlan(queued: [UUID: [RecordedClip]],
                                   liveExerciseIDs: Set<UUID>) -> [PageClipGroup] {
        queued
            .filter { !$0.value.isEmpty }
            .map { owner, clips in
                PageClipGroup(exerciseID: liveExerciseIDs.contains(owner) ? owner : nil,
                              clips: clips.sorted { $0.capturedAt < $1.capturedAt })
            }
            .sorted { ($0.clips.first?.capturedAt ?? .distantPast)
                    < ($1.clips.first?.capturedAt ?? .distantPast) }
    }

    // MARK: - History-drawer deltas

    /// Direction of a per-set change vs the previous session, for the drawer's comparison column.
    enum DeltaDirection: Equatable, Sendable { case up, down, same }

    struct SetDelta: Equatable, Sendable {
        var direction: DeltaDirection
        /// "▲ +2.5 kg" / "▼ −0:05" / "= same". Pre-formatted so the row just renders it.
        var label: String
    }

    /// Per-set deltas of this session's sets vs the same-index sets of the previous session's run
    /// of the same exercise. Compares the discipline's primary measure (weight / duration /
    /// distance); `nil` where there's no counterpart set or no comparable measure.
    static func deltas(current: [SetLog], previous: [SetLog], kind: SetKind) -> [SetDelta?] {
        current.indices.map { i in
            guard i < previous.count else { return nil }
            let cur = current[i], prev = previous[i]
            switch kind {
            case .repsWeight:
                guard let c = cur.actualWeight, let p = prev.actualWeight else { return nil }
                // Compare in the stored unit only when the units match; a cross-unit pair would
                // need a conversion table this drawer doesn't warrant.
                guard cur.weightUnit == prev.weightUnit else { return nil }
                return delta(c - p, format: { SetMeasure.formatWeight(abs($0)) + " \(cur.weightUnit?.display ?? "kg")" })
            case .duration:
                guard let c = cur.durationSec, let p = prev.durationSec else { return nil }
                return delta(c - p, format: { SetMeasure.formatDuration(abs($0)) })
            case .climbAttempt:
                return nil   // outcomes don't diff numerically
            }
        }
    }

    private static func delta(_ diff: Double, format: (Double) -> String) -> SetDelta {
        if abs(diff) < 0.01 { return SetDelta(direction: .same, label: "= same") }
        return diff > 0 ? SetDelta(direction: .up, label: "▲ +\(format(diff))")
                        : SetDelta(direction: .down, label: "▼ −\(format(diff))")
    }

    /// The previous session's sets for the same exercise — the drawer's comparison baseline and the
    /// plan default's source. Order-independent (most recent completed session by `startedAt` wins,
    /// the `LastSetLookup` rule); active sessions and empty runs are skipped. Ad-hoc ids
    /// (`adhoc-*`) additionally match by display name since their catalog id is shared.
    static func lastSessionSets(exerciseId: String, displayName: String?,
                                history: [WorkoutSession]) -> [SetLog]? {
        let isAdhoc = exerciseId.hasPrefix("adhoc-")
        let candidates = history
            .filter { !$0.isActive }
            .sorted { $0.startedAt > $1.startedAt }
        for session in candidates {
            let match = session.exercises.first {
                if isAdhoc {
                    return $0.exerciseId == exerciseId && $0.displayName == displayName
                }
                return $0.exerciseId == exerciseId
            }
            if let match, !match.sets.isEmpty { return match.sets }
        }
        return nil
    }
}
