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
    /** Library name for the installed catalog (Settings list). Defaults to [displayName]. */
    val catalogName: String get() = displayName
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
 * **Phase 2 — hosted-dataset download.** Fetches a board's catalog (gzipped SQLite) from a static host
 * the user controls (the Snappet Board Explorer Pages site by default), trims it on-device with the
 * chosen filters, and hands back a small importable file. Owns the module's only network egress (one GET
 * to the configured host), user-initiated, no analytics, nothing uploaded — see `KilterAuroraSync.kt`
 * for the (narrow, personal-use) legal posture. Mirrors the iOS `HostedCatalogProvider`.
 */
class HostedCatalogProvider(
    private val context: Context,
    private val board: CatalogBoardEntry,
    private val filter: CatalogFilter,
    private val baseURL: String = KILTER_DEFAULT_CATALOG_HOST,
    private val name: String = "",
) : KilterCatalogProvider {
    override val displayName = "${board.label} download"
    override val catalogName = name.ifEmpty { displayName }

    override suspend fun fetch(onProgress: (Float) -> Unit): File =
        HostedCatalogClient(baseURL).buildCatalog(context.cacheDir, board, filter, onProgress)
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
            provider.displayName, System.currentTimeMillis(), provider.catalogName)
        store.install(temp, meta)   // adds + activates a new library entry
        KilterCatalog.reset()       // next get() re-opens the new active catalog
        meta
    } finally {
        if (temp.exists()) temp.delete()
    }
}

/** The whole on-device library (most-recent first). */
fun installedKilterCatalogs(context: Context): List<InstalledCatalog> =
    KilterCatalogStore.get(context).installed()

fun activeKilterCatalogId(context: Context): String? =
    KilterCatalogStore.get(context).activeCatalogId

/** Make a different installed catalog active, then drop the cached reader. */
fun activateKilterCatalog(context: Context, id: String) {
    KilterCatalogStore.get(context).setActive(id)
    KilterCatalog.reset()
}

/** Remove one catalog from the library (promotes another active if needed), then drop the reader. */
fun removeKilterCatalog(context: Context, id: String) {
    KilterCatalogStore.get(context).remove(id)
    KilterCatalog.reset()
}
