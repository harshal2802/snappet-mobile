package com.snappet.mobile.ui.theme

import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext

/**
 * The "Snappet Pulse" motion system. Specs are hand-rolled (not tied to any specific M3
 * `MotionScheme` version) so behaviour is stable across Compose releases. Use [SnappetMotion]
 * helpers via [gated] so every animation collapses to [SnappetMotion.reduced] when the user has
 * disabled animations.
 */
object SnappetMotion {
    /** ~150ms linear-ish tween for small, frequent state changes (color, alpha, small offsets). */
    fun <T> quick(): FiniteAnimationSpec<T> = tween(durationMillis = 150)

    /** The default expressive motion: a medium-bouncy, low-stiffness spring for entrances/values. */
    fun <T> standard(): FiniteAnimationSpec<T> = spring(
        dampingRatio = Spring.DampingRatioMediumBouncy,
        stiffness = Spring.StiffnessLow,
    )

    /** A restrained spring for press/scale feedback — low bounce so it settles cleanly. */
    fun <T> expressive(): FiniteAnimationSpec<T> = spring(
        dampingRatio = Spring.DampingRatioLowBouncy,
        stiffness = Spring.StiffnessMediumLow,
    )

    /** No motion: snap straight to the target value. Used when reduce-motion is on. */
    fun <T> reduced(): FiniteAnimationSpec<T> = snap()
}

/** Whether the user has asked the system to remove/minimise animations. */
val LocalReduceMotion = staticCompositionLocalOf { false }

/**
 * Reads the OS animation preference: `Settings.Global.ANIMATOR_DURATION_SCALE == 0f` means the user
 * turned animations off (Developer options / accessibility). Defaults to "not reduced" if the
 * setting can't be read.
 */
@Composable
fun rememberSystemReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        val scale = Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
        scale == 0f
    }
}

/**
 * Returns [spec] normally, or [SnappetMotion.reduced] when reduce-motion is on. Pass the current
 * [LocalReduceMotion] value as [reduceMotion]. Use everywhere an animation spec is supplied so a
 * single flag governs all motion.
 */
fun <T> gated(reduceMotion: Boolean, spec: FiniteAnimationSpec<T>): FiniteAnimationSpec<T> =
    if (reduceMotion) SnappetMotion.reduced() else spec

/** [gated] overload for the broader [AnimationSpec] type (e.g. cross-fade/animateContentSize). */
fun <T> gatedSpec(reduceMotion: Boolean, spec: AnimationSpec<T>): AnimationSpec<T> =
    if (reduceMotion) SnappetMotion.reduced() else spec

/**
 * The shared "structural transition" used for the three suite-level surface swaps — tab switch,
 * module entry/exit, and the workout phase change (issue #97). A snappy slide-along-axis + cross-fade
 * (~220ms in, 180ms out) instead of the navigation default 700ms crossfade. Collapses to an instant
 * cut under reduce-motion. Factored here so the shell, the library NavHost, and the workout player all
 * read one spec and can't drift.
 *
 * [forward] picks the slide direction (true → new content enters from the trailing edge), so a "deeper"
 * navigation and a "back" pop feel different. Returns an [androidx.compose.animation.ContentTransform].
 */
fun snappetSurfaceTransition(
    reduceMotion: Boolean,
    forward: Boolean = true,
): androidx.compose.animation.ContentTransform {
    if (reduceMotion) {
        // Instant: a zero-duration fade so AnimatedContent still settles, with no movement.
        return androidx.compose.animation.ContentTransform(
            targetContentEnter = androidx.compose.animation.fadeIn(snap()),
            initialContentExit = androidx.compose.animation.fadeOut(snap()),
        )
    }
    val enterMs = 220
    val exitMs = 160
    val dir = if (forward) 1 else -1
    return androidx.compose.animation.ContentTransform(
        targetContentEnter = androidx.compose.animation.slideInHorizontally(tween(enterMs)) { full -> dir * full / 12 } +
            androidx.compose.animation.fadeIn(tween(enterMs)),
        initialContentExit = androidx.compose.animation.slideOutHorizontally(tween(exitMs)) { full -> -dir * full / 12 } +
            androidx.compose.animation.fadeOut(tween(exitMs)),
    )
}
