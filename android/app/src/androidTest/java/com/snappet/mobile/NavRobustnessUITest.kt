package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.percentOffset
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappet.mobile.core.AppContainer
import com.snappet.mobile.core.TestHooks
import com.snappet.mobile.feature.workout.WorkoutSession
import com.snappet.mobile.feature.workout.WorkoutSessionExercise
import com.snappet.mobile.feature.workout.WorkoutSetLog
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Navigation-robustness coverage for issue #86: system back pops one level inside a module
 * (and can never silently abandon a live workout), module nav state and in-progress drafts
 * survive activity recreation (rotation / process-death analogue via
 * [ActivityScenario.recreate]), tab switches retain module position (RootShell's
 * SaveableStateHolder), and an interrupted workout session (`finishedAt == null`) surfaces
 * a Resume/Discard banner instead of being lost. Mirrors the iOS navigation-robustness work.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class NavRobustnessUITest : SuiteTest() {

    @After
    fun clearHooks() {
        TestHooks.installKilterCatalogFixture = false
        TestHooks.freshInMemoryStore = false
    }

    private fun existsTag(tag: String): Boolean =
        composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()

    /**
     * Launch, then drop the fresh-store hook: MainActivity re-runs `onCreate` on
     * [ActivityScenario.recreate], and with the hook still set it would rebuild a *new* empty
     * in-memory store mid-test instead of reattaching to the one the test has been driving.
     */
    private fun launchForRecreate(): ActivityScenario<MainActivity> {
        val scenario = launch()
        TestHooks.freshInMemoryStore = false
        return scenario
    }

    private fun pressSystemBack() {
        Espresso.pressBack()
        composeRule.waitForIdle()
    }

    /** Routines section → first starter routine → Start Workout → wait for the live player. */
    private fun startFirstRoutine() {
        composeRule.onNodeWithTag("workout.section.Routines").performClick()
        // Starter routines seed asynchronously through Room on first open.
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("routineRow") }
        composeRule.onAllNodesWithTag("routineRow")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("workout.startWorkout").performClick()
        // startWorkout inserts the session row before the player screen swaps in.
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.completeSet") }
    }

    /** Back out of the live player and discard the session via the End dialog. */
    private fun discardLiveWorkout() {
        pressSystemBack()
        composeRule.onNodeWithText("End this workout?").assertIsDisplayed()
        composeRule.onNodeWithText("Discard").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.section.Exercises") }
    }

    @Test
    fun backInsideModulePopsOneLevel() {
        launch()
        openModule("workout-log")

        composeRule.onAllNodesWithTag("exerciseRow")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Category").assertIsDisplayed()

        pressSystemBack()

        // One level up: the workout root, not the App Library.
        composeRule.onNodeWithTag("workout.section.Exercises").assertIsDisplayed()
        composeRule.onNodeWithTag("appLibraryGrid").assertDoesNotExist()
    }

    @Test
    fun backMidWorkoutShowsEndDialogAndNeverSilentlyAbandons() {
        launch()
        openModule("workout-log")
        startFirstRoutine()

        pressSystemBack()
        composeRule.onNodeWithText("End this workout?").assertIsDisplayed()

        // Discard is an explicit finalization: back at the root with nothing left to resume.
        composeRule.onNodeWithText("Discard").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.section.Exercises") }
        composeRule.onNodeWithTag("appLibraryGrid").assertDoesNotExist()
        composeRule.waitUntil(timeoutMillis = 5_000) { !existsTag("workout.resumeBanner") }
    }

    @Test
    fun recreatePreservesJournalDraft() {
        val scenario = launchForRecreate()
        openModule("journal")

        composeRule.onAllNodesWithTag("journal.add").onFirst().performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("journal.titleField").performTextInput("Draft title")
        composeRule.onNodeWithTag("journal.bodyField").performTextInput("Draft body text")

        scenario.recreate()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("journal.titleField").assertTextContains("Draft title")
        composeRule.onNodeWithTag("journal.bodyField").assertTextContains("Draft body text")
    }

    @Test
    fun recreateMidWorkoutRestoresPlayer() {
        val scenario = launchForRecreate()
        openModule("workout-log")
        startFirstRoutine()

        scenario.recreate()
        composeRule.waitForIdle()

        // The player restores (saveable nav + the Room session row), not the dashboard.
        composeRule.waitUntil(timeoutMillis = 8_000) { existsTag("workout.completeSet") }
        composeRule.onNodeWithTag("workout.section.Exercises").assertDoesNotExist()

        discardLiveWorkout()
    }

    @Test
    fun tabSwitchPreservesModulePosition() {
        launch()
        openModule("workout-log")

        composeRule.onNodeWithTag("tab.today").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("tab.apps").performClick()
        composeRule.waitForIdle()

        // Still inside the workout module, not bounced back to the App Library grid.
        composeRule.onNodeWithTag("workout.section.Exercises").assertIsDisplayed()
        composeRule.onNodeWithTag("appLibraryGrid").assertDoesNotExist()
    }

    @Test
    fun resumeBannerResumesInterruptedWorkout() {
        launch()

        // Seed an orphaned active session (finishedAt == null by construction) directly into
        // the live store — AFTER launch so this is the fresh in-memory container the UI uses.
        val container = AppContainer.get(ApplicationProvider.getApplicationContext())
        val exercises = listOf(
            WorkoutSessionExercise(
                exerciseId = "nav-test-exercise",
                targetSets = 1,
                targetReps = "8",
                targetRestSeconds = 0,
                sets = listOf(WorkoutSetLog()),
                displayName = "Interrupted exercise",
            ),
        )
        runBlocking {
            container.database.workoutDao().insertSession(
                WorkoutSession.create(null, "Interrupted Routine", exercises),
            )
        }

        openModule("workout-log")
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.resumeBanner") }
        composeRule.onNodeWithTag("workout.resume").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.completeSet") }

        discardLiveWorkout()
        composeRule.waitUntil(timeoutMillis = 5_000) { !existsTag("workout.resumeBanner") }

        // Banner's own Discard path: seed a second orphan and delete it from the banner.
        runBlocking {
            container.database.workoutDao().insertSession(
                WorkoutSession.create(null, "Second Orphan", exercises),
            )
        }
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.resumeBanner") }
        composeRule.onNodeWithTag("workout.discardActive").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Discard this workout?").assertIsDisplayed()
        composeRule.onNodeWithTag("confirm.delete").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) { !existsTag("workout.resumeBanner") }
    }

    /** Resume must continue at the first incomplete set — never back over already-logged sets,
     *  where Complete-set would silently overwrite the persisted log (issue #86 review). */
    @Test
    fun resumeLandsOnFirstIncompleteSet() {
        launch()

        val container = AppContainer.get(ApplicationProvider.getApplicationContext())
        val done = WorkoutSetLog(actualReps = 8, completedAt = System.currentTimeMillis())
        val exercises = listOf(
            WorkoutSessionExercise(
                exerciseId = "nav-test-finished",
                targetSets = 1,
                targetReps = "8",
                targetRestSeconds = 0,
                sets = listOf(done),
                displayName = "Finished exercise",
            ),
            WorkoutSessionExercise(
                exerciseId = "nav-test-next-up",
                targetSets = 2,
                targetReps = "8",
                targetRestSeconds = 0,
                sets = listOf(done, WorkoutSetLog()),
                displayName = "Next-up exercise",
            ),
        )
        runBlocking {
            container.database.workoutDao().insertSession(
                WorkoutSession.create(null, "Half-done Routine", exercises),
            )
        }

        openModule("workout-log")
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.resumeBanner") }
        composeRule.onNodeWithTag("workout.resume").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) { existsTag("workout.completeSet") }

        // Lands on the second exercise's second set — not back on the finished work.
        composeRule.onNodeWithText("Next-up exercise").assertIsDisplayed()
        composeRule.onNodeWithText("Set 2 of 2").assertIsDisplayed()

        discardLiveWorkout()
        composeRule.waitUntil(timeoutMillis = 5_000) { !existsTag("workout.resumeBanner") }
    }

    @Test
    fun recreatePreservesCreateClimbDraft() {
        TestHooks.installKilterCatalogFixture = true
        val scenario = launchForRecreate()
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 8_000) { existsTag("kilter.more") }

        composeRule.onNodeWithTag("kilter.create").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("kilter.create.name").performTextInput("Recreate Draft")
        placeValidClimb()
        composeRule.onNodeWithTag("kilter.create.valid").performScrollTo().assertIsDisplayed()

        scenario.recreate()
        composeRule.waitForIdle()

        // Name and hold assignments are saveable; validity recomputes once the board geometry
        // reloads from the catalog, so wait for the valid marker rather than asserting cold.
        composeRule.waitUntil(timeoutMillis = 8_000) { existsTag("kilter.create.valid") }
        composeRule.onNodeWithTag("kilter.create.name").assertTextContains("Recreate Draft")
        composeRule.onNodeWithTag("kilter.create.valid").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.create.save").assertIsEnabled()
    }

    /** Draw a valid climb: center hole ×3 → finish; three other holes ×1 → start. */
    private fun placeValidClimb() {
        val board = composeRule.onNodeWithTag("kilter.create.board")
        board.performScrollTo()
        composeRule.waitForIdle()
        repeat(3) {
            board.performTouchInput { click(percentOffset(0.5f, 0.5f)) }
            composeRule.waitForIdle()
        }
        for ((fx, fy) in listOf(0.25f to 0.25f, 0.75f to 0.75f, 0.75f to 0.25f)) {
            board.performTouchInput { click(percentOffset(fx, fy)) }
            composeRule.waitForIdle()
        }
    }
}
