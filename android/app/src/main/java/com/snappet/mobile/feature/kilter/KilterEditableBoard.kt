package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import kotlin.math.hypot
import kotlin.math.min

/**
 * The **authoring** board: the same schematic backdrop as [KilterBoard] (faint hole grid + role-shaped,
 * role-colored holds) but interactive — tapping the nearest hole cycles its role (via [onCycle]). Built on
 * the exact normalized geometry from [KilterCatalog.placeableHolds] (same render extent as
 * [KilterCatalog.holds]), so a climb drawn here lines up with how it renders everywhere else. A clear hint
 * ring marks every placeable hole. Mirrors iOS `KilterEditableBoardView`.
 */
@Composable
fun KilterEditableBoard(
    geometry: KilterBoardGeometry,
    placeable: List<KilterPlaceableHold>,
    assignments: Map<Int, KilterAuthorRole>,
    onCycle: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val aspect = if (geometry.aspect > 0) geometry.aspect.toFloat() else 1f
    // The tap detector is keyed only on `placeable` (so it isn't torn down every time a hold is placed),
    // so capture the LATEST onCycle via rememberUpdatedState — otherwise a stale callback (built from an
    // earlier `assignments`) would reset the climb to a single hold on every tap.
    val currentOnCycle by rememberUpdatedState(onCycle)
    Canvas(
        modifier
            .aspectRatio(aspect)
            .pointerInput(placeable) {
                detectTapGestures { tap ->
                    val w = size.width.toFloat()
                    val h = size.height.toFloat()
                    val holdD = (min(w, h) * 0.052f).coerceAtLeast(12f)
                    val r = holdD / 2f
                    fun pt(x: Double, y: Double) = Offset(r + (x * (w - holdD)).toFloat(), r + (y * (h - holdD)).toFloat())
                    var bestPid = -1
                    var bestDist = Float.MAX_VALUE
                    for (hold in placeable) {
                        val c = pt(hold.x, hold.y)
                        val dist = hypot(c.x - tap.x, c.y - tap.y)
                        if (dist < bestDist) { bestDist = dist; bestPid = hold.placementId }
                    }
                    if (bestPid >= 0 && bestDist <= holdD) currentOnCycle(bestPid)
                }
            },
    ) {
        val w = size.width
        val h = size.height
        val holdD = (min(w, h) * 0.052f).coerceAtLeast(12f)
        val r = holdD / 2f
        fun pt(x: Double, y: Double) = Offset((r + x * (w - holdD)).toFloat(), (r + y * (h - holdD)).toFloat())

        drawRect(Color(0xFFF1F0ED))

        // 1) faint full grid
        val gridR = holdD * 0.16f
        for (p in geometry.grid) drawCircle(Color.Gray.copy(alpha = 0.28f), gridR, pt(p.x, p.y))

        // 2) hint ring at every unassigned placeable hole, so targets are discoverable
        val hintR = holdD * 0.25f
        for (hold in placeable) if (assignments[hold.placementId] == null) {
            drawCircle(Color.Gray.copy(alpha = 0.22f), hintR, pt(hold.x, hold.y), style = Stroke(width = 1f))
        }

        // 3) placed holds, role-colored + role-shaped
        for (hold in placeable) {
            val role = assignments[hold.placementId] ?: continue
            val d = holdD * roleScale(role)
            val center = pt(hold.x, hold.y)
            drawPath(holdPath(KilterHoldShape.forRole(role.roleName), center, d), hexColor(authorRoleColorHex(role)),
                style = Stroke(width = (d * 0.17f).coerceAtLeast(2.5f), join = StrokeJoin.Round))
        }
    }
}

private fun roleScale(role: KilterAuthorRole): Float = when (role) {
    KilterAuthorRole.FOOT -> 0.74f
    KilterAuthorRole.START, KilterAuthorRole.FINISH -> 1.14f
    KilterAuthorRole.MIDDLE -> 1.0f
}

/** On-screen role colors (mirror the catalog's `screen_color` for the four roles). */
internal fun authorRoleColorHex(role: KilterAuthorRole): String = when (role) {
    KilterAuthorRole.START -> "00DD00"
    KilterAuthorRole.MIDDLE -> "00FFFF"
    KilterAuthorRole.FINISH -> "FF00FF"
    KilterAuthorRole.FOOT -> "FFA500"
}
