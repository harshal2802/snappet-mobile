package com.snappet.mobile.feature.kilter

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.snappet.mobile.feature.kilter.hr.BleHeartRateSource
import java.util.UUID

/**
 * Tracks the active board session so logged ascents can be grouped in History. A session opens when
 * a board connects (source `"ble"`) or when the user starts one manually, and closes on disconnect.
 * Mirrors the iOS `KilterSessionManager`.
 *
 * Issue #92: optionally drives a [BleHeartRateSource]. When an HR strap is captured during a session,
 * the avg/max/sample-count summary is persisted onto the session row on [end] (additive v5 columns).
 *
 * **Planned session (port of the iOS feature):** owns the plan pinned to the live session
 * ([currentPlanId] + the [planProgress]/[planPendingUuids] caches the chip/strip read). The manager is
 * `remember`-scoped in `KilterRoot`, so on every entry [recover] re-hydrates the open session + its
 * pinned plan from the store (the persisted DB is the source of truth — mirrors iOS recover semantics;
 * the outside-Kilter re-entry surfaces read the DB directly via Flows). Done-state lives on the plan
 * items, never re-derived from logs + the recommender.
 */
class KilterSessionManager(
    private val dao: KilterDao,
    /** Optional — null in tests / on devices without BLE; the session still works without HR. */
    val hr: BleHeartRateSource? = null,
) {
    var currentSessionId by mutableStateOf<String?>(null)
        private set

    /** Epoch millis the current session started; null when none is open. */
    var currentStartMillis by mutableStateOf<Long?>(null)
        private set

    /** The plan pinned to the live session (`KilterPlanEntity.id`); null for an ad-hoc session. */
    var currentPlanId by mutableStateOf<String?>(null)
        private set

    /** Live `(done, total)` of the pinned plan for the re-entry strip; null with no plan. */
    var planProgress by mutableStateOf<Pair<Int, Int>?>(null)
        private set

    /** The pinned plan's pending picks in plan order — backs "Next pick →" without a per-render fetch. */
    var planPendingUuids by mutableStateOf<List<String>>(emptyList())
        private set

    suspend fun start(angle: Int, source: String) {
        if (currentSessionId != null) return
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        dao.insertSession(KilterSession(id = id, startedAt = now, angle = angle, source = source))
        currentSessionId = id
        currentStartMillis = now
        hr?.start(now)
    }

    suspend fun end() {
        val id = currentSessionId ?: return
        val series = hr?.snapshotSeries().orEmpty()
        if (series.isNotEmpty()) {
            val bpms = series.map { it.bpm }
            dao.setSessionHr(id, avgHr = bpms.average().toInt(), maxHr = bpms.max(), count = series.size)
        }
        hr?.stop()
        val now = System.currentTimeMillis()
        dao.endSession(id, now)
        // Close the pinned plan in lockstep — no orphaned open plan rows outliving their session.
        dao.closePlanForSession(id, now)
        currentSessionId = null
        currentStartMillis = null
        clearPlanCaches()
    }

    // MARK: - Planned session

    /**
     * Snapshot + pin a freshly-built plan to the live session and freeze it. Enforces one open plan per
     * session (closes any prior open plan first), persists the new one pinned to the session, and seeds
     * the caches. No-op with no live session.
     */
    suspend fun startPlan(plan: KilterPlanEntity, items: List<KilterPlanItem>) {
        val sid = currentSessionId ?: return
        dao.closePlanForSession(sid, System.currentTimeMillis())   // supersede any prior open plan
        dao.upsertPlan(plan.copy(sessionId = sid, completedAt = null))
        currentPlanId = plan.id
        planProgress = KilterPlanProgress.progress(items)
        planPendingUuids = KilterPlanProgress.pendingClimbUuids(items)
    }

    /**
     * Tick the active plan when a climb is logged: flip the lowest-order matching `pending` item to
     * sent/attempted (a later send upgrades an attempted one). Read off the plan, never re-derived —
     * so a completed send/project pick can't be filtered out. No-op for an ad-hoc/off-plan log.
     */
    suspend fun applyLogToPlan(climbUuid: String, ascent: KilterAscentStatus, atMillis: Long) {
        val sid = currentSessionId ?: return
        val plan = dao.openPlanForSession(sid) ?: return
        val items = KilterPlanItemsCodec.decode(plan.itemsJson)
        val updated = KilterPlanProgress.applyingLog(climbUuid, ascent, atMillis, items)
        if (updated == items) return
        dao.upsertPlan(plan.copy(itemsJson = KilterPlanItemsCodec.encode(updated)))
        currentPlanId = plan.id
        planProgress = KilterPlanProgress.progress(updated)
        planPendingUuids = KilterPlanProgress.pendingClimbUuids(updated)
    }

    /** Skip a pending pick (leaves the "next up" rotation, not counted as done). */
    suspend fun skipPlanItem(id: String) {
        val sid = currentSessionId ?: return
        val plan = dao.openPlanForSession(sid) ?: return
        val items = KilterPlanItemsCodec.decode(plan.itemsJson)
        val updated = KilterPlanProgress.skipping(id, items)
        if (updated == items) return
        dao.upsertPlan(plan.copy(itemsJson = KilterPlanItemsCodec.encode(updated)))
        planProgress = KilterPlanProgress.progress(updated)
        planPendingUuids = KilterPlanProgress.pendingClimbUuids(updated)
    }

    /**
     * The next pick to climb — the pending pick immediately after [excluding] in plan order (so it
     * advances forward even without logging the current climb); falls back to the earliest pending when
     * [excluding] isn't pending. Reads the cached list (no fetch). Mirrors iOS nextPlanClimb(excluding:).
     */
    fun nextPlanClimb(excluding: String?): String? {
        val idx = planPendingUuids.indexOf(excluding)
        return if (idx >= 0) planPendingUuids.getOrNull(idx + 1) else planPendingUuids.firstOrNull()
    }

    /**
     * Re-hydrate from the store on entry: adopt the newest open session (if none is live in memory) and
     * re-pin its open plan. Idempotent; a near-no-op once a session is already live. The persisted DB is
     * the source of truth, so this survives navigating out of and back into Kilter (and a relaunch).
     */
    suspend fun recover() {
        if (currentSessionId == null) {
            val open = dao.openSessions().firstOrNull() ?: run { clearPlanCaches(); return }
            currentSessionId = open.id
            currentStartMillis = open.startedAt
        }
        refreshPlanCaches()
    }

    private suspend fun refreshPlanCaches() {
        val sid = currentSessionId
        val plan = if (sid != null) dao.openPlanForSession(sid) else null
        if (plan == null) { clearPlanCaches(); return }
        val items = KilterPlanItemsCodec.decode(plan.itemsJson)
        currentPlanId = plan.id
        planProgress = KilterPlanProgress.progress(items)
        planPendingUuids = KilterPlanProgress.pendingClimbUuids(items)
    }

    private fun clearPlanCaches() {
        currentPlanId = null
        planProgress = null
        planPendingUuids = emptyList()
    }
}
