package com.snappet.mobile.feature.kilter

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.LongBuffer
import kotlin.random.Random

/**
 * The ONNX Runtime edge — the **only** file that imports `ai.onnxruntime`. Wraps an [OrtSession] over the
 * downloaded `model.onnx` and exposes it as a [KilterLogitsProviding], so the pure decode loop
 * ([KilterClimbGenerator]) never touches the binary dependency. The model takes a single int64 `tokens`
 * input `[1, block]` (sequence left-packed, the rest `pad`) and returns `logits` `[1, block, vocab]`; we
 * read the slice at the last real token's position. Mirrors iOS `KilterORTSession`.
 */
class KilterOrtSession(modelFile: File, private val block: Int, private val pad: Int) :
    KilterLogitsProviding, AutoCloseable {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession = env.createSession(modelFile.absolutePath, OrtSession.SessionOptions())

    override fun logits(tokens: List<Int>): FloatArray {
        // Left-pack the sequence into a block-length int64 buffer, the rest filled with `pad`.
        val buf = LongArray(block) { pad.toLong() }
        val n = minOf(tokens.size, block)
        for (i in 0 until n) buf[i] = tokens[i].toLong()

        OnnxTensor.createTensor(env, LongBuffer.wrap(buf), longArrayOf(1, block.toLong())).use { input ->
            session.run(mapOf("tokens" to input)).use { result ->
                val value = result.get("logits").orElseThrow {
                    KilterGeneratorException("Model produced no logits output.")
                }.value
                // 3D float tensor → float[1][block][vocab].
                @Suppress("UNCHECKED_CAST")
                val seq = (value as Array<Array<FloatArray>>)[0]
                val pos = (n - 1).coerceAtLeast(0)
                return seq[pos]
            }
        }
    }

    override fun close() = session.close()
}

/**
 * Owns the (heavy, single-threaded) ONNX session and runs generation off the main thread. Creates the
 * session once and reuses it across "Generate another" taps, serialized by a [Mutex]; returns only the
 * value-type result. Mirrors iOS's `KilterGeneratorRuntime` actor.
 */
class KilterGeneratorRuntime(
    private val model: KilterGeneratorModel,
    private val modelFile: File,
) {
    private var ort: KilterOrtSession? = null
    private val mutex = Mutex()

    suspend fun generate(request: KilterGenerateRequest): KilterGeneratedClimb = withContext(Dispatchers.Default) {
        mutex.withLock {
            val session = ort ?: KilterOrtSession(modelFile, model.meta.block, model.meta.pad).also { ort = it }
            KilterClimbGenerator(model, session).generate(request) { Random.nextDouble() }
        }
    }

    fun close() {
        ort?.close()
        ort = null
    }
}
