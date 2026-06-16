package com.snappet.mobile

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.compose.runtime.CompositionLocalProvider
import com.snappet.mobile.core.AppContainer
import com.snappet.mobile.core.TestHooks
import com.snappet.mobile.feature.kilter.KilterCatalog
import com.snappet.mobile.feature.kilter.KilterCatalogFixture
import com.snappet.mobile.feature.kilter.KilterCatalogStore
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.RootShell
import com.snappet.mobile.ui.theme.SnappetTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // The AndroidX splash (Theme.Snappet.Starting) hands off here; must run before
        // super.onCreate on the launcher activity (issue #96).
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Fresh in-memory store when a UI test asks for it (via TestHooks or an intent extra).
        val fresh = TestHooks.freshInMemoryStore || intent?.getBooleanExtra("uiTestFreshStore", false) == true
        val container = AppContainer.get(applicationContext, freshInMemory = fresh)
        // Touch the Pomodoro engine at launch (a foreground context) so a session that
        // survived process death restores — and away-completed focuses get logged —
        // without requiring the user to open the module first (issue #85 review).
        container.pomodoro

        // Kilter catalog (issue #42): the app ships none. Under the catalog test hook, install the
        // synthetic fixture so the Kilter instrumented tests have data to browse; otherwise (fresh
        // store) clear any leftover catalog so runs are deterministic. No-ops in a normal run.
        if (TestHooks.installKilterCatalogFixture) {
            KilterCatalogFixture.installForTesting(applicationContext)
        } else if (fresh) {
            KilterCatalogStore.get(applicationContext).clear()
            KilterCatalog.reset()
        }

        // Deep link (snappet://kilter/climb/...), launcher shortcut, or widget tap → SuiteRouter.
        routeIntent(intent, container)

        setContent {
            CompositionLocalProvider(LocalAppContainer provides container) {
                SnappetTheme { RootShell() }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeIntent(intent, AppContainer.get(applicationContext))
    }

    /**
     * Translate a launch [Intent] into a [com.snappet.mobile.core.SuiteRouter] route (issues #91, #99):
     * a `snappet://` VIEW link opens a Kilter climb; a `snappet.module` string extra (carried by static
     * launcher shortcuts and Glance widget taps) opens that module. The shell consumes the route once.
     */
    private fun routeIntent(intent: Intent?, container: AppContainer) {
        intent ?: return
        val handledUri = intent.data?.let { container.router.handleUri(it.toString()) } == true
        if (handledUri) return
        intent.getStringExtra(EXTRA_MODULE)?.let { container.router.openModule(it) }
    }

    companion object {
        /** String extra carrying a module id for shortcuts / widget taps (issue #99). */
        const val EXTRA_MODULE = "snappet.module"
    }
}
