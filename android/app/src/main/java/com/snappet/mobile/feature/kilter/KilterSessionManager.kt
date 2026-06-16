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
 * The session start millis is tracked so the detail screen can compute the duration for an open
 * session and anchor HR sample offsets.
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

    suspend fun start(angle: Int, source: String) {
        if (currentSessionId != null) return
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        dao.insertSession(KilterSession(id = id, startedAt = now, angle = angle, source = source))
        currentSessionId = id
        currentStartMillis = now
        // Begin live HR capture (no-op on devices without BLE / when the strap never appears).
        hr?.start(now)
    }

    suspend fun end() {
        val id = currentSessionId ?: return
        // Flush the captured HR summary onto the session before closing it.
        val series = hr?.snapshotSeries().orEmpty()
        if (series.isNotEmpty()) {
            val bpms = series.map { it.bpm }
            dao.setSessionHr(id, avgHr = bpms.average().toInt(), maxHr = bpms.max(), count = series.size)
        }
        hr?.stop()
        dao.endSession(id, System.currentTimeMillis())
        currentSessionId = null
        currentStartMillis = null
    }
}
