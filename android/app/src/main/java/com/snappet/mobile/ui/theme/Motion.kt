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
