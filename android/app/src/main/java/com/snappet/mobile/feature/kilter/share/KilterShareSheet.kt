package com.snappet.mobile.feature.kilter.share

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.feature.kilter.KilterClimbIdentity

/**
 * Share sheet for a Kilter climb (issue #91). Renders a QR encoding the cross-platform deep link
 * `snappet://kilter/climb/<uuid>?angle=<n>` (scannable by iOS and Android), plus the link itself and
 * two plain-language actions: "Share climb" (sends the link) and "Copy hold string" (the raw frames,
 * the only path for a created climb the recipient may not have in their catalog). Mirrors the iOS
 * `KilterShareView`. Labels are user language — no bare "frames" jargon.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KilterShareSheet(
    uuid: String,
    angle: Int,
    frames: String,
    onDismiss: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val link = remember(uuid, angle) { KilterDeepLink.climbUrl(uuid, angle) }
    val qr = remember(link) { QrEncoder.encode(link, 600).asImageBitmap() }

    ModalBottomSheet(onDismissRequest = onDismiss, modifier = Modifier.testTag("kilter.shareSheet")) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Share this climb", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "Point another phone's Snappet scanner at the code, or send the link — it opens the " +
                    "climb on iOS or Android.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Image(qr, contentDescription = "Climb QR code", modifier = Modifier.size(220.dp).testTag("kilter.shareQr"))
            Text(link, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = { shareLink(context, link) },
                    modifier = Modifier.weight(1f).testTag("kilter.shareLink"),
                ) { Text("Share link") }
                if (frames.isNotEmpty()) {
                    OutlinedButton(
                        onClick = { copyHoldString(context, frames) },
                        modifier = Modifier.weight(1f).testTag("kilter.copyHolds"),
                    ) { Text("Copy hold string") }
                }
            }
            Text(
                "The hold string lets someone re-create this climb even if it's not in their catalog.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun shareLink(context: Context, link: String) {
    val send = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, link) }
    context.startActivity(Intent.createChooser(send, "Share climb"))
}

private fun copyHoldString(context: Context, frames: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("holds", KilterClimbIdentity.canonicalFrames(frames)))
}
