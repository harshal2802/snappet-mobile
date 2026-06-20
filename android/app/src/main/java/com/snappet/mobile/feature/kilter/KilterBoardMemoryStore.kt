package com.snappet.mobile.feature.kilter

import android.content.Context
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Persists the physical Kilter boards this device has connected to so a return visit **restores the
 * board's layout + size and pre-selects the usual angle** — the Android port of the iOS
 * `KilterBoardMemory`. Backed by SharedPreferences (one JSON string key, matching [KilterSettings] /
 * `PomodoroStateStore`); on-device only, no Room schema / no backup tax.
 *
 * The store keeps a `Map<deviceId, RememberedBoard>` ([RememberedBoard.deviceId] is the BLE address, the
 * Android analogue of `CBPeripheral.identifier`). All decision logic lives in the pure
 * [KilterBoardMemoryRules]; all map↔JSON serialization + mutation lives in the pure [KilterBoardMemoryState]
 * so it unit-tests on the JVM with no Context. This class is the thin SharedPreferences edge that loads,
 * delegates to that pure layer, and saves.
 *
 * Angle is recorded **only on an explicit confirm** ([confirmAngle]) — a plain connect the climber
 * ignores must not reinforce the pre-selected angle (the iOS review fix). [remember] writes identity only.
 */
class KilterBoardMemoryStore(private val context: Context) {

    private fun prefs() = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun load(): Map<String, RememberedBoard> =
        KilterBoardMemoryState.decode(prefs().getString(MAP_KEY, null))

    private fun save(map: Map<String, RememberedBoard>) {
        prefs().edit().putString(MAP_KEY, KilterBoardMemoryState.encode(map)).apply()
    }

    /** Every remembered board, newest-seen first — the order the Settings list + arrival pick use. */
    fun all(): List<RememberedBoard> = KilterBoardMemoryState.sortedByLastSeen(load())

    /**
     * Remember (or update) a board's **identity** on a confirmed connect — layout, size, [lastSeen], and
     * any newly-known serial / coarse place (never clobbering a value we already have). Does **not** touch
     * [RememberedBoard.angleHistory]: the angle is recorded only via [confirmAngle]. Preserves a
     * user-renamed [label] unless an explicit one is passed; a brand-new board gets the default label.
     */
    fun remember(
        deviceId: String,
        layoutId: Int,
        sizeId: Int,
        label: String? = null,
        serial: String? = null,
        coarsePlace: CoarsePlace? = null,
        lastSeen: Long = System.currentTimeMillis(),
    ) = save(
        KilterBoardMemoryState.remembering(
            load(), deviceId, layoutId, sizeId, label, serial, coarsePlace, lastSeen,
        )
    )

    /**
     * Record an angle the user **explicitly confirmed/adjusted** (the ribbon's "Got it"), appending it to
     * [RememberedBoard.angleHistory] so [RememberedBoard.usualAngle] tracks the real habit. The ONLY path
     * that grows the history. No-op for an unknown [deviceId].
     */
    fun confirmAngle(deviceId: String, angle: Int, lastSeen: Long = System.currentTimeMillis()) =
        save(KilterBoardMemoryState.confirmingAngle(load(), deviceId, angle, lastSeen))

    /**
     * Recall a board for an arriving connection — [deviceId] first, serial cross-check as a reinstall
     * fallback. Delegates to [KilterBoardMemoryRules.recall].
     */
    fun recall(deviceId: String, serial: String? = null): RememberedBoard? =
        KilterBoardMemoryRules.recall(load(), deviceId, serial)

    /** Rename a board's friendly label (Settings). No-op for an unknown [deviceId]. */
    fun rename(deviceId: String, label: String) =
        save(KilterBoardMemoryState.renaming(load(), deviceId, label))

    /** Forget a board entirely — the next connect re-remembers it from scratch ("Forget" in Settings). */
    fun forget(deviceId: String) = save(KilterBoardMemoryState.forgetting(load(), deviceId))

    /** The best remembered board to suggest for an arrival at [place]. Delegates to the pure rules. */
    fun suggestion(place: CoarsePlace): RememberedBoard? =
        KilterBoardMemoryRules.suggestion(place, load().values)

    companion object {
        private const val PREFS_NAME = "kilter.boardMemory"
        private const val MAP_KEY = "rememberedBoards"
    }
}

/**
 * The PURE map↔JSON (de)serialization + mutation layer behind [KilterBoardMemoryStore]. Every function
 * takes the current map and returns the next one (or a JSON string), with no Context / no SharedPreferences,
 * so it unit-tests on the JVM with a plain in-memory map — exactly like [KilterBoardMemoryRules] and
 * [KilterPlanItemsCodec]. The store is just the thin SharedPreferences edge that calls these.
 *
 * Mutations mirror the iOS `KilterBoardMemory` semantics: [remembering] writes identity only and never
 * appends an angle; [confirmingAngle] is the sole path that grows [RememberedBoard.angleHistory].
 */
object KilterBoardMemoryState {

    private val json = Json { ignoreUnknownKeys = true }

    /** Encode the remembered-board map to its persisted JSON string. */
    fun encode(map: Map<String, RememberedBoard>): String = json.encodeToString(map)

    /** Decode the persisted JSON string; null / blank / malformed input yields an empty map. */
    fun decode(text: String?): Map<String, RememberedBoard> {
        if (text.isNullOrBlank()) return emptyMap()
        return runCatching { json.decodeFromString<Map<String, RememberedBoard>>(text) }
            .getOrDefault(emptyMap())
    }

    /** Remembered boards, newest-seen first ([RememberedBoard.lastSeen] descending). */
    fun sortedByLastSeen(map: Map<String, RememberedBoard>): List<RememberedBoard> =
        map.values.sortedByDescending { it.lastSeen }

    /**
     * Remember (or update) a board's identity — see [KilterBoardMemoryStore.remember]. Never touches
     * [RememberedBoard.angleHistory]; never drops a previously-known serial / coarse place; preserves a
     * user-renamed label unless an explicit one is passed.
     */
    fun remembering(
        map: Map<String, RememberedBoard>,
        deviceId: String,
        layoutId: Int,
        sizeId: Int,
        label: String?,
        serial: String?,
        coarsePlace: CoarsePlace?,
        lastSeen: Long,
    ): Map<String, RememberedBoard> {
        val existing = map[deviceId]
        val next = if (existing == null) {
            RememberedBoard(
                deviceId = deviceId,
                serial = serial,
                layoutId = layoutId,
                sizeId = sizeId,
                angleHistory = emptyList(),
                label = label ?: KilterBoardMemoryRules.defaultLabel(layoutName = null, serial = serial),
                coarsePlace = coarsePlace,
                lastSeen = lastSeen,
            )
        } else {
            existing.copy(
                layoutId = layoutId,
                sizeId = sizeId,
                label = label ?: existing.label,                                  // explicit rename only
                serial = if (!serial.isNullOrEmpty()) serial else existing.serial, // never drop a known serial
                coarsePlace = coarsePlace ?: existing.coarsePlace,                 // never drop a known place
                lastSeen = lastSeen,
            )
        }
        return map + (deviceId to next)
    }

    /** Append an explicitly-confirmed angle to a board's history; bump [RememberedBoard.lastSeen]. No-op
     *  for an unknown [deviceId]. The ONLY path that grows the angle history. */
    fun confirmingAngle(
        map: Map<String, RememberedBoard>,
        deviceId: String,
        angle: Int,
        lastSeen: Long,
    ): Map<String, RememberedBoard> {
        val board = map[deviceId] ?: return map
        return map + (deviceId to board.copy(angleHistory = board.angleHistory + angle, lastSeen = lastSeen))
    }

    /** Rename a board's label. No-op for an unknown [deviceId]. */
    fun renaming(
        map: Map<String, RememberedBoard>,
        deviceId: String,
        label: String,
    ): Map<String, RememberedBoard> {
        val board = map[deviceId] ?: return map
        return map + (deviceId to board.copy(label = label))
    }

    /** Forget a board entirely. No-op for an unknown [deviceId]. */
    fun forgetting(map: Map<String, RememberedBoard>, deviceId: String): Map<String, RememberedBoard> =
        map - deviceId
}
