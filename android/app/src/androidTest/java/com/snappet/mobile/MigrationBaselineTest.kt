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
}
