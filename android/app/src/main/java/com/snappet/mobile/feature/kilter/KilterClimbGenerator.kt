package com.snappet.mobile.feature.kilter

import kotlin.math.abs
import kotlin.math.exp

/**
 * Supplies model logits for the decode loop. The ONNX session conforms to this ([KilterOrtSession]); tests
 * supply a deterministic stub — so the whole sampler is unit-tested with **no** ONNX Runtime, no model
 * file, no device. Keeps the heavy binary dependency at a thin edge. Mirrors iOS `KilterLogitsProviding`.
 */
interface KilterLogitsProviding {
    /** Vocabulary-length logits for the **last** token of [tokens] (≤ block tokens). */
    fun logits(tokens: List<Int>): FloatArray
}

/** What to generate: size / angle / target grade / matching rule + sampling knobs (web-tool defaults). */
data class KilterGenerateRequest(
    val sizeId: Int,
    val angle: Int,
    val grade: Int,
    val nomatch: Boolean,
    val temperature: Double = 0.9,
    val maxHolds: Int = 20,
    val minHolds: Int = 4,
    val candidates: Int = 1,
)

/** A generated climb: its `frames`, the raw hold token indices, and the model's predicted grade. */
data class KilterGeneratedClimb(
    val frames: String,
    val holdTokens: List<Int>,
    val predictedGrade: Double,
)

class KilterGeneratorException(message: String) : Exception(message)

/**
 * Autoregressive climb sampler — a faithful Kotlin port of the board-explorer's decode (`at`/`rt`/`st`/
 * `nt`). Conditions on `[BOS, SIZE, ANGLE, GRADE, MATCH|NOMATCH]`, samples hold tokens restricted to the
 * board-size mask (never re-using a placement), gates the stop token on a minimum length + a start + a
 * finish, then repairs any missing start/finish → **valid by construction**. Pure (logits via the injected
 * session); deterministic given a fixed RNG. Mirrors iOS `KilterClimbGenerator`.
 */
class KilterClimbGenerator(
    val model: KilterGeneratorModel,
    val session: KilterLogitsProviding,
) {
    /** Best-of-N climb whose predicted grade is closest to target. [rng] yields a value in `[0, 1)`. */
    fun generate(request: KilterGenerateRequest, rng: () -> Double): KilterGeneratedClimb {
        var best: KilterGeneratedClimb? = null
        repeat(maxOf(1, request.candidates)) {
            val holds = sampleHolds(request, rng)
            val grade = predictGrade(model, holds, request.angle, request.nomatch)
            val frames = holds.joinToString("") { "p${model.placementOf[it] ?: 0}r${model.roleOf[it] ?: 0}" }
            val candidate = KilterGeneratedClimb(frames, holds, grade)
            val b = best
            if (b == null || abs(grade - request.grade) < abs(b.predictedGrade - request.grade)) {
                best = candidate
            }
        }
        return best ?: throw KilterGeneratorException("The generator produced no climb. Try again.")
    }

    /** One autoregressive sample → the ordered hold token indices (with start/finish repaired in). */
    private fun sampleHolds(req: KilterGenerateRequest, rng: () -> Double): List<Int> {
        val meta = model.meta
        val mask = meta.sizeMasks[req.sizeId.toString()]
            ?: throw KilterGeneratorException("The model has no hold set for board size ${req.sizeId}.")
        val eos = meta.specials.EOS

        fun token(s: String): Int = model.stoi[s]
            ?: throw KilterGeneratorException("The model doesn't know token “$s” — pick a supported size/angle/grade.")
        val matchToken = if (req.nomatch) meta.specials.NOMATCH else meta.specials.MATCH
        val seq = arrayListOf(
            meta.specials.BOS, token("SIZE_${req.sizeId}"),
            token("ANGLE_${req.angle}"), token("GRADE_${req.grade}"), matchToken,
        )

        val used = HashSet<Int>()
        val out = ArrayList<Int>()
        var hasStart = false
        var hasFinish = false

        for (step in 0 until req.maxHolds) {
            val window = if (seq.size > meta.block) seq.subList(seq.size - meta.block, seq.size) else seq
            val logits = session.logits(window)
            val canStop = hasStart && hasFinish && out.size >= req.minHolds

            val candidates = ArrayList<Int>()
            val weights = ArrayList<Float>()
            for (d in mask) {
                if (d >= logits.size) continue
                if (d == eos) {
                    if (canStop) { candidates.add(d); weights.add((logits[d] / req.temperature).toFloat()) }
                } else {
                    val pid = model.placementOf[d]
                    if (pid != null && !used.contains(pid)) {
                        candidates.add(d); weights.add((logits[d] / req.temperature).toFloat())
                    }
                }
            }
            if (candidates.isEmpty()) break
            val picked = sample(weights, candidates, rng)
            if (picked == eos) break
            seq.add(picked)
            out.add(picked)
            model.placementOf[picked]?.let { used.add(it) }
            model.roleOf[picked]?.let { rid ->
                when (model.roleName[rid]) {
                    "start" -> hasStart = true
                    "finish" -> hasFinish = true
                }
            }
        }
        return finish(out, mask, used, hasStart, hasFinish)
    }

    /** Repair: a climb must have a start and a finish — force-add the lowest-id legal hold of any missing
     *  role (the web tool's "valid by construction" guarantee). */
    private fun finish(out: ArrayList<Int>, mask: List<Int>, used: HashSet<Int>,
                       hasStart: Boolean, hasFinish: Boolean): List<Int> {
        val sortedMask = mask.sorted()
        for ((role, missing) in listOf("start" to !hasStart, "finish" to !hasFinish)) {
            if (!missing) continue
            for (d in sortedMask) {
                if (d == model.meta.specials.EOS) continue
                val pid = model.placementOf[d] ?: continue
                val rid = model.roleOf[d] ?: continue
                if (!used.contains(pid) && model.roleName[rid] == role) {
                    out.add(d); used.add(pid); break
                }
            }
        }
        return out
    }

    companion object {
        /** Temperature-softmax sample (weights already divided by temperature) — numerically stable. */
        fun sample(weights: List<Float>, tokens: List<Int>, rng: () -> Double): Int {
            if (tokens.isEmpty()) return -1
            val maxW = weights.max()
            val exps = DoubleArray(weights.size)
            var sum = 0.0
            for (i in weights.indices) { val e = exp((weights[i] - maxW).toDouble()); exps[i] = e; sum += e }
            var r = rng() * sum
            for (i in exps.indices) { r -= exps[i]; if (r <= 0) return tokens[i] }
            return tokens.last()
        }

        /** The model's predicted grade — the linear estimator from `meta.gradeModel`. Mirrors `st()`. */
        fun predictGrade(model: KilterGeneratorModel, holds: List<Int>, angle: Int, nomatch: Boolean): Double {
            val gm = model.meta.gradeModel
            var v = gm.bias + (if (nomatch) gm.wNomatch else 0.0)
            gm.angleIndex[angle.toString()]?.let { if (it < gm.wAngle.size) v += gm.wAngle[it] }
            for (t in holds) if (t < gm.wHold.size) v += gm.wHold[t]
            return v + gm.yMean
        }
    }
}
