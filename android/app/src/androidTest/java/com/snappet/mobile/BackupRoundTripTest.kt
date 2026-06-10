package com.snappet.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snappet.mobile.core.SnappetBackup
import com.snappet.mobile.core.SnappetBackupManager
import com.snappet.mobile.core.SnappetDatabase
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.journal.JournalEntry
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Issue #84's round-trip acceptance criterion: export → wipe → import → every module
 * reads identical data. Runs against an in-memory Room store on the device/emulator;
 * the JSON leg goes through the real codec so this covers exactly what a SAF file holds.
 */
@RunWith(AndroidJUnit4::class)
class BackupRoundTripTest {

    @Test
    fun exportWipeImportRestoresEveryModule() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val db = SnappetDatabase.buildInMemory(context)
        try {
            // Seed a few modules (different storage classes: text, ints, reals, nulls).
            db.usageDao().insert(UsageRecord(module = "tip", action = "calc",
                summary = "Tipped", metric = 12.5, timestamp = 111))
            db.journalDao().insert(JournalEntry(title = "Morning", body = "Climbed.",
                tags = "climbing,trip", createdAt = 5, updatedAt = 6))
            db.pomodoroDao().insert(PomodoroSession(minutes = 25, completedAt = 7))
            db.habitDao().insertHabit(Habit(habitId = "h-1", name = "Stretch", createdAt = 1))
            db.habitDao().insertCompletion(HabitCompletion(habitId = "h-1", day = 2))

            val manager = SnappetBackupManager(db)
            val exported = manager.exportPayload(nowMillis = 999)
            val json = SnappetBackup.encode(exported)        // the real SAF file content

            // Wipe: import an empty payload of the same schema version…
            val empty = exported.copy(tables = exported.tables.mapValues { emptyList() })
            manager.importPayload(empty)
            assertTrue(db.journalDao().allFlow().first().isEmpty())

            // …then restore from the JSON and compare what every module reads.
            manager.importPayload(SnappetBackup.decode(json))

            val journal = db.journalDao().allFlow().first()
            assertEquals(1, journal.size)
            assertEquals("Morning", journal[0].title)
            assertEquals(listOf("climbing", "trip"), journal[0].tagList)

            val pomodoro = db.pomodoroDao().allFlow().first()
            assertEquals(listOf(25), pomodoro.map { it.minutes })

            val habits = db.habitDao().habitsFlow().first()
            assertEquals(listOf("Stretch"), habits.map { it.name })

            // Re-export must equal the first export — proves import lost nothing.
            val reExported = manager.exportPayload(nowMillis = 999)
            assertEquals(exported.tables, reExported.tables)
        } finally {
            db.close()
        }
    }
}
