package com.snappet.mobile.feature.expense

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.theme.SnappetAccents

/**
 * Card that surfaces a [ReceiptValidation.Report]: a coloured headline (Balanced / Needs review /
 * Doesn't add up) that expands to the individual checks on tap. Advisory only. Mirrors the iOS
 * `ReceiptValidationBanner`.
 */
@Composable
fun ReceiptValidationBanner(report: ReceiptValidation.Report) {
    var expanded by remember { mutableStateOf(false) }
    val tint = color(report.overall)

    Column(
        Modifier
            .fillMaxWidth()
            .background(tint.copy(alpha = 0.10f), RoundedCornerShape(12.dp))
            .clickable { expanded = !expanded }
            .padding(12.dp)
            .testTag("expense.receipt.validation"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon(report.overall), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
            Text(report.headline, fontWeight = FontWeight.SemiBold, color = tint, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ExpandMore, contentDescription = if (expanded) "Collapse" else "Expand",
                tint = tint, modifier = Modifier.size(20.dp))
        }
        if (expanded) {
            report.checks.forEach { check ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(icon(check.status), contentDescription = null, tint = color(check.status),
                        modifier = Modifier.size(18.dp))
                    Column {
                        Text(check.title, style = MaterialTheme.typography.bodyMedium)
                        if (check.detail.isNotEmpty()) {
                            Text(check.detail, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

private fun icon(status: ReceiptValidation.Status): ImageVector = when (status) {
    ReceiptValidation.Status.PASS -> Icons.Filled.CheckCircle
    ReceiptValidation.Status.WARN -> Icons.Filled.Warning
    ReceiptValidation.Status.FAIL -> Icons.Filled.Error
}

private fun color(status: ReceiptValidation.Status): Color = when (status) {
    ReceiptValidation.Status.PASS -> SnappetAccents.Leaf
    ReceiptValidation.Status.WARN -> SnappetAccents.Kilter
    ReceiptValidation.Status.FAIL -> SnappetAccents.Tomato
}
