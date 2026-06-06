package com.snappet.mobile.feature.kilter

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * The IO edge for getting a catalog onto the device. Everything else in the Kilter module is read-only
 * and source-agnostic; a provider just yields a local `.sqlite3` file already on this device, and
 * [installKilterCatalog] validates + installs it — so the read path never cares where the bytes came
 * from. Mirrors the iOS `KilterCatalogProvider`.
 */
interface KilterCatalogProvider {
    val displayName: String
    suspend fun fetch(onProgress: (Float) -> Unit = {}): File
}

/**
 * **Phase 1 — the shipped path.** The user supplies a `.sqlite3` they built/exported themselves via
 * Storage Access Framework. We copy the picked content to a cache file and hand it back; **nothing is
 * fetched from a network** — the user brings their own data, the cleanest legal posture.
 */
class FileImportProvider(private val context: Context, private val uri: Uri) : KilterCatalogProvider {
    override val displayName = "Imported file"

    override suspend fun fetch(onProgress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val temp = File(context.cacheDir, "kilter-import-${UUID.randomUUID()}.sqlite3")
        context.contentResolver.openInputStream(uri)?.use { input ->
            temp.outputStream().use { input.copyTo(it) }
        } ?: throw KilterCatalogException(KilterCatalogException.Reason.UNREADABLE)
        onProgress(1f)
        temp
    }
}

/**
 * **Phase 2 — NOT shipped.** An inert stub kept so the in-app Aurora sync drops into this exact seam
 * once the endpoint / account / Terms-of-Use open questions in issue #42 are answered. It performs
 * **no** network requests today and the sync button stays disabled. See `pdd/context/decisions.md`.
 */
class AuroraSyncProvider : KilterCatalogProvider {
    override val displayName = "Sync from Kilter"

    override suspend fun fetch(onProgress: (Float) -> Unit): File =
        throw KilterCatalogException(KilterCatalogException.Reason.SYNC_UNAVAILABLE)
}

/**
 * fetch → validate → install for any provider, returning the meta on success. One place owns the
 * "bring a catalog onto the device" flow so the sync screen and Settings "Refresh" can't drift. A
 * failure anywhere leaves any previously-installed catalog untouched; the temp file is always cleaned.
 */
suspend fun installKilterCatalog(
    context: Context,
    provider: KilterCatalogProvider,
    onProgress: (Float) -> Unit = {},
): KilterCatalogMeta = withContext(Dispatchers.IO) {
    val store = KilterCatalogStore.get(context)
    val temp = provider.fetch(onProgress)
    try {
        val validated = KilterCatalogValidator.validate(temp)
        val meta = KilterCatalogMeta(
            validated.version, validated.climbCount, validated.sizeBytes,
            provider.displayName, System.currentTimeMillis())
        store.install(temp, meta)
        KilterCatalog.reset()   // next get() re-opens the new catalog
        meta
    } finally {
        if (temp.exists()) temp.delete()
    }
}
