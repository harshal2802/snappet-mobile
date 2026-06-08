package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.min

/**
 * Renders a climb on the Kilter board: the full hold grid as faint markers with the climb's lit holds
 * drawn on top, **shape-coded by role** (start = triangle, hand = circle, finish = square, foot =
 * diamond — see [KilterHoldShape]) so a color-blind climber can read the route without separating the
 * hues; colors are kept too. The official wood/hold photo isn't bundled (#42 — copyrighted Aurora
 * assets), so the backdrop is schematic — but it's drawn at the user's selected board size and shows
 * every hole. `geometry` (grid + aspect) and `holds` arrive normalized to the same board extent **at
 * that size** from [KilterCatalog]. Mirrors the iOS `KilterBoardView`.
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

        // 2) the climb's lit holds, role-colored AND role-shaped (color-blind redundant channel)
        for (hold in holds) {
            val color = hexColor(hold.colorHex)
            val d = holdD * roleScale(hold.role)
            val center = pt(hold.x, hold.y)
            val shape = KilterHoldShape.forRole(hold.role)
            if (lit) {
                drawPath(holdPath(shape, center, d * 1.5f), color.copy(alpha = 0.35f))   // glow
                drawPath(holdPath(shape, center, d), color)                               // solid core
            } else {
                drawPath(holdPath(shape, center, d), color,
                    style = Stroke(width = (d * 0.17f).coerceAtLeast(2.5f), join = StrokeJoin.Round))
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

/**
 * The role's marker [Path] of diameter [d] centered at [center] (circle/triangle/square/diamond). Shared
 * with the detail screen's legend (it's `internal`) so the on-board shapes and the legend can't drift.
 * Mirrors iOS `KilterBoardView.holdPath`.
 */
internal fun holdPath(shape: KilterHoldShape, center: Offset, d: Float): Path {
    val r = d / 2f
    val p = Path()
    when (shape) {
        KilterHoldShape.CIRCLE ->
            p.addOval(Rect(center.x - r, center.y - r, center.x + r, center.y + r))
        KilterHoldShape.SQUARE ->
            p.addRoundRect(RoundRect(
                Rect(center.x - r, center.y - r, center.x + r, center.y + r),
                CornerRadius(d * 0.16f)))
        KilterHoldShape.TRIANGLE -> {
            p.moveTo(center.x, center.y - r)
            p.lineTo(center.x + r, center.y + r)
            p.lineTo(center.x - r, center.y + r)
            p.close()
        }
        KilterHoldShape.DIAMOND -> {
            p.moveTo(center.x, center.y - r)
            p.lineTo(center.x + r, center.y)
            p.lineTo(center.x, center.y + r)
            p.lineTo(center.x - r, center.y)
            p.close()
        }
    }
    return p
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
