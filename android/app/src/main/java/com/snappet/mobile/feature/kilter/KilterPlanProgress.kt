package com.snappet.mobile.feature.kilter

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Pure, device-free model + logic for a **persisted** planned session — the keystone that decouples a
 * plan from the volatile [KilterRecommender] output. Faithful port of the iOS `KilterPlanLogic.swift`.
 *
 * [KilterRecommender] stays a pure *generator*; once the climber taps **Start**, its [KilterRecommender.Plan]
 * is snapshotted into ordered [KilterPlanItem]s and the live UI reads done-state from
 * [KilterPlanItem.status] instead of re-deriving it from `logs ∩ recommend()` every render. That single
 * move kills the "completed send/project pick vanishes on the next log" defect (the recommender used to
 * drop now-sent UUIDs and reshuffle), and gives the session a stable, re-enterable home.
 *
 * No Room / no Compose here, so it is unit-tested on the JVM with synthetic inputs, exactly like
 * [KilterRecommender]. The Room wrapper that persists this ([KilterPlanEntity]) stores the items as a
 * JSON `String` column (kotlinx.serialization) — there is no Room `@TypeConverter` in this codebase.
 */

/** How a planned pick has resolved as the session runs. Stored by [name] on [KilterPlanItem.statusRaw]. */
enum class KilterPlanItemStatus {
    /** Not yet attempted — the only state a Plan-ready item can be in. */
    PENDING,
    /** Logged as a send or flash ([KilterAscentStatus.isSend]). */
    SENT,
    /** Logged as an attempt or project — worked, not (yet) sent. */
    ATTEMPTED,
    /** The climber explicitly skipped this pick (a deliberate "not today", distinct from pending). */
    SKIPPED;

    /** Whether the pick earned a green tick / counts toward "N of M done" (engaged with, not skipped). */
    val isDone: Boolean get() = this == SENT || this == ATTEMPTED

    companion object {
        fun from(raw: String): KilterPlanItemStatus = entries.firstOrNull { it.name == raw } ?: PENDING
    }
}

/**
 * One ordered pick in a persisted plan, carrying its own completion state so done-ness survives any
 * recommender re-run. `@Serializable` so the list rides as a JSON column on [KilterPlanEntity].
 * [climbUuid] is the same key `SessionMedia`/log entries use, so a plan row inherits its session clips
 * by a pure join.
 */
@Serializable
data class KilterPlanItem(
    val id: String,
    /** Position in the frozen plan (0-based); the display + "next up" order. */
    val order: Int,
    /** [KilterRecommender.Goal.name] — what this pick is *for* (WARMUP / SEND / PROJECT). */
    val goalRaw: String,
    val climbUuid: String,
    val climbName: String,
    val setter: String,
    val gradeLabel: String,
    val difficulty: Double,
    /** [KilterPlanItemStatus.name]. */
    val statusRaw: String,
    /** Pinned across "Shuffle" while still in **Plan ready** (reserved; lock UI is a later increment). */
    val locked: Boolean = false,
    /** When the pick resolved (sent/attempted), epoch millis; null while pending/skipped. */
    val completedAtMillis: Long? = null,
) {
    val goal: KilterRecommender.Goal
        get() = KilterRecommender.Goal.entries.firstOrNull { it.name == goalRaw } ?: KilterRecommender.Goal.SEND
    val status: KilterPlanItemStatus get() = KilterPlanItemStatus.from(statusRaw)
}

/** Pure operations over a plan's items. Every function is total + deterministic; the caller persists. */
object KilterPlanProgress {

    /** Snapshot a recommender [KilterRecommender.Plan] into ordered plan items — the freeze on **Start**. */
    fun items(from: KilterRecommender.Plan): List<KilterPlanItem> =
        from.picks.mapIndexed { idx, pick ->
            KilterPlanItem(
                id = UUID.randomUUID().toString(),
                order = idx,
                goalRaw = pick.goal.name,
                climbUuid = pick.item.uuid,
                climbName = pick.item.name,
                setter = pick.item.setter,
                gradeLabel = pick.item.gradeLabel,
                difficulty = pick.item.difficulty,
                statusRaw = KilterPlanItemStatus.PENDING.name,
            )
        }

    /**
     * Resolve a logged ascent against the plan: flip the lowest-order still-`pending` item for this
     * climb to sent/attempted. Logging a climb that isn't a pending pick leaves the plan unchanged
     * (ad-hoc / already-resolved) — **except** a later *send* of a climb already `attempted` upgrades it.
     */
    fun applyingLog(
        climbUuid: String,
        ascent: KilterAscentStatus,
        atMillis: Long,
        items: List<KilterPlanItem>,
    ): List<KilterPlanItem> {
        val resolved = if (ascent.isSend) KilterPlanItemStatus.SENT else KilterPlanItemStatus.ATTEMPTED
        lowestOrderId(climbUuid, KilterPlanItemStatus.PENDING, items)?.let { id ->
            return items.map {
                if (it.id == id) it.copy(statusRaw = resolved.name, completedAtMillis = atMillis) else it
            }
        }
        if (ascent.isSend) {
            lowestOrderId(climbUuid, KilterPlanItemStatus.ATTEMPTED, items)?.let { id ->
                return items.map {
                    if (it.id == id) it.copy(statusRaw = KilterPlanItemStatus.SENT.name, completedAtMillis = atMillis) else it
                }
            }
        }
        return items
    }

    /** Mark a pick skipped by id (a deliberate pass; it leaves "next up" but isn't done). */
    fun skipping(id: String, items: List<KilterPlanItem>): List<KilterPlanItem> =
        items.map { if (it.id == id) it.copy(statusRaw = KilterPlanItemStatus.SKIPPED.name) else it }

    /** Done-vs-total for the progress header — `done` counts sent + attempted; skipped counts as neither. */
    fun progress(items: List<KilterPlanItem>): Pair<Int, Int> =
        items.count { it.status.isDone } to items.size

    /** The pick to surface as **Next up**: the lowest-order item still `pending`. */
    fun nextPending(items: List<KilterPlanItem>): KilterPlanItem? =
        items.filter { it.status == KilterPlanItemStatus.PENDING }.minByOrNull { it.order }

    /** The still-`pending` picks' climb UUIDs, in plan order — backs the climb screen's "Next pick →". */
    fun pendingClimbUuids(items: List<KilterPlanItem>): List<String> =
        items.filter { it.status == KilterPlanItemStatus.PENDING }.sortedBy { it.order }.map { it.climbUuid }

    /** Whether every pick has resolved (sent / attempted / skipped) — the "Finish plan" nudge. */
    fun allResolved(items: List<KilterPlanItem>): Boolean =
        items.isNotEmpty() && items.all { it.status != KilterPlanItemStatus.PENDING }

    private fun lowestOrderId(climbUuid: String, status: KilterPlanItemStatus, items: List<KilterPlanItem>): String? =
        items.filter { it.climbUuid == climbUuid && it.status == status }.minByOrNull { it.order }?.id
}

/** JSON codec for the embedded plan-items list (the [KilterPlanEntity.itemsJson] column). */
object KilterPlanItemsCodec {
    private val json = Json { ignoreUnknownKeys = true }
    fun encode(items: List<KilterPlanItem>): String = json.encodeToString(items)
    fun decode(text: String): List<KilterPlanItem> =
        runCatching { json.decodeFromString<List<KilterPlanItem>>(text) }.getOrDefault(emptyList())
}
