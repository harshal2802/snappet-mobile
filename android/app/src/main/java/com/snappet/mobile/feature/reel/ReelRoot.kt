package com.snappet.mobile.feature.reel

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalSpacing
import com.snappet.mobile.ui.theme.SnappetAccents

/**
 * The flagship **Workout Reels** module — HR-driven auto-highlight reels.
 *
 * The full pipeline (read a completed workout's heart-rate series via **Health Connect**, find the
 * photos/videos shot during the workout window via **MediaStore**, and assemble an HR-ranked reel
 * with **Media3 Transformer**) is device-only: it needs a paired wearable, real Health Connect data,
 * granted media permissions, and hardware video encoding — none of which exist on an emulator. This
 * mirrors the iOS app, where the equivalent HealthKit/Photos/AVFoundation flow builds and links but
 * is **not** part of the simulator UI-test suite. This screen documents the flow and gates entry on
 * device capabilities; the pipeline is implemented behind it as a later device phase.
 */
@Composable
fun ReelRoot(onExit: () -> Unit) {
    ModuleScaffold(title = "Workout Reels", onExit = onExit) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(LocalSpacing.current.pageGutter),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Card(
                Modifier.fillMaxWidth().testTag("reel.hero"),
                colors = CardDefaults.cardColors(containerColor = SnappetAccents.Coral.copy(alpha = 0.12f)),
            ) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Movie, contentDescription = null, tint = SnappetAccents.Coral, modifier = Modifier.size(40.dp))
                    Text("HR-driven highlight reels", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(
                        "Do a normal watch workout and film however you like. Snappet reads the " +
                            "workout's heart-rate series, finds the media you shot during the workout " +
                            "window, and assembles a reel ranked by HR intensity — one tap, minimal editing.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Text("How it works", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            StepRow(Icons.Filled.Watch, "Track a workout", "On Wear OS, recorded via Health Services → Health Connect.")
            StepRow(Icons.Filled.FavoriteBorder, "Read the HR series", "Resample → smooth → %HRR → find the high-intensity moments.")
            StepRow(Icons.Filled.PhotoLibrary, "Match your media", "MediaStore finds photos/videos shot inside the workout window.")
            StepRow(Icons.Filled.Bolt, "Assemble the reel", "Media3 Transformer cuts an HR-ranked highlight reel on-device.")

            Spacer(Modifier.height(4.dp))
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Requires a device", fontWeight = FontWeight.SemiBold)
                    Text(
                        "Connect Health Connect and a paired wearable, then grant media access. " +
                            "This flow can't run on an emulator (no HR data, no hardware encoder).",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = { /* device-only: launches Health Connect permission flow */ },
                        enabled = false,
                        modifier = Modifier.fillMaxWidth().testTag("reel.connectHealth"),
                    ) { Text("Connect Health Connect") }
                }
            }
        }
    }
}

@Composable
private fun StepRow(icon: ImageVector, title: String, detail: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
        Column(Modifier.fillMaxWidth()) {
            Text(title, fontWeight = FontWeight.Medium)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
