package com.snappet.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snappet.mobile.feature.kilter.KilterCatalog
import com.snappet.mobile.feature.kilter.KilterCatalogException
import com.snappet.mobile.feature.kilter.KilterCatalogFixture
import com.snappet.mobile.feature.kilter.KilterCatalogMeta
import com.snappet.mobile.feature.kilter.KilterCatalogStore
import com.snappet.mobile.feature.kilter.KilterCatalogValidator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * Instrumented coverage for the opt-in catalog plumbing (issue #42): the synthetic fixture builds, the
 * validator accepts it / rejects junk with a deterministic version, the store installs/clears with a
 * round-tripped meta, and an installed fixture drives the read-only `KilterCatalog`. Instrumented (not
 * JVM `src/test`) because the store/validator/reader use Android's `SQLiteDatabase`. No Aurora data —
 * every row is authored by `KilterCatalogFixture`.
 */
@RunWith(AndroidJUnit4::class)
class KilterCatalogStoreTest {

    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private fun tempFile() = File(ctx.cacheDir, "kilter-test-${UUID.randomUUID()}.sqlite3")

    @Test
    fun fixtureValidatesWithExpectedCounts() {
        val file = KilterCatalogFixture.build(tempFile())
        try {
            val v = KilterCatalogValidator.validate(file)
            assertEquals(4, v.climbCount)
            assertTrue(v.sizeBytes > 0)
            assertTrue(v.version.isNotEmpty())
        } finally {
            file.delete()
        }
    }

    @Test
    fun versionIsDeterministic() {
        val a = KilterCatalogValidator.validate(KilterCatalogFixture.build(tempFile()))
        val b = KilterCatalogValidator.validate(KilterCatalogFixture.build(tempFile()))
        assertEquals(a.version, b.version)
    }

    @Test
    fun validatorRejectsNonCatalog() {
        val bogus = tempFile().apply { writeText("this is not a sqlite database") }
        try {
            val ex = assertThrows(KilterCatalogException::class.java) {
                KilterCatalogValidator.validate(bogus)
            }
            assertTrue(
                ex.reason == KilterCatalogException.Reason.MISSING_TABLES ||
                    ex.reason == KilterCatalogException.Reason.UNREADABLE)
        } finally {
            bogus.delete()
        }
    }

    @Test
    fun installThenClearRoundTrips() {
        val dir = File(ctx.cacheDir, "kilter-store-${UUID.randomUUID()}")
        val store = KilterCatalogStore(dir)
        assertFalse(store.isInstalled)

        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()

        assertTrue(store.isInstalled)
        assertEquals(4, store.metadata()?.climbCount)
        assertEquals(v.version, store.metadata()?.version)

        store.clear()
        assertFalse(store.isInstalled)
        assertNull(store.metadata())
        dir.deleteRecursively()
    }

    /** Integration: install the fixture into the shared store and confirm the reader browses it. */
    @Test
    fun installedFixtureDrivesTheReader() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            assertTrue(cat.isAvailable)
            assertEquals(1, cat.layouts().size)   // only layout 1 has listed climbs
            val items = cat.list(1, 40, 1.0, 39.0)
            assertEquals(4, items.size)
            val climb = cat.climb(items.first().uuid)!!
            assertTrue(cat.holds(climb).isNotEmpty())
        } finally {
            store.clear()
            KilterCatalog.reset()
        }
    }
}
