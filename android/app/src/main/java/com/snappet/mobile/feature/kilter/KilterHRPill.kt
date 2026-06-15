package com.snappet.mobile.feature.kilter

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.feature.kilter.hr.HeartRateZone

/**
 * Compact live HR pill, ported from the iOS `KilterHRPill`. Shows the current bpm tinted by training
 * zone, "—" before the first sample, and an "adjust strap" warning when contact is lost. Used in the
 * Kilter session banner. Live values come from [com.snappet.mobile.feature.kilter.hr.BleHeartRateSource].
 */
@Composable
fun KilterHRPill(
    bpm: Int?,
    contactLost: Boolean,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val zone = HeartRateZone.forBpm(bpm)
    val tint = if (zone == HeartRateZone.NONE) Color(0xFFFF2D55) else Color(zone.colorHex)
    val label = bpm?.let { "$it${if (compact) "" else " bpm"}" } ?: "—"
    val a11y = if (bpm != null) {
        "Heart rate $bpm beats per minute" + if (contactLost) ", adjust strap" else ""
    } else "Heart rate unavailable"

    Row(
        modifier
            .background(tint.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .semantics { contentDescription = a11y }
            .testTag("kilter.hrPill"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Filled.Favorite, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(label, style = MaterialTheme.typography.labelMedium, color = tint, fontWeight = FontWeight.SemiBold)
        if (contactLost) {
            Icon(Icons.Filled.WarningAmber, contentDescription = null,
                tint = Color(0xFFFF9500), modifier = Modifier.size(12.dp))
        }
    }
}
