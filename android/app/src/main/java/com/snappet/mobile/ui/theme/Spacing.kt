package com.snappet.mobile.ui.theme

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A 4-pt spacing scale, mirroring the iOS Pulse spec. Read via [LocalSpacing] inside any composable
 * (e.g. `LocalSpacing.current.md12`) to keep gaps/padding on a consistent rhythm.
 */
data class Spacing(
    val xs4: Dp = 4.dp,
    val sm8: Dp = 8.dp,
    val md12: Dp = 12.dp,
    val lg16: Dp = 16.dp,
    val xl24: Dp = 24.dp,
    val xxl32: Dp = 32.dp,
) {
    /**
     * The single page gutter applied at every module/screen root (issue #97) so the suite stops
     * "breathing" differently per module — page paddings used to drift 12/16/20/24dp. 16dp is the
     * Material default and matches the home dashboard, the most-seen surface.
     */
    val pageGutter: Dp get() = lg16

    /**
     * The accessibility minimum touch target (issue #98): Material's 48dp. Custom-drawn / shrunken
     * interactive elements (the habit day cell, small icon buttons) must reach this.
     */
    val minTouchTarget: Dp get() = 48.dp
}

val LocalSpacing = staticCompositionLocalOf { Spacing() }
