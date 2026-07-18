import Foundation

/// Ranks the sets you HAVEN'T starred to fill the gaps in your plan — the keystone of festival
/// prompt 04 (wireframe frame 8's "For you"). Pure and deterministic: identical inputs yield the
/// identical order AND the identical machine-readable `Reason`, every time, so the ranking unit-tests
/// without a simulator and never surprises the user. Signals, weighted then summed:
///
///   • **artist affinity** — your logged HR-per-artist history (`FestivalHRHistory`). The artist you
///     danced hardest to, playing again, is the top signal (`.heardBefore`).
///   • **plan gaps** — a candidate whose start falls inside an empty stretch of your plan
///     (`FestivalPlan.gaps`) — the "your 01:00 is empty" nudge (`.fillsGap`).
///   • **walk time** — a candidate on the SAME stage as one of your stars costs no walk, a soft
///     bonus; cross-stage costs a nominal walk. There's no geo in the `.fpack`, so walk is
///     modelled as same-stage/other-stage, not metres (a data leg — see decisions.md).
///   • **clash avoidance** — a candidate that overlaps one of your stars is never suggested (a hard
///     drop): the recommender only proposes sets you could actually attend.
///
/// The `Reason` is the single strongest contributing signal, carried as data so the template floor
/// AND the optional on-device Foundation Models pass render the SAME facts (E7 contract: FM only
/// rephrases the reason string — never the ranking, never the numbers).
enum SetRecommender {

    struct Config: Sendable, Equatable {
        /// Nominal minutes to walk between two different stages (no geo in the pack; a data leg).
        var stageWalkMinutes: Int = 8
        /// How many suggestions the For-You sheet shows.
        var limit: Int = 3
        /// The floor score every clash-free upcoming set gets, so there's always something to offer
        /// even before any HR history exists.
        var basePick: Double = 0.15
        /// A candidate must beat this to be offered at all.
        var minScore: Double = 0.1
        static let `default` = Config()
    }

    /// Why a set is suggested — machine-readable so the template line and the FM rewrite read the
    /// SAME facts.
    enum Reason: Sendable, Equatable {
        /// You've danced to this exact artist before, hitting `peakBPM` at `festival`.
        case heardBefore(artist: String, peakBPM: Int, festival: String)
        /// Fills the empty stretch of your plan that starts at `gapStart`; `sameStageAs` names an
        /// adjacent star on the same stage (zero walk) when there is one.
        case fillsGap(gapStart: Date, sameStageAs: String?)
        /// On the same stage as `star`, no walk — a low-effort add beside what you starred.
        case sameStage(star: String)
        /// Nothing personal yet — a clash-free set worth a look (the always-present floor).
        case freshPick
    }

    struct Suggestion: Sendable, Equatable, Identifiable {
        var set: FestivalSet
        var score: Double
        var reason: Reason
        /// The deterministic template one-liner — the heuristic FLOOR the sheet always shows and the
        /// FM pass optionally rewrites. Pure, so it's unit-tested as documentation of each reason.
        var templateReason: String
        // `self.` is load-bearing: a getter body starting with the bare identifier `set` parses as a
        // setter accessor ("expected '{' to start setter definition") — the prompt-01 pitfall.
        var id: UUID { self.set.id }
    }

    /// Rank the unstarred, clash-free, still-upcoming sets. `now` gates out sets that already
    /// started; `history` is your cross-festival HR-per-artist affinity.
    static func suggestions(in pack: FestivalPack, starred: Set<UUID>,
                            history: FestivalHRHistory, now: Date,
                            config: Config = .default) -> [Suggestion] {
        let plan = FestivalPlan(starredSetIDs: starred)
        let starredSets = plan.starredSets(in: pack)
        let gaps = plan.gaps(in: pack)
        let offset = pack.utcOffsetSeconds

        let candidates = pack.allSets.filter { set in
            !starred.contains(set.id)                              // not already yours
                && set.start > now                                 // still ahead
                && !starredSets.contains { overlaps(set, $0) }     // never suggest a clash
        }

        var out: [Suggestion] = []
        for set in candidates {
            var score = config.basePick
            var reason: Reason = .freshPick

            // Same-stage star (zero walk) — a soft bonus and a fallback reason.
            let sameStageStar = starredSets.first { $0.stage == set.stage }
            if sameStageStar != nil {
                score += 0.25
                reason = .sameStage(star: sameStageStar!.artist)
            }

            // Plan gap — this set starts inside an empty stretch you'd otherwise stand idle in.
            if let gap = gaps.first(where: { $0.contains(set.start) }) {
                score += 0.6
                reason = .fillsGap(gapStart: gap.start,
                                   sameStageAs: sameStageStar?.artist)
            }

            // Artist affinity — the strongest signal: you've danced hard to this exact artist.
            if let aff = history.affinity(for: set.artist) {
                // Scale by how hard you danced (peak toward a ~200 BPM ceiling), so your favourite
                // outranks a merely-familiar name; always above gap/walk weight.
                score += 1.0 + min(1.0, Double(aff.peakBPM) / 200.0)
                reason = .heardBefore(artist: aff.artist, peakBPM: aff.peakBPM,
                                      festival: aff.lastFestival)
            } else if !history.isEmpty {
                // A mild "you dance hard" prior for a stranger — never enough to outrank a match.
                score += 0.05
            }

            guard score >= config.minScore else { continue }
            out.append(Suggestion(set: set, score: score, reason: reason,
                                  templateReason: templateLine(reason, set: set,
                                                               offsetSeconds: offset)))
        }

        return out
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.set.start != b.set.start { return a.set.start < b.set.start }
                if a.set.artist != b.set.artist { return a.set.artist < b.set.artist }
                return a.set.id.uuidString < b.set.id.uuidString
            }
            .prefix(config.limit)
            .map { $0 }
    }

    /// Two sets overlap in time (stages don't matter — clash math is interval math). Back-to-back
    /// (end == next start) is not an overlap, matching `FestivalPlan.clashes`.
    private static func overlaps(_ a: FestivalSet, _ b: FestivalSet) -> Bool {
        a.start < b.end && b.start < a.end
    }

    // MARK: Template floor (the heuristic reason lines FM optionally rewrites)

    /// The deterministic one-line "why", per reason. Reads like the wireframe frame-8 captions; the
    /// FM pass rephrases only this string, never its facts.
    static func templateLine(_ reason: Reason, set: FestivalSet, offsetSeconds: Int) -> String {
        let time = FestivalSchedule.timeLabel(set.start, offsetSeconds: offsetSeconds)
        switch reason {
        case let .heardBefore(artist, peakBPM, festival):
            return "You peaked at \(peakBPM) ♥ dancing to \(artist) at \(festival) — worth catching again."
        case let .fillsGap(gapStart, sameStageAs):
            let gapTime = FestivalSchedule.timeLabel(gapStart, offsetSeconds: offsetSeconds)
            if let star = sameStageAs {
                return "Fills the empty \(gapTime) in your plan — same stage as \(star), no walk."
            }
            return "Fills the empty \(gapTime) in your plan, and doesn't clash with your stars."
        case let .sameStage(star):
            return "Same stage as \(star) at \(time) — no walk between sets."
        case .freshPick:
            return "\(set.stage) at \(time), and it doesn't clash with your plan."
        }
    }
}
