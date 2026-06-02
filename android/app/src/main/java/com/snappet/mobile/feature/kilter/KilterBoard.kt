package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * Renders a climb's holds on a neutral board. Holds come pre-normalized (x,y in 0..1, y from the
 * top) from [KilterCatalog], colored by role. We draw an outlined ring per hold (matching the
 * on-wall LED-ring look); when [lit] we fill them on a dark board (illumination preview). The
 * official wood/hold background image isn't bundled (it lives in the Kilter app's assets, not the
 * DB) so the backdrop is schematic — coordinates are exact. Mirrors the iOS `KilterBoardView`.
 */
@Composable
fun KilterBoard(holds: List<KilterHold>, modifier: Modifier = Modifier, lit: Boolean = false) {
    Canvas(modifier.aspectRatio(0.95f)) {
        val w = size.width
        val h = size.height
        val radius = (min(w, h) * 0.025f).coerceAtLeast(6f)
        drawRoundRect(
            color = if (lit) Color.Black else Color(0xFFEDEDF0),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(28f, 28f),
        )
        for (hold in holds) {
            val center = androidx.compose.ui.geometry.Offset((hold.x * w).toFloat(), (hold.y * h).toFloat())
            val color = hexColor(hold.colorHex)
            if (lit) {
                drawCircle(color = color, radius = radius, center = center)
            } else {
                drawCircle(color = color, radius = radius, center = center, style = Stroke(width = 4f))
            }
        }
    }
}

/** Build a Color from a 6-digit hex string (no `#`), defaulting to gray on bad input. */
internal fun hexColor(hex: String): Color {
    val v = hex.toLongOrNull(16)
    if (v == null || hex.length != 6) return Color.Gray
    return Color(
        red = ((v shr 16) and 0xFF) / 255f,
        green = ((v shr 8) and 0xFF) / 255f,
        blue = (v and 0xFF) / 255f,
    )
}
