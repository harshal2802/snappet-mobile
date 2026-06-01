package com.snappet.mobile.ui

import androidx.compose.runtime.staticCompositionLocalOf
import com.snappet.mobile.core.AppContainer

/** The process-wide [AppContainer], injected at the app root and read by any mini-app. */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> {
    error("LocalAppContainer not provided")
}
