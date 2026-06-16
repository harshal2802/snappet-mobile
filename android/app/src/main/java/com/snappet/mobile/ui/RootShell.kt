package com.snappet.mobile.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.snappet.mobile.core.SuiteRouter
import com.snappet.mobile.ui.home.HomeDashboardScreen
import com.snappet.mobile.ui.library.AppLibraryScreen

/**
 * The suite shell: a two-tab bottom bar over the Home dashboard and the App Library, mirroring
 * the iOS `RootShell` `TabView`. Tab tags ("Today"/"Apps") match the labels the smoke tests tap.
 * Each tab renders inside a [rememberSaveableStateHolder] entry so switching tabs keeps the other
 * tab's `rememberSaveable` state (NavHost back stack, module position, drafts) instead of
 * disposing it (issue #86).
 *
 * Issue #99/#91: a pending [SuiteRouter] route (deep link, launcher shortcut, widget tap, or a Home
 * card) forces the Apps tab and is consumed by the [AppLibraryScreen] NavHost, which owns module
 * navigation. Home cards open modules through the same router so there's one navigation path.
 */
@Composable
fun RootShell() {
    var tab by rememberSaveable { mutableStateOf(0) }
    val tabStateHolder = rememberSaveableStateHolder()
    // App-level snackbar surface (issue #89): hosted once here and provided to every mini-app so
    // commit confirmations, errors, and undoable deletes share one host instead of per-module ones.
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val snackbarController = remember { SnackbarController(snackbarHostState, scope) }
    val router = LocalAppContainer.current.router

    // A queued route lives on the Apps tab — flip to it so the NavHost can honor it.
    LaunchedEffect(router.pendingRoute) {
        if (router.pendingRoute != null) tab = 1
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState, modifier = Modifier.testTag("app.snackbar")) },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { tab = 0 },
                    icon = { Icon(Icons.Filled.Home, contentDescription = "Today") },
                    label = { Text("Today") },
                    modifier = Modifier.testTag("tab.today").semantics { contentDescription = "Today" },
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { tab = 1 },
                    icon = { Icon(Icons.Filled.GridView, contentDescription = "Apps") },
                    label = { Text("Apps") },
                    modifier = Modifier.testTag("tab.apps").semantics { contentDescription = "Apps" },
                )
            }
        },
    ) { padding ->
        CompositionLocalProvider(LocalSnackbarController provides snackbarController) {
            Box(Modifier.fillMaxSize().padding(padding)) {
                val key = if (tab == 0) "today" else "apps"
                tabStateHolder.SaveableStateProvider(key) {
                    when (tab) {
                        0 -> HomeDashboardScreen(onOpenModule = { router.openModule(it) })
                        else -> AppLibraryScreen()
                    }
                }
            }
        }
    }
}
