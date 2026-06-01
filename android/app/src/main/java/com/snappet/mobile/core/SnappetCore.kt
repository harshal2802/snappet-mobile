package com.snappet.mobile.core

/**
 * Thin wrapper over the shared Room store exposing the usage-logging API every mini-app
 * calls, plus aggregation helpers for the dashboard. Reached via [AppContainer.core].
 * On-device only — nothing is transmitted.
 */
class SnappetCore(private val dao: UsageDao) {

    /** Record a usage event. Call this from any mini-app on a meaningful action. */
    suspend fun log(module: String, action: String, summary: String, metric: Double? = null) {
        dao.insert(UsageRecord(module = module, action = action, summary = summary, metric = metric))
    }

    /** Reactive stream of all usage records (newest first) — drives the Home dashboard. */
    fun allFlow() = dao.allFlow()

    /** Most-recent records (activity feed). */
    suspend fun recent(limit: Int = 40): List<UsageRecord> = dao.recent(limit)

    /** Records on/after `since` epoch millis (for day/week aggregation). */
    suspend fun records(since: Long): List<UsageRecord> = dao.since(since)
}
