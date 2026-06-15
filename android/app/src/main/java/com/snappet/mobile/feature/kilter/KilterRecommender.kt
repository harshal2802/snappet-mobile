package com.snappet.mobile.feature.kilter

import kotlin.math.roundToInt

/**
 * Pure, device-free recommender that turns a climber's logged history + a pool of catalog candidates
 * into a **suggested climbing session** — a few warm-ups below the working grade, a block of sends at
 * it, and a project above (issue #93). The climbing analogue of "pick today's workout", built on the
 * data Kilter already keeps (the same `isSend` signal the History grade pyramid mines).
 *
 * No Room, no catalog DB, no UI — it consumes plain value types ([KilterLogEntry] history,
 * [KilterListItem] candidates) so it's unit-tested with synthetic inputs, exactly like the generator.
 * The screen ([KilterPlanScreen]) does the I/O: reads logs, queries the catalog over a difficulty
 * window, and renders the result. Faithful port of the iOS `KilterRecommender`.
 */
object KilterRecommender {

    /** What a suggested climb is *for* in the session arc (declared easy → hard, the display order). */
    enum class Goal(val label: String) {
        WARMUP("Warm up"), SEND("Send"), PROJECT("Project");
    }

    /** One recommended climb: the catalog item to climb + the role it plays. */
    data class Pick(val item: KilterListItem, val goal: Goal)

    /**
     * A suggested session: picks ordered warm-ups → sends → project, plus the working grade it was
     * built around ([workingDifficulty] is null when there's no send history — a cold start).
     */
    data class Plan(
        val picks: List<Pick>,
        val workingDifficulty: Double?,
        val workingGradeLabel: String?,
    ) {
        val isEmpty: Boolean get() = picks.isEmpty()
        fun picks(goal: Goal): List<Pick> = picks.filter { it.goal == goal }

        companion object {
            val EMPTY = Plan(emptyList(), null, null)
        }
    }

    /** Tunables (sensible defaults; surfaced so tests pin behaviour and a settings screen could tune). */
    data class Options(
        /** Total climbs to suggest. */
        val targetCount: Int = 6,
        /** How many sends in a grade bucket qualify it as the working grade (vs a lucky one-off). */
        val sendThreshold: Int = 2,
        /** For send/project goals, prefer climbs the user hasn't already sent (chase the new). */
        val preferUnsent: Boolean = true,
    )

    // MARK: - Public API

    /**
     * The climber's **working grade**: the hardest difficulty bucket they've sent at least
     * [sendThreshold] times. Falls back to the hardest single send, then null (no sends yet). Buckets
     * are rounded difficulty — the catalog's own grade granularity ([KilterCatalog.gradeLabel]).
     */
    fun workingDifficulty(history: List<KilterLogEntry>, sendThreshold: Int = 2): Double? {
        val sends = history.filter { KilterAscentStatus.from(it.status).isSend }
        if (sends.isEmpty()) return null
        val countByBucket = HashMap<Int, Int>()
        for (s in sends) countByBucket[bucket(s.difficulty)] = (countByBucket[bucket(s.difficulty)] ?: 0) + 1
        val qualifying = countByBucket.filterValues { it >= sendThreshold }.keys.maxOrNull()
        if (qualifying != null) return qualifying.toDouble()
        // Nothing meets the threshold yet → anchor on the hardest single send.
        return sends.map { bucket(it.difficulty) }.max().toDouble()
    }

    /**
     * Build a session plan. [history] is the user's logged climbs (across all sessions); [candidates]
     * is a catalog pool already scoped to the user's layout/angle and spanning roughly the
     * warm-up…project window. Deterministic for a given input (stable tie-breaks), so reproducible and
     * testable. Pass the same [anchor] the candidate query used (see [candidateWindow]) so window and
     * bands share a centre.
     */
    fun recommend(
        history: List<KilterLogEntry>,
        candidates: List<KilterListItem>,
        anchor: Double? = null,
        options: Options = Options(),
    ): Plan {
        val working = workingDifficulty(history, options.sendThreshold)

        val resolvedAnchor: Double = when {
            anchor != null -> anchor
            working != null -> working
            candidates.isNotEmpty() -> {
                val sorted = candidates.map { it.difficulty }.sorted()
                sorted[sorted.size / 2]
            }
            else -> return Plan(emptyList(), working, null)
        }

        val w = bucket(resolvedAnchor)
        val alloc = allocation(options.targetCount)
        val sentUuids = history.filter { KilterAscentStatus.from(it.status).isSend }.map { it.climbUuid }.toSet()

        val chosen = HashSet<String>()
        val picks = ArrayList<Pick>()

        fun take(bands: List<Set<Int>>, count: Int, goal: Goal, allowSent: Boolean) {
            var remaining = count
            for (band in bands) {
                if (remaining <= 0) break
                val pool = rank(candidates.filter {
                    !chosen.contains(it.uuid) &&
                        band.contains(bucket(it.difficulty)) &&
                        (allowSent || !sentUuids.contains(it.uuid))
                })
                for (item in pool) {
                    if (remaining <= 0) break
                    picks.add(Pick(item, goal))
                    chosen.add(item.uuid)
                    remaining -= 1
                }
            }
        }

        // Warm-ups stay below the working grade (revisiting sent classics is fine → allowSent).
        take(listOf(setOf(w - 2, w - 1), setOf(w - 3), setOf(w - 4)), alloc.warmup, Goal.WARMUP, allowSent = true)
        // Sends sit at the working grade; chase un-sent ones when asked.
        take(listOf(setOf(w), setOf(w - 1)), alloc.send, Goal.SEND, allowSent = !options.preferUnsent)
        // A project a touch above.
        take(listOf(setOf(w + 1), setOf(w + 2)), alloc.project, Goal.PROJECT, allowSent = !options.preferUnsent)

        // Order: warm-up → send → project, each easiest→hardest, stable by uuid.
        val order = listOf(Goal.WARMUP, Goal.SEND, Goal.PROJECT)
        val sorted = picks.sortedWith(
            compareBy({ order.indexOf(it.goal) }, { it.item.difficulty }, { it.item.uuid })
        )

        val label = if (working == null) null else gradeLabel(w, history, candidates)
        return Plan(sorted, working, label)
    }

    /**
     * How a target count splits across the three goals — roughly ⅓ warm-up, the bulk sends, one
     * project. Always sums to [target] (for target ≥ 3). Internal so tests can pin it.
     */
    fun allocation(target: Int): Allocation {
        val t = maxOf(1, target)
        if (t == 1) return Allocation(0, 1, 0)
        if (t == 2) return Allocation(1, 1, 0)
        val project = maxOf(1, (t.toDouble() / 6.0).roundToInt())
        val warmup = maxOf(1, (t.toDouble() / 3.0).roundToInt())
        val send = maxOf(1, t - warmup - project)
        return Allocation(warmup, send, project)
    }

    data class Allocation(val warmup: Int, val send: Int, val project: Int)

    /**
     * The catalog difficulty window a caller should fetch candidates over so **every** band
     * `recommend(anchor)` may draw on is populated. Bands span buckets `[w-4 … w+2]` where
     * `w = round(anchor)`; bucket `b` covers `[b-0.5, b+0.5)`, so the window reaches `w-4.5 … w+2.5`.
     * Pass the *same* anchor to [recommend] so window and bands share a centre.
     */
    fun candidateWindow(anchor: Double): Pair<Double, Double> {
        val w = bucket(anchor).toDouble()
        return (w - 4.5) to (w + 2.5)
    }

    // MARK: - Private helpers

    private fun bucket(difficulty: Double): Int = difficulty.roundToInt()

    /** Rank a candidate pool: best quality first, then most-climbed, then easiest, then uuid (stable). */
    private fun rank(items: List<KilterListItem>): List<KilterListItem> =
        items.sortedWith(
            compareByDescending<KilterListItem> { it.quality }
                .thenByDescending { it.ascents }
                .thenBy { it.difficulty }
                .thenBy { it.uuid }
        )

    /** A grade label for the working bucket — preferring the user's own history label, then a candidate. */
    private fun gradeLabel(w: Int, history: List<KilterLogEntry>, candidates: List<KilterListItem>): String? {
        history.firstOrNull { bucket(it.difficulty) == w && it.gradeLabel.isNotEmpty() }?.let { return it.gradeLabel }
        candidates.firstOrNull { bucket(it.difficulty) == w && it.gradeLabel.isNotEmpty() }?.let { return it.gradeLabel }
        return null
    }
}
