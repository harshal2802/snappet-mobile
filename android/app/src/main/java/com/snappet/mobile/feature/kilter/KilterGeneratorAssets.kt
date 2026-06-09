package com.snappet.mobile.feature.kilter

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Default host for the generator assets — the board-explorer's `climb-generator/` dir (same host the
 *  catalog downloads from; #42 user-hosted posture). One GET each for manifest/model/meta; nothing uploaded. */
const val KILTER_GENERATOR_HOST = "https://harshal2802.github.io/Snappet/climb-generator/"

/** The host's `manifest.json` — available generator models; the app installs the `default` one. */
@Serializable
data class KilterGeneratorManifest(val default: String, val models: List<Entry>) {
    @Serializable
    data class Entry(
        val id: String,
        val label: String,
        val model: String,
        val meta: String,
        val sizeBytes: Long? = null,
        val description: String? = null,
    )
}

/**
 * Lazy-downloads + caches the on-device generator's model + meta (~9 MB `model.q.onnx` + `meta.json`) into
 * app storage, so the binary stays slim and the model is updatable host-side. [ensureInstalled] is
 * idempotent. No ONNX here (Foundation/HTTP only). Mirrors iOS `KilterGeneratorAssets`.
 */
class KilterGeneratorAssets(context: Context, private val baseUrl: String = KILTER_GENERATOR_HOST) {
    private val dir = File(context.filesDir, "kilter-generator").apply { mkdirs() }
    val modelFile = File(dir, "model.onnx")
    val metaFile = File(dir, "meta.json")
    private val json = Json { ignoreUnknownKeys = true }

    val isInstalled: Boolean get() = modelFile.exists() && metaFile.exists()

    /** Ensure the model + meta are cached, downloading on first use; returns the decoded model. [progress] 0→1. */
    suspend fun ensureInstalled(progress: (Float) -> Unit = {}): KilterGeneratorModel = withContext(Dispatchers.IO) {
        if (isInstalled) {
            progress(1f)
            return@withContext KilterGeneratorModel.parse(metaFile.readText())
        }
        val manifest = fetchManifest()
        val entry = manifest.models.firstOrNull { it.id == manifest.default }
            ?: manifest.models.firstOrNull()
            ?: throw KilterGeneratorException("The generator manifest had no models.")
        download(entry.meta, metaFile) { progress(it * 0.05f) }
        download(entry.model, modelFile) { progress(0.05f + it * 0.95f) }
        progress(1f)
        KilterGeneratorModel.parse(metaFile.readText())
    }

    fun remove() {
        modelFile.delete()
        metaFile.delete()
    }

    private fun fetchManifest(): KilterGeneratorManifest {
        val conn = URL(baseUrl + "manifest.json").openConnection() as HttpURLConnection
        conn.connectTimeout = 30_000; conn.readTimeout = 60_000
        try {
            if (conn.responseCode !in 200..299) {
                throw KilterGeneratorException("Couldn't reach the generator host (HTTP ${conn.responseCode}).")
            }
            return json.decodeFromString(KilterGeneratorManifest.serializer(), conn.inputStream.bufferedReader().readText())
        } finally {
            conn.disconnect()
        }
    }

    /** Stream a file to [dest] with progress (atomic-ish swap via a `.part` temp). */
    private fun download(name: String, dest: File, progress: (Float) -> Unit) {
        val conn = URL(baseUrl + name).openConnection() as HttpURLConnection
        conn.connectTimeout = 30_000; conn.readTimeout = 120_000
        try {
            if (conn.responseCode !in 200..299) {
                throw KilterGeneratorException("Couldn't reach the generator host (HTTP ${conn.responseCode}).")
            }
            val total = conn.contentLengthLong
            val tmp = File(dest.path + ".part")
            conn.inputStream.use { input ->
                tmp.outputStream().use { output ->
                    val buf = ByteArray(1 shl 16)
                    var received = 0L
                    var n: Int
                    while (input.read(buf).also { n = it } >= 0) {
                        output.write(buf, 0, n)
                        received += n
                        if (total > 0) progress((received.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
            if (tmp.length() == 0L) throw KilterGeneratorException("The download was empty. Try again.")
            dest.delete()
            if (!tmp.renameTo(dest)) throw KilterGeneratorException("Couldn't save the model on this device.")
        } finally {
            conn.disconnect()
        }
    }
}
