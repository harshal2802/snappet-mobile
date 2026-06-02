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
        else -> Coral
    }
}
