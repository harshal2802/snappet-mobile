package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.min

/**
 * Renders a climb on the Kilter board: the full hold grid as faint markers with the climb's lit holds
 * drawn as role-colored rings on top (start/finish larger, feet smaller), inset so nothing clips. The
 * official wood/hold photo isn't bundled, so the backdrop is schematic — but every hole is shown, so a
 * climb reads in real board context. `geometry` (grid + aspect) and `holds` arrive normalized to the
 * same board extent from [KilterCatalog]. Mirrors the iOS `KilterBoardView`.
 */
@Composable
fun KilterBoard(
    geometry: KilterBoardGeometry,
    holds: List<KilterHold>,
    modifier: Modifier = Modifier,
    lit: Boolean = false,
) {
    val aspect = if (geometry.aspect > 0) geometry.aspect.toFloat() else 1f
    Canvas(modifier.aspectRatio(aspect)) {
        val w = size.width
        val h = size.height
        val unit = min(w, h)
        val holdD = (unit * 0.052f).coerceAtLeast(12f)
        val r = holdD / 2f

        fun pt(x: Double, y: Double) = Offset((r + x * (w - holdD)).toFloat(), (r + y * (h - holdD)).toFloat())

        drawRect(color = if (lit) Color(0xFF0E0E12) else Color(0xFFF1F0ED))

        // 1) faint full grid
        val gridColor = if (lit) Color.White.copy(alpha = 0.10f) else Color.Gray.copy(alpha = 0.28f)
        val gridR = holdD * 0.16f
        for (p in geometry.grid) drawCircle(gridColor, radius = gridR, center = pt(p.x, p.y))

        // 2) the climb's lit holds, role-colored
        for (hold in holds) {
            val color = hexColor(hold.colorHex)
            val d = holdD * roleScale(hold.role)
            val center = pt(hold.x, hold.y)
            if (lit) {
                drawCircle(color.copy(alpha = 0.35f), radius = d * 0.75f, center = center)  // glow
                drawCircle(color, radius = d / 2f, center = center)
            } else {
                drawCircle(color, radius = d / 2f, center = center, style = Stroke(width = (d * 0.17f).coerceAtLeast(2.5f)))
            }
        }
    }
}

/** Foot holds read smaller; start/finish a touch larger so the route's anchors pop. */
private fun roleScale(role: String): Float = when (role) {
    "foot" -> 0.74f
    "start", "finish" -> 1.14f
    else -> 1.0f
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
