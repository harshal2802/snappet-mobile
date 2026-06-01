package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.test.core.app.ActivityScenario
import com.snappet.mobile.core.TestHooks
import org.junit.Before
import org.junit.Rule

/**
 * Shared base for the suite's instrumented Compose tests. Forces a fresh in-memory store
 * before each launch (the Android analogue of the iOS `-uiTestFreshStore` arg) and provides
 * the App-Library entry helpers every per-module test reuses (mirrors the iOS test pattern of
 * opening each mini-app from its card).
 */
@OptIn(ExperimentalTestApi::class)
abstract class SuiteTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Before
    fun useFreshStore() {
        TestHooks.freshInMemoryStore = true
    }

    fun launch(): ActivityScenario<MainActivity> = ActivityScenario.launch(MainActivity::class.java)

    /** Switch to the App Library tab. */
    fun openApps() {
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("tab.apps").performClick()
    }

    /** Open a mini-app from the App Library by its module id, scrolling its card into view first. */
    fun openModule(id: String) {
        openApps()
        composeRule.onNodeWithTag("appLibraryGrid").performScrollToNode(hasTestTag("moduleCard.$id"))
        composeRule.onNodeWithTag("moduleCard.$id").performClick()
        composeRule.waitForIdle()
    }

    /** Tap the standard module back arrow (returns to the App Library / pops a deeper screen). */
    fun tapBack() {
        composeRule.onNodeWithTag("BackButton").performClick()
        composeRule.waitForIdle()
    }

    /** Read the concatenated text rendered by the node carrying [tag] (for value assertions). */
    fun textOf(tag: String): String {
        val node = composeRule.onNodeWithTag(tag).fetchSemanticsNode()
        val texts = node.config.getOrNull(SemanticsProperties.Text) ?: emptyList()
        return texts.joinToString("") { it.text }
    }
}
