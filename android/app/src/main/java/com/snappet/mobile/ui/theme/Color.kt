package com.snappet.mobile.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The "Snappet Pulse" palette — light + dark roles, mirroring the iOS Pulse spec. Raw colors are
 * collected here; [Theme] wires them into Material 3 `lightColorScheme`/`darkColorScheme`. Per-module
 * accents live in [SnappetAccents].
 */
object PulseColors {
    // Brand / primary — "Pulse Coral".
    val PrimaryLight = Color(0xFFFF5A4D)
    val PrimaryDark = Color(0xFFFF7A6B)

    // Background — "paper".
    val BackgroundLight = Color(0xFFFBFAF8)
    val BackgroundDark = Color(0xFF121214)

    // Surface — card.
    val SurfaceLight = Color(0xFFFFFFFF)
    val SurfaceDark = Color(0xFF1E1E22)

    // Surface variant — "surfaceMuted" tile fill.
    val SurfaceVariantLight = Color(0xFFF2F1EE)
    val SurfaceVariantDark = Color(0xFF26262B)

    // Outline — "hairline".
    val OutlineLight = Color(0xFFE7E5E1)
    val OutlineDark = Color(0xFF34343A)

    // Status text — success/warning/neutral that pass 4.5:1 on the mode's surfaces AND
    // on their own alpha-tinted chip washes (the harder case — computed, issue #96 review:
    // SuccessLight on its 0.16 wash ≥5.6:1, WarningLight on its 0.18 wash ≥5.0:1, all
    // ≥4.5:1 up to a 0.22 wash in both modes). The old hardcoded greens/ambers
    // (#1E7E48 on #1E1E22 ≈ 2.6:1) were unreadable in dark.
    val SuccessLight = Color(0xFF136134)
    val SuccessDark = Color(0xFF7DD8A4)
    val WarningLight = Color(0xFF854C00)
    val WarningDark = Color(0xFFFFB85C)
    val NeutralLight = Color(0xFF4F4F57)
    val NeutralDark = Color(0xFFC2C2CA)

    // The Kilter board's schematic "wall" per mode — the fixed light paper was a glaring
    // rectangle in a dimly-lit gym (issue #96).
    val BoardPaperLight = Color(0xFFF1F0ED)
    val BoardPaperDark = Color(0xFF222226)

    // On background / on surface — "ink".
    val InkLight = Color(0xFF1A1A1E)
    val InkDark = Color(0xFFF4F3F1)

    // On surface variant — "textSecondary".
    val TextSecondaryLight = Color(0xFF6B6A66)
    val TextSecondaryDark = Color(0xFFA6A5A1)

    // On-primary text (text drawn on the coral primary).
    val OnPrimary = Color(0xFFFFFFFF)
}

/**
 * Curated per-module accent colors, keyed by the real [com.snappet.mobile.core.AppModule.id] values
 * registered in `ModuleRegistry`. Mirrors the iOS accent assignment:
 *  - `workout` (Workout Reels) → coral, `workout-log` (Workout Tracker) → ember-orange,
 *  - `pomodoro` → tomato, `habit` → leaf-green, `journal` → violet,
 *  - `tip` → mint, `expense` → teal, `budget` → azure.
 */
object SnappetAccents {
    val Coral = Color(0xFFFF5A4D)
    val Ember = Color(0xFFF76808)
    val Tomato = Color(0xFFE5484D)
    val Leaf = Color(0xFF30A46C)
    val Violet = Color(0xFF8E4EC6)
    val Mint = Color(0xFF12A594)
    val Teal = Color(0xFF0D9488)
    val Azure = Color(0xFF0091FF)
    val Kilter = Color(0xFFD97706)   // amber/sandstone — Kilter Board (climbing); distinct from coral/ember

    /** Accent for a module id; falls back to the brand coral for unknown ids. */
    fun forModule(id: String): Color = when (id) {
        "workout" -> Coral
        "workout-log" -> Ember
        "pomodoro" -> Tomato
        "habit" -> Leaf
        "journal" -> Violet
        "tip" -> Mint
        "expense" -> Teal
        "budget" -> Azure
        "kilter" -> Kilter
        else -> Coral
    }
}

/** Theme-aware success text color (≥4.5:1 in both modes). */
@androidx.compose.runtime.Composable
fun pulseSuccess(): Color =
    if (androidx.compose.foundation.isSystemInDarkTheme()) PulseColors.SuccessDark else PulseColors.SuccessLight

/** Theme-aware warning text color (≥4.5:1 in both modes). */
@androidx.compose.runtime.Composable
fun pulseWarning(): Color =
    if (androidx.compose.foundation.isSystemInDarkTheme()) PulseColors.WarningDark else PulseColors.WarningLight

/** Theme-aware neutral status color (attempt/in-progress chips; ≥4.5:1 in both modes). */
@androidx.compose.runtime.Composable
fun pulseNeutral(): Color =
    if (androidx.compose.foundation.isSystemInDarkTheme()) PulseColors.NeutralDark else PulseColors.NeutralLight

/**
 * The Kilter module accent (amber/sandstone) — the single source the Kilter screens read instead of
 * re-hardcoding the raw `0xFFD97706` hex (issue #97). Lit a touch brighter in dark mode so it keeps a
 * readable contrast on the dark Kilter surfaces, mirroring the per-mode status tokens.
 */
@androidx.compose.runtime.Composable
fun kilterAccent(): Color =
    if (androidx.compose.foundation.isSystemInDarkTheme()) Color(0xFFF0A23B) else SnappetAccents.Kilter
