package com.snappet.mobile.feature.kilter

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID

/**
 * Tracks the active board session so logged ascents can be grouped in History. A session opens when
 * a board connects (source `"ble"`) or when the user starts one manually, and closes on disconnect.
 * Mirrors the iOS `KilterSessionManager`.
 */
class KilterSessionManager(private val dao: KilterDao) {
    var currentSessionId by mutableStateOf<String?>(null)
        private set

    suspend fun start(angle: Int, source: String) {
        if (currentSessionId != null) return
        val id = UUID.randomUUID().toString()
        dao.insertSession(KilterSession(id = id, startedAt = System.currentTimeMillis(), angle = angle, source = source))
        currentSessionId = id
    }

    suspend fun end() {
        val id = currentSessionId ?: return
        dao.endSession(id, System.currentTimeMillis())
        currentSessionId = null
    }
}
