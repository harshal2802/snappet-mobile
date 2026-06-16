package com.snappet.mobile.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback

/**
 * Tiny wrapper over [LocalHapticFeedback] (issue #89) so commit/toggle moments fire a consistent
 * tactile confirmation without each call site importing the haptic plumbing. Compose exposes only
 * `LongPress` and `TextHandleMove` cross-platform; we map our two intents onto them:
 *  - [SnappetHaptics.commit] — a firm "it happened" for set-complete / habit-toggle / log-climb,
 *  - [SnappetHaptics.tick]   — a light tick for smaller state changes.
 */
class SnappetHaptics(private val haptic: HapticFeedback) {
    fun commit() = haptic.performHapticFeedback(HapticFeedbackType.LongPress)
    fun tick() = haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
}

@Composable
fun rememberSnappetHaptics(): SnappetHaptics {
    val haptic = LocalHapticFeedback.current
    return remember(haptic) { SnappetHaptics(haptic) }
}
