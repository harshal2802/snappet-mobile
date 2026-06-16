package com.snappet.mobile.feature.kilter

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * A tiny process-wide hand-off for a `snappet://kilter/climb/<uuid>?angle=<n>` deep link (issue #91).
 * The app shell routes into the Kilter module and parks the target here; [KilterRoot] observes it on
 * entry, opens the climb at the encoded angle, then clears it. Kept separate from the generic
 * [com.snappet.mobile.core.SuiteRouter] so the module owns its own intra-module navigation.
 */
object KilterDeepLinkBus {
    /** The pending (uuid, angle) to open, or null. */
    var pending by mutableStateOf<Pair<String, Int?>?>(null)
        private set

    fun request(uuid: String, angle: Int?) { pending = uuid to angle }
    fun consume() { pending = null }

    /** Pending "open the plan-home" intent (the Home "Resume climbing session" card). */
    var pendingPlan by mutableStateOf(false)
        private set

    fun requestPlan() { pendingPlan = true }
    fun consumePlan() { pendingPlan = false }
}
