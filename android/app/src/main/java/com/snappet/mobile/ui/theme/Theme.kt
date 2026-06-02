package com.snappet.mobile.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext

/** The "Snappet Pulse" light scheme — coral brand on warm paper. */
private val LightColors = lightColorScheme(
    primary = PulseColors.PrimaryLight,
    onPrimary = PulseColors.OnPrimary,
    background = PulseColors.BackgroundLight,
    onBackground = PulseColors.InkLight,
    surface = PulseColors.SurfaceLight,
    onSurface = PulseColors.InkLight,
    surfaceVariant = PulseColors.SurfaceVariantLight,
    onSurfaceVariant = PulseColors.TextSecondaryLight,
    outline = PulseColors.OutlineLight,
)

/** The "Snappet Pulse" dark scheme. */
private val DarkColors = darkColorScheme(
    primary = PulseColors.PrimaryDark,
    onPrimary = PulseColors.OnPrimary,
    background = PulseColors.BackgroundDark,
    onBackground = PulseColors.InkDark,
    surface = PulseColors.SurfaceDark,
    onSurface = PulseColors.InkDark,
    surfaceVariant = PulseColors.SurfaceVariantDark,
    onSurfaceVariant = PulseColors.TextSecondaryDark,
    outline = PulseColors.OutlineDark,
)

/**
 * The suite theme. Defaults to the curated Pulse palette; Material You dynamic color is **opt-in**
 * via [dynamicColor] (only applied on API 31+). Provides the Pulse spacing scale and the
 * reduce-motion flag so any composable can read them. Mirrors the iOS Pulse design tokens.
 */
@Composable
fun SnappetTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        darkTheme -> DarkColors
        else -> LightColors
    }
    val reduceMotion = rememberSystemReduceMotion()
    CompositionLocalProvider(
        LocalSpacing provides Spacing(),
        LocalReduceMotion provides reduceMotion,
    ) {
        MaterialTheme(
            colorScheme = colors,
            shapes = SnappetShapes,
            typography = SnappetTypography,
            content = content,
        )
    }
}
