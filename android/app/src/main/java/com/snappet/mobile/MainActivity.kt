package com.snappet.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import com.snappet.mobile.core.AppContainer
import com.snappet.mobile.core.TestHooks
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.RootShell
import com.snappet.mobile.ui.theme.SnappetTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Fresh in-memory store when a UI test asks for it (via TestHooks or an intent extra).
        val fresh = TestHooks.freshInMemoryStore || intent?.getBooleanExtra("uiTestFreshStore", false) == true
        val container = AppContainer.get(applicationContext, freshInMemory = fresh)

        setContent {
            CompositionLocalProvider(LocalAppContainer provides container) {
                SnappetTheme { RootShell() }
            }
        }
    }
}
