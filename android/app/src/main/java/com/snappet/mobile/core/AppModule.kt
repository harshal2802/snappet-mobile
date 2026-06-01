package com.snappet.mobile.core

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector

/** Category groupings for the App Library. */
enum class ModuleCategory(val title: String) {
    FITNESS("Fitness"),
    PRODUCTIVITY("Productivity"),
    FINANCE("Finance"),
}

/**
 * A self-contained mini-app in the suite. Each feature package vends one of these
 * descriptors; the App Library renders them and routes to [content]. Mini-apps log
 * activity to [SnappetCore] so the Home dashboard can aggregate historical usage across
 * the whole suite. Mirrors the iOS `AppModule`.
 */
data class AppModule(
    /** Stable id — also used as the `module` key in [UsageRecord] and the test card tag. */
    val id: String,
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val category: ModuleCategory,
    /**
     * The module's root screen. [onExit] pops back to the App Library — wire it to the root
     * screen's top-bar back arrow (tagged `BackButton`). Deeper screens inside a module manage
     * their own back navigation. Mirrors iOS pushing the root view into the shared stack.
     */
    val content: @Composable (onExit: () -> Unit) -> Unit,
)
