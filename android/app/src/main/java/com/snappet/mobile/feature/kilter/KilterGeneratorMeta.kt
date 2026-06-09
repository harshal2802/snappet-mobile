package com.snappet.mobile.feature.kilter

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The generator's sidecar metadata (`meta.json`) — vocabulary, board-size hold masks, role table and the
 * linear grade model that drive the on-device transformer. Decoded straight from the lazy-downloaded file;
 * identical to what the board-explorer web tool ships, so on-device generation matches it. Pure value type
 * → unit-tested. Mirrors iOS `KilterGeneratorMeta`. (`ignoreUnknownKeys` skips fields we don't need, e.g.
 * `placements`/`sizeNames`.)
 */
@Serializable
data class KilterGeneratorMeta(
    val block: Int,
    val pad: Int,
    val specials: Specials,
    val firstHoldId: Int,
    /** Index → token string. Hold tokens are `HOLD_<placementId>_<roleId>`. */
    val itos: List<String>,
    val sizes: List<Size>,
    val roles: List<Role>,
    /** `"<sizeId>" → [allowed token indices]` (includes EOS + that size's hold tokens). */
    val sizeMasks: Map<String, List<Int>>,
    val gradeModel: GradeModel,
    val grades: List<Int>,
    val gradeLabels: Map<String, String>,
    val angles: List<Int>,
    val defaultSize: Int,
) {
    @Serializable
    data class Specials(val BOS: Int, val EOS: Int, val PAD: Int, val MATCH: Int, val NOMATCH: Int)

    @Serializable
    data class Size(val id: Int, val name: String, val box: List<Int>)

    @Serializable
    data class Role(val id: Int, val name: String, val color: String)

    /** Linear grade estimator `bias + w_nomatch·nomatch + w_angle[angle] + Σ w_hold[token] + y_mean`. */
    @Serializable
    data class GradeModel(
        @SerialName("w_hold") val wHold: List<Double>,
        @SerialName("w_angle") val wAngle: List<Double>,
        @SerialName("w_nomatch") val wNomatch: Double,
        val bias: Double,
        @SerialName("angle_index") val angleIndex: Map<String, Int>,
        @SerialName("y_mean") val yMean: Double,
        @SerialName("first_hold_id") val firstHoldId: Int,
    )

    companion object {
        val json = Json { ignoreUnknownKeys = true }
        fun parse(text: String): KilterGeneratorMeta = json.decodeFromString(serializer(), text)
    }
}

/**
 * A [KilterGeneratorMeta] plus the lookup maps the decode loop needs, precomputed once (read in a hot
 * per-token loop). The web tool's `tt()` prep step. Mirrors iOS `KilterGeneratorModel`.
 */
class KilterGeneratorModel(val meta: KilterGeneratorMeta) {
    /** token string → index. */
    val stoi: Map<String, Int>
    /** hold-token index → placementId. */
    val placementOf: Map<Int, Int>
    /** hold-token index → roleId. */
    val roleOf: Map<Int, Int>
    /** roleId → role name. */
    val roleName: Map<Int, String>

    init {
        val stoi = HashMap<String, Int>(meta.itos.size)
        val placementOf = HashMap<Int, Int>()
        val roleOf = HashMap<Int, Int>()
        meta.itos.forEachIndexed { i, s ->
            stoi[s] = i
            if (s.startsWith("HOLD_")) {
                val parts = s.split('_')
                if (parts.size == 3) {
                    val p = parts[1].toIntOrNull()
                    val r = parts[2].toIntOrNull()
                    if (p != null && r != null) { placementOf[i] = p; roleOf[i] = r }
                }
            }
        }
        this.stoi = stoi
        this.placementOf = placementOf
        this.roleOf = roleOf
        this.roleName = meta.roles.associate { it.id to it.name }
    }

    /** The board sizes this model supports, as the app's [KilterBoardSize] (for the Generate pickers). */
    val boardSizes: List<KilterBoardSize>
        get() = meta.sizes.map { KilterBoardSize(it.id, it.name, "", null) }

    /** Grade label for a model grade index (e.g. 17 → "6a/V3"), falling back to the raw number. */
    fun gradeLabel(grade: Int): String = meta.gradeLabels[grade.toString()] ?: grade.toString()

    companion object {
        fun parse(text: String): KilterGeneratorModel = KilterGeneratorModel(KilterGeneratorMeta.parse(text))
    }
}
