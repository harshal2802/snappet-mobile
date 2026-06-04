package com.snappet.mobile.feature.expense

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.theme.SnappetAccents

/**
 * Shared totals + per-person breakdown for an itemized receipt, rendered from a pure
 * [ReceiptSplit.Result]. Used by both the live preview in `NewReceiptSheet` and the read-only
 * `ReceiptDetail`. Mirrors the iOS `ReceiptSummaryView`.
 */
@Composable
fun ReceiptSummary(result: ReceiptSplit.Result) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Totals", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        TotalsRow("Items subtotal", money(result.itemsSubtotal))
        if (result.discount > 0.005) TotalsRow("Discount", "-" + money(result.discount), tint = SnappetAccents.Leaf)
        if (result.tax > 0.005) TotalsRow("Tax", money(result.tax))
        if (result.unassignedSubtotal > 0.005) TotalsRow("Unassigned", money(result.unassignedSubtotal), tint = SnappetAccents.Tomato)
        Row(Modifier.fillMaxWidth()) {
            Text("Total", modifier = Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Text(money(result.grandTotal), fontWeight = FontWeight.SemiBold)
        }

        Text("Per person", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (result.perPerson.isEmpty()) {
            Text("Assign items to people to see the split.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            result.perPerson.forEach { share -> PersonShareRow(share) }
        }
    }
}

@Composable
private fun TotalsRow(label: String, value: String, tint: Color? = null) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium,
            color = tint ?: MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun PersonShareRow(share: ReceiptSplit.PersonShare) {
    Column(Modifier.fillMaxWidth().testTag("receipt.share.${share.name}")) {
        Row(Modifier.fillMaxWidth()) {
            Text(share.name, modifier = Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Text(money(share.total), fontWeight = FontWeight.SemiBold)
        }
        Text(detail(share), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun detail(share: ReceiptSplit.PersonShare): String {
    val parts = mutableListOf("${money(share.itemsSubtotal)} items")
    if (share.discount > 0.005) parts.add("-${money(share.discount)} disc")
    if (share.tax > 0.005) parts.add("+${money(share.tax)} tax")
    return parts.joinToString("  ")
}

/** Plain currency-style amount, e.g. "$12.34" — matches the rest of the Split Expenses UI. */
private fun money(value: Double): String = "$" + String.format("%.2f", value)
