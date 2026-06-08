package com.snappet.mobile

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snappet.mobile.feature.kilter.CatalogFilter
import com.snappet.mobile.feature.kilter.HostedCatalogClient
import com.snappet.mobile.feature.kilter.KilterFilter
import com.snappet.mobile.feature.kilter.KilterSizeBox
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

    /**
     * Board-size LED selection: each `product_size` addresses its LEDs differently, so holds(sizeId)
     * must use the *selected* size — another size's positions light wrong/shifted holds (the real-board
     * bug). Also proves the board uses `led_color`, not the on-screen `screen_color`. Mirrors iOS.
     */
    @Test
    fun boardSizeSelectsLedMapAndUsesLedColor() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            assertEquals(listOf(1, 2, 3), cat.sizes(1).map { it.id }.sorted())
            assertEquals(1, cat.defaultSizeId(1))

            val climb = cat.climb("11111111-1111-4111-8111-111111111111")!!
            val s1 = cat.holds(climb, 1).mapNotNull { it.ledPosition }.sorted()
            val s2 = cat.holds(climb, 2).mapNotNull { it.ledPosition }.sorted()
            assertEquals(listOf(1, 13, 25), s1)
            assertEquals(listOf(1001, 1013, 1025), s2)
            // An unset (0) or stale (foreign) size falls back to the layout's smallest — deterministic.
            assertEquals(s1, cat.holds(climb, 0).mapNotNull { it.ledPosition }.sorted())
            assertEquals(s1, cat.holds(climb, 999).mapNotNull { it.ledPosition }.sorted())

            val start = cat.holds(climb, 1).first { it.role == "start" }
            assertEquals("00DD00", start.colorHex)   // on-screen render keeps screen_color
            assertEquals("00FF00", start.ledColorHex) // board payload uses led_color
        } finally {
            store.clear()
            KilterCatalog.reset()
        }
    }

    /**
     * Regression / parity: a catalog lacking the (non-required) product_sizes table must DEGRADE to
     * bare ids in sizes(), not crash — Android's rawQuery throws on a missing table where iOS's query()
     * silently yields none. Guards the size-lookup try/catch. Mirrors iOS
     * testSizesDegradeWhenProductSizesTableAbsent.
     */
    @Test
    fun sizesDegradeWhenProductSizesTableAbsent() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        // Drop product_sizes to simulate the older-catalog case (still valid — it isn't required).
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use {
            it.execSQL("DROP TABLE product_sizes")
        }
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            // Degrades to bare ids from product_sizes_layouts_sets instead of crashing.
            assertEquals(listOf(1, 2, 3), cat.sizes(1).map { it.id }.sorted())
            val climb = cat.climb("11111111-1111-4111-8111-111111111111")!!
            assertEquals(listOf(1001, 1013, 1025), cat.holds(climb, 2).mapNotNull { it.ledPosition }.sorted())
        } finally {
            store.clear()
            KilterCatalog.reset()
        }
    }

    /**
     * The on-screen board tracks the **selected size**: boardGeometry(layoutId, sizeId) renders only the
     * holes wired for that product_size, so a smaller board reads shorter (fewer holes, taller aspect),
     * and the lit holds normalize to the same extent. Fixture size 3 (5×3) wires the bottom three rows;
     * sizes 1/2 (5×5) wire all 25. Mirrors iOS testBoardGeometryAndHoldsTrackSelectedSize.
     */
    @Test
    fun boardGeometryAndHoldsTrackSelectedSize() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            val full = cat.boardGeometry(1, 1)   // 5×5
            val mini = cat.boardGeometry(1, 3)   // 5×3 (bottom three rows)
            assertEquals(25, full.grid.size)
            assertEquals(15, mini.grid.size)
            assertEquals(1.0, full.aspect, 0.001)   // 16/16
            assertEquals(2.0, mini.aspect, 0.001)   // 16/8
            // sizeId 0 = whole layout; an invalid size falls back to the whole layout (no crash).
            assertEquals(25, cat.boardGeometry(1, 0).grid.size)
            assertEquals(25, cat.boardGeometry(1, 999).grid.size)
            // Holds line up with the grid: Alpha's top hole (placement 25, above the 5×3 board) clamps
            // to the mini board's top edge (view y 0); its bottom hole (placement 1) sits on the floor.
            val climb = cat.climb("11111111-1111-4111-8111-111111111111")!!
            val mh = cat.holds(climb, 3)
            assertEquals(0.0, mh.first { it.placementId == 25 }.y, 0.001)
            assertEquals(1.0, mh.first { it.placementId == 1 }.y, 0.001)
            // Holds line up with the grid: at full size every lit hold coincides with a grid hole.
            for (h in cat.holds(climb, 1)) {
                assertTrue("lit hold ${h.placementId} must coincide with a grid hole",
                    full.grid.any { kotlin.math.abs(it.x - h.x) < 0.001 && kotlin.math.abs(it.y - h.y) < 0.001 })
            }
            // Off-diagonal hold (Charlie's placement 3 = board (12,4) → x 0.5, y 1.0) pins x vs an x<->y swap.
            val charlie = cat.climb("33333333-3333-4333-8333-333333333333")!!
            val p3 = cat.holds(charlie, 1).first { it.placementId == 3 }
            assertEquals(0.5, p3.x, 0.001)
            assertEquals(1.0, p3.y, 0.001)
        } finally {
            store.clear()
            KilterCatalog.reset()
        }
    }

    private fun installFixture(store: KilterCatalogStore, name: String, atMillis: Long): String {
        val f = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(f)
        val id = store.install(f, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", atMillis, name))
        f.delete()
        return id
    }

    @Test
    fun libraryHoldsMultipleNewestActive() {
        val dir = File(ctx.cacheDir, "kilter-lib-${UUID.randomUUID()}")
        val store = KilterCatalogStore(dir)
        val a = installFixture(store, "A", 1000L)
        val b = installFixture(store, "B", 2000L)
        assertEquals(2, store.installed().size)
        assertEquals("B", store.installed().first().meta.name)   // most-recent first
        assertEquals(b, store.activeCatalogId)                    // a fresh install becomes active
        store.setActive(a)
        assertEquals("A", store.metadata()?.name)
        dir.deleteRecursively()
    }

    @Test
    fun removingActiveFallsBackToAnother() {
        val dir = File(ctx.cacheDir, "kilter-lib-${UUID.randomUUID()}")
        val store = KilterCatalogStore(dir)
        val a = installFixture(store, "A", 1000L)
        val b = installFixture(store, "B", 2000L)
        assertEquals(b, store.activeCatalogId)
        store.remove(b)
        assertEquals(1, store.installed().size)
        assertEquals(a, store.activeCatalogId)
        store.remove(a)
        assertTrue(store.installed().isEmpty())
        assertFalse(store.isInstalled)
        assertNull(store.activeCatalogId)
        dir.deleteRecursively()
    }

    @Test
    fun filteredBuildFromFixtureReads() {
        val source = KilterCatalogFixture.build(tempFile())
        val out = tempFile()
        HostedCatalogClient().buildFilteredCatalog(
            source.path, CatalogFilter(layoutIds = listOf(1), maxClimbs = 100), out.path)
        assertEquals(4, KilterCatalogValidator.validate(out).climbCount)
        source.delete(); out.delete()
    }

    @Test
    fun filteredBuildCapKeepsTopMostClimbed() {
        val source = KilterCatalogFixture.build(tempFile())
        val out = tempFile()
        HostedCatalogClient().buildFilteredCatalog(
            source.path, CatalogFilter(layoutIds = listOf(1), maxClimbs = 2), out.path)
        assertEquals(2, KilterCatalogValidator.validate(out).climbCount)
        source.delete(); out.delete()
    }

    @Test
    fun filteredBuildEmptyMatchThrows() {
        val source = KilterCatalogFixture.build(tempFile())
        val out = tempFile()
        try {
            assertThrows(KilterCatalogException::class.java) {
                HostedCatalogClient().buildFilteredCatalog(
                    source.path, CatalogFilter(layoutIds = listOf(8)), out.path)
            }
        } finally {
            source.delete(); out.delete()
        }
    }

    /** Board-size filter (mirrors the Board Explorer): the fixture's climbs span [4,20,4,20]; a tall
     *  0..24 box keeps all four, the short Mini box (top 12) fits none. Mirrors iOS. */
    @Test
    fun boardSizeFilterKeepsOnlyFittingClimbs() {
        val source = KilterCatalogFixture.build(tempFile())
        val out = tempFile()
        HostedCatalogClient().buildFilteredCatalog(
            source.path, CatalogFilter(layoutIds = listOf(1), sizeBox = KilterSizeBox(0, 24, 0, 24)), out.path)
        assertEquals(4, KilterCatalogValidator.validate(out).climbCount)
        val out2 = tempFile()
        try {
            assertThrows(KilterCatalogException::class.java) {
                HostedCatalogClient().buildFilteredCatalog(
                    source.path, CatalogFilter(layoutIds = listOf(1), sizeBox = KilterSizeBox(0, 24, 4, 12)), out2.path)
            }
        } finally {
            source.delete(); out.delete(); out2.delete()
        }
    }

    /** Reader surfaces the "No matching" rule (`climbs.is_nomatch`) and each size's fit box
     *  (`product_sizes.edge_*`). Mirrors iOS testClimbNoMatchRuleAndSizeFitBox. */
    @Test
    fun climbNoMatchRuleAndSizeFitBox() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            assertEquals(true, cat.climb("22222222-2222-4222-8222-222222222222")?.isNoMatch)
            assertEquals("No matching", cat.climb("22222222-2222-4222-8222-222222222222")?.description)
            assertEquals(false, cat.climb("11111111-1111-4111-8111-111111111111")?.isNoMatch)
            val sizes = cat.sizes(1)
            assertEquals(KilterSizeBox(0, 24, 0, 24), sizes.first { it.id == 1 }.box)
            assertEquals(KilterSizeBox(0, 24, 4, 12), sizes.first { it.id == 3 }.box)
        } finally {
            store.clear(); KilterCatalog.reset()
        }
    }

    /** The live browse count: count() reflects the full filter + search. Mirrors iOS testCountReflectsFilterAndSearch. */
    @Test
    fun countReflectsFilterAndSearch() {
        val store = KilterCatalogStore.get(ctx)
        val file = KilterCatalogFixture.build(tempFile())
        val v = KilterCatalogValidator.validate(file)
        store.install(file, KilterCatalogMeta(v.version, v.climbCount, v.sizeBytes, "Test", 0L))
        file.delete()
        try {
            KilterCatalog.reset()
            val cat = KilterCatalog.get(ctx)
            val base = KilterFilter(1, 40, 1.0, 39.0)
            assertEquals(4, cat.count(base))
            assertEquals(cat.list(base).size, cat.count(base))
            assertEquals(1, cat.count(base.copy(search = "Bravo")))
            assertEquals(2, cat.count(KilterFilter(1, 25, 1.0, 39.0)))
            assertEquals(1, cat.count(base.copy(minDifficulty = 22.0)))
        } finally {
            store.clear(); KilterCatalog.reset()
        }
    }
}
