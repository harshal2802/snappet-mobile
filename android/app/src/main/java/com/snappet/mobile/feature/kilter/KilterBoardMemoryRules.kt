package com.snappet.mobile.feature.kilter

import kotlinx.serialization.Serializable
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * A coarse, on-device place bucket — a lat/long rounded to ~110 m squares (3 decimals) so the app can
 * say "you're at your usual gym" **without ever reverse-geocoding or networking the location**. Stored
 * raw; the value never leaves the device. [matches] gives the pure place-match its test seam. Mirrors
 * the iOS `CoarsePlace`.
 *
 * The constructor takes a precise fix and buckets it — there is no way to store a precise coordinate, so
 * one can never be persisted by accident. Use [bucket] to create one from a raw lat/lon.
 *
 * Serialized for persistence via [CoarsePlaceSurrogate] (an explicit `@Serializable` DTO): the private
 * constructor invariant is preserved because storage only ever round-trips the **already-bucketed**
 * lat/lon — re-bucketing a value that is already at [DECIMALS] places is idempotent, so a precise fix
 * can never sneak in through the persistence layer either.
 */
@Serializable(with = CoarsePlaceSerializer::class)
data class CoarsePlace private constructor(
    /** Latitude rounded to [DECIMALS] places (the stored bucket — never the precise fix). */
    val lat: Double,
    /** Longitude rounded to [DECIMALS] places. */
    val lon: Double,
) {
    /** Whether a (freshly bucketed) place is the same square as this one — the recall test for an
     *  arrival suggestion. Same square == same gym for this feature's purposes. */
    fun matches(other: CoarsePlace): Boolean = lat == other.lat && lon == other.lon

    companion object {
        /** 3 decimals ≈ 110 m at the equator — fine enough to tell two gyms apart, coarse enough that
         *  the stored value is not a precise location. Fixed so two buckets are comparable for equality. */
        const val DECIMALS = 3

        /** Bucket a raw fix into a coarse place (the ONLY way a place is created). */
        fun bucket(latitude: Double, longitude: Double): CoarsePlace {
            val f = 10.0.pow(DECIMALS)
            return CoarsePlace((latitude * f).roundToLong() / f, (longitude * f).roundToLong() / f)
        }

        /** Reconstruct from already-bucketed values (persistence only). Re-buckets defensively so the
         *  [DECIMALS] invariant holds even if a stored value were ever tampered with — idempotent on a
         *  value that is already coarse. */
        internal fun fromStored(lat: Double, lon: Double): CoarsePlace = bucket(lat, lon)
    }
}

/** The on-the-wire DTO for [CoarsePlace] — a plain `@Serializable` record of the bucketed lat/lon. Kept
 *  separate so [CoarsePlace] keeps its private constructor (no precise fix can be persisted by accident). */
@Serializable
private data class CoarsePlaceSurrogate(val lat: Double, val lon: Double)

/** Maps [CoarsePlace] ↔ [CoarsePlaceSurrogate] so the private-ctor value type can ride in JSON without
 *  exposing a public constructor. Delegates the format wiring to the surrogate's generated serializer. */
internal object CoarsePlaceSerializer : kotlinx.serialization.KSerializer<CoarsePlace> {
    private val delegate = CoarsePlaceSurrogate.serializer()
    override val descriptor = delegate.descriptor
    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: CoarsePlace) =
        encoder.encodeSerializableValue(delegate, CoarsePlaceSurrogate(value.lat, value.lon))
    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): CoarsePlace =
        decoder.decodeSerializableValue(delegate).let { CoarsePlace.fromStored(it.lat, it.lon) }
}

/**
 * Everything this device remembers about one physical board it has connected to before, keyed by the
 * BLE [deviceId] (the peripheral's address — the Android analogue of the iOS `CBPeripheral.identifier`).
 * Plain value type; the pure recall/label rules here read it and [KilterBoardMemoryStore] persists a
 * `Map<deviceId, RememberedBoard>` as a single JSON string. `@Serializable` so it rides in that JSON
 * (the [usualAngle] computed property has no backing field, so it is not serialized). Mirrors the iOS
 * `RememberedBoard` (Codable + UserDefaults).
 */
@Serializable
data class RememberedBoard(
    /** The BLE device address last used to reach this board (the stable per-install key). */
    val deviceId: String,
    /** The `#serial` token parsed from the advertised local name, if any — a cross-check that survives a
     *  reinstall (which can mint a fresh [deviceId] but the board keeps its `#serial`). */
    val serial: String? = null,
    /** The Kilter layout (`kilter.layout`) last used on this board. */
    val layoutId: Int,
    /** The physical board size (`product_size_id`) last used on this board. */
    val sizeId: Int,
    /** Every angle the user has **explicitly confirmed/adjusted** on this board, in order —
     *  [usualAngle]/[KilterBoardMemoryRules.mostFrequentAngle] reads this to pre-select the usual angle. */
    val angleHistory: List<Int> = emptyList(),
    /** A friendly, renameable name shown in the confirm ribbon / Settings ("8×12 Home"). */
    val label: String,
    /** The coarse place this board was last seen at, for the pre-connect arrival suggestion. */
    val coarsePlace: CoarsePlace? = null,
    /** When this board was last connected (epoch millis) — newest-first ordering + serial cross-check. */
    val lastSeen: Long,
) {
    /** The most-frequently-confirmed angle on this board (the pre-select), or null with no history. */
    val usualAngle: Int? get() = KilterBoardMemoryRules.mostFrequentAngle(angleHistory)
}

/**
 * The PURE decision rules behind remembered Kilter boards — serial parsing, the usual-angle pick, the
 * identifier-first/serial-cross-check recall, and the default label. No framework, no persistence, no
 * device: these unit-test in plain JVM tests exactly like [KilterSessionStats]. The persistence layer
 * (a later wave) feeds these a map of [RememberedBoard]s keyed by [RememberedBoard.deviceId]. Mirrors the
 * iOS `KilterBoardMemory` static rules + `KilterPlaceMatcher`.
 */
object KilterBoardMemoryRules {

    /**
     * Parse the `#serial` token out of an Aurora advertised local name of the shape
     * `"<name>#<serial>@<api>"` (e.g. `"Kilter#A1B2C3@3"`). Returns null when there's no `#serial`
     * segment, or when the segment is empty/whitespace. With multiple `#`, the first delimits the serial
     * and the serial runs up to the first `@` (so any later `#` is part of the serial).
     */
    fun serialFromLocalName(name: String?): String? {
        if (name == null) return null
        val hash = name.indexOf('#')
        if (hash < 0) return null
        val afterHash = name.substring(hash + 1)
        val serial = afterHash.substringBefore('@').trim()
        return serial.ifEmpty { null }
    }

    /**
     * The most-frequently-confirmed angle in a history, breaking ties toward the **most recent** of the
     * tied angles (the climber's current habit wins over an equally-old one). Null for an empty history.
     */
    fun mostFrequentAngle(history: List<Int>): Int? {
        if (history.isEmpty()) return null
        val counts = history.groupingBy { it }.eachCount()
        val maxCount = counts.values.max()
        val tied = counts.filterValues { it == maxCount }.keys
        // Among the angles tied at the max count, pick the one that appears latest in history.
        return history.last { it in tied }
    }

    /**
     * Recall a board for an arriving connection. **[deviceId] first** (the stable per-install key); if
     * that misses, fall back to a **serial cross-check** so a board survives a reinstall (which mints a
     * new [deviceId] but the board keeps its `#serial`). When more than one entry shares the serial, pick
     * the **most-recently-seen** one ([RememberedBoard.lastSeen]) so the result is deterministic — the iOS
     * determinism fix. Returns null when nothing matches (a board re-learns itself on first reconnect).
     *
     * @param map remembered boards keyed by [RememberedBoard.deviceId].
     */
    fun recall(map: Map<String, RememberedBoard>, deviceId: String, serial: String? = null): RememberedBoard? {
        map[deviceId]?.let { return it }
        if (!serial.isNullOrEmpty()) {
            return map.values.filter { it.serial == serial }.maxByOrNull { it.lastSeen }
        }
        return null
    }

    /**
     * The best remembered board to suggest for a current coarse place: among boards whose stored place is
     * the **same coarse square**, the most-recently-seen one (so a board you used today wins over an older
     * one at the same gym). Null when nothing matches — the graceful BLE-only fall-through. Mirrors the
     * iOS `KilterPlaceMatcher.suggestion`.
     */
    fun suggestion(place: CoarsePlace, boards: Collection<RememberedBoard>): RememberedBoard? =
        boards.filter { it.coarsePlace?.matches(place) == true }.maxByOrNull { it.lastSeen }

    /**
     * A reasonable default label for a never-renamed board — the serial when known, else a generic
     * "Kilter board". Settings lets the user rename it to "8×12 Home" etc. ([layoutName] is accepted for
     * call-site parity with the iOS signature; the generic fallback is layout-agnostic, as on iOS.)
     */
    fun defaultLabel(layoutName: String?, serial: String?): String =
        if (!serial.isNullOrEmpty()) "Board $serial" else "Kilter board"
}
