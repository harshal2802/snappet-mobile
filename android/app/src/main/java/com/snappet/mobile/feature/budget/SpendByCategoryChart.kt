package com.snappet.mobile.feature.budget

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** One category's spend for the selected month — the unit the chart plots. */
data class CategorySpend(val name: String, val amount: Double)

/** Stable palette for chart slices/legend, indexed by slice order. */
private val sliceColors = listOf(
    Color(0xFF3B82F6), Color(0xFF8B5CF6), Color(0xFF30A46C),
    Color(0xFFF76808), Color(0xFFE5484D), Color(0xFF06B6D4),
    Color(0xFFEAB308), Color(0xFFEC4899),
)

/**
 * A donut chart of the selected month's spend broken down by category, with a centred total and a
 * legend below. Drawn with [Canvas] (mirrors the Pomodoro chart pattern). Mirrors iOS
 * `SpendByCategoryChart`.
 */
@Composable
fun SpendByCategoryChart(slices: List<CategorySpend>, periodLabel: String, modifier: Modifier = Modifier) {
    val total = slices.sumOf { it.amount }
    Column(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(200.dp)) {
                val stroke = 36f
                val inset = stroke / 2
                val arcSize = Size(size.width - stroke, size.height - stroke)
                var startAngle = -90f
                val safeTotal = if (total > 0) total else 1.0
                slices.forEachIndexed { i, slice ->
                    val sweep = (slice.amount / safeTotal * 360.0).toFloat()
                    drawArc(
                        color = sliceColors[i % sliceColors.size],
                        startAngle = startAngle,
                        sweepAngle = sweep,
                        useCenter = false,
                        topLeft = Offset(inset, inset),
                        size = arcSize,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
                    )
                    startAngle += sweep
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(total.asCurrency(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(periodLabel, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            slices.forEachIndexed { i, slice ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.size(12.dp).clip(RoundedCornerShape(3.dp)).background(sliceColors[i % sliceColors.size]))
                    Text(slice.name, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                    Text(slice.amount.asCurrency(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
