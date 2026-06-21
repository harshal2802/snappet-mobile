package com.snappet.mobile

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snappet.mobile.core.SnappetDatabase
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The migration pipeline's baseline (issue #84): a database created from the **committed
 * v4 schema JSON** opens under the current builder — which has NO destructive fallback —
 * with its data intact. Every future version bump extends this test by inserting under
 * the old version and validating through `runMigrationsAndValidate(newVersion, …)`; the
 * committed schemas make that possible at all.
 */
@RunWith(AndroidJUnit4::class)
class MigrationBaselineTest {

    private val dbName = "migration-baseline-test.db"

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        SnappetDatabase::class.java,
        emptyList(),
        FrameworkSQLiteOpenHelperFactory(),
    )

    @Test
    fun v4DataSurvivesOpeningUnderTheCurrentBuilder() {
        // Create a store from the committed v4 schema JSON and put real data in it.
        helper.createDatabase(dbName, 4).use { db ->
            db.execSQL(
                "INSERT INTO journal_entries (title, body, tags, createdAt, updatedAt) " +
                    "VALUES ('Morning', 'Climbed.', 'climbing', 5, 6)"
            )
        }

        // Open it the way the app does — no fallbackToDestructiveMigration anywhere —
        // and the row must still be there.
        val db = androidx.room.Room.databaseBuilder(
            InstrumentationRegistry.getInstrumentation().targetContext,
            SnappetDatabase::class.java, dbName,
        ).build()
        try {
            val titles = db.openHelper.readableDatabase
                .query("SELECT title FROM journal_entries").use { cursor ->
                    generateSequence { if (cursor.moveToNext()) cursor.getString(0) else null }.toList()
                }
            assertEquals(listOf("Morning"), titles)
        } finally {
            db.close()
            InstrumentationRegistry.getInstrumentation().targetContext.deleteDatabase(dbName)
        }
    }

    /**
     * Issue #92: the v4 → v5 AutoMigration is non-destructive — a kilter_session row inserted under v4
     * survives the migration with its data intact, and the three new nullable HR columns appear (null
     * for pre-existing rows). Validated via `runMigrationsAndValidate` so the committed v5 schema and
     * the generated AutoMigration agree.
     *
     * NOTE FOR REVIEWER: when Wave 2's independent v5 (workout columns) is renumbered to v6, bump the
     * target version here to 6 too (this test stays the proof that the kilter HR columns migrate cleanly).
     */
    @Test
    fun v4ToV5_addsHrColumns_nonDestructively() {
        val migName = "migration-v5-test.db"
        helper.createDatabase(migName, 4).use { db ->
            db.execSQL(
                "INSERT INTO kilter_session (id, startedAt, endedAt, angle, source) " +
                    "VALUES ('s1', 100, 200, 40, 'ble')"
            )
        }
        // Validate the AutoMigration to v5; Room verifies the resulting schema matches 5.json.
        helper.runMigrationsAndValidate(migName, 5, true).use { db ->
            db.query("SELECT id, angle, avgHr, maxHr, hrSampleCount FROM kilter_session").use { c ->
                assertEquals(true, c.moveToFirst())
                assertEquals("s1", c.getString(0))
                assertEquals(40, c.getInt(1))
                // New columns exist and are NULL for the pre-existing row.
                assertEquals(true, c.isNull(2))
                assertEquals(true, c.isNull(3))
                assertEquals(true, c.isNull(4))
            }
        }
        InstrumentationRegistry.getInstrumentation().targetContext.deleteDatabase(migName)
    }

    /**
     * Kilter Wave B (P4 + P5): the v6 → v7 AutoMigration is non-destructive and covers BOTH additive
     * changes in one step — a kilter_session row inserted under v6 survives with its data intact and gains
     * the three new nullable columns (title/notes/layoutId, null for pre-existing rows), AND the new
     * `kilter_lit_event` table is created and writable. Validated via `runMigrationsAndValidate` so the
     * committed v7 schema and the generated AutoMigration agree.
     */
    @Test
    fun v6ToV7_addsSessionMetadataAndLitEventTable_nonDestructively() {
        val migName = "migration-v7-test.db"
        helper.createDatabase(migName, 6).use { db ->
            db.execSQL(
                "INSERT INTO kilter_session (id, startedAt, endedAt, angle, source) " +
                    "VALUES ('s1', 100, 200, 40, 'ble')"
            )
        }
        // Validate the AutoMigration to v7; Room verifies the resulting schema matches 7.json.
        helper.runMigrationsAndValidate(migName, 7, true).use { db ->
            // P4: the three new nullable columns exist and are NULL for the pre-existing session row.
            db.query("SELECT id, angle, title, notes, layoutId FROM kilter_session").use { c ->
                assertEquals(true, c.moveToFirst())
                assertEquals("s1", c.getString(0))
                assertEquals(40, c.getInt(1))
                assertEquals(true, c.isNull(2))
                assertEquals(true, c.isNull(3))
                assertEquals(true, c.isNull(4))
            }
            // P5: the new table exists and accepts a row.
            db.execSQL(
                "INSERT INTO kilter_lit_event " +
                    "(climbUuid, climbName, gradeLabel, angle, layoutId, sizeId, litAt, wasConnected, sessionId) " +
                    "VALUES ('k1', 'Crimp city', 'V5', 40, 1, 7, 300, 1, 's1')"
            )
            db.query("SELECT climbUuid, litAt FROM kilter_lit_event").use { c ->
                assertEquals(true, c.moveToFirst())
                assertEquals("k1", c.getString(0))
                assertEquals(300L, c.getLong(1))
            }
        }
        InstrumentationRegistry.getInstrumentation().targetContext.deleteDatabase(migName)
    }
}
