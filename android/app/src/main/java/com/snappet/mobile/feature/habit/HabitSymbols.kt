package com.snappet.mobile.feature.habit

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.LocalCafe
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.NightlightRound
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The small shared palette of habit icons. Keys mirror the iOS `HabitEditorView.symbols` SF Symbol
 * names (kept stable so completion/edit semantics match) and map to Material icons for rendering.
 */
object HabitSymbols {
    const val default = "checkmark.circle"

    val all = listOf(
        "checkmark.circle", "drop.fill", "book.fill", "figure.run",
        "dumbbell.fill", "leaf.fill", "bed.double.fill", "cup.and.saucer.fill",
        "moon.fill", "sun.max.fill", "pencil", "heart.fill",
    )

    fun icon(key: String): ImageVector = when (key) {
        "drop.fill" -> Icons.Filled.WaterDrop
        "book.fill" -> Icons.Filled.MenuBook
        "figure.run" -> Icons.Filled.DirectionsRun
        "dumbbell.fill" -> Icons.Filled.FitnessCenter
        "leaf.fill" -> Icons.Filled.Spa
        "bed.double.fill" -> Icons.Filled.Bedtime
        "cup.and.saucer.fill" -> Icons.Filled.LocalCafe
        "moon.fill" -> Icons.Filled.NightlightRound
        "sun.max.fill" -> Icons.Filled.WbSunny
        "pencil" -> Icons.Filled.Edit
        "heart.fill" -> Icons.Filled.Favorite
        else -> Icons.Filled.CheckCircle
    }
}
