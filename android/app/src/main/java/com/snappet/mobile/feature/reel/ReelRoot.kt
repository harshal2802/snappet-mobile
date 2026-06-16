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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
 * Stage 0 (issue #90): an honest screen written in user language, with a real "Notify me / Coming to
 * Android" control instead of a permanently disabled button blaming the emulator. The full on-device
 * pipeline (read a completed workout's heart-rate series via Health Connect → find the photos/videos
 * shot in the workout window → assemble an HR-ranked reel via Media3 Transformer) is the device-only
 * Stage 1+ phase, mirroring the sanctioned iOS HealthKit/Photos/AVFoundation architecture. The pure,
 * portable ranking core ([ReelRanking]) is the first pipeline slice landed behind this screen and is
 * JVM-unit-tested without a device.
 */
@Composable
fun ReelRoot(onExit: () -> Unit) {
    var interested by remember { mutableStateOf(false) }
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
                    Text("Highlight reels from your workouts", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(
                        "Do a normal watch workout and film however you like. Snappet finds your most " +
                            "intense moments — where your heart rate spiked — and turns the photos and " +
                            "videos you shot into a short highlight reel. One tap, almost no editing.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Text("How it works", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            StepRow(Icons.Filled.Watch, "Track a workout", "Use your watch as usual — Snappet reads the workout afterward.")
            StepRow(Icons.Filled.FavoriteBorder, "Find the intense moments", "We look at your heart rate to spot the hardest stretches.")
            StepRow(Icons.Filled.PhotoLibrary, "Match your photos & videos", "We line up the media you shot with those moments.")
            StepRow(Icons.Filled.Bolt, "Build the reel", "We cut a short highlight reel, ranked by intensity, right on your phone.")

            Spacer(Modifier.height(4.dp))
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Coming to Android", fontWeight = FontWeight.SemiBold)
                    Text(
                        if (interested)
                            "Thanks — we'll surface this for you as soon as the on-device pipeline lands."
                        else
                            "Reels already work on iPhone. The Android version is in progress — it builds " +
                                "your reel entirely on your phone, with nothing uploaded.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedButton(
                        onClick = { interested = true },
                        enabled = !interested,
                        modifier = Modifier.fillMaxWidth().testTag("reel.notifyMe"),
                    ) { Text(if (interested) "We'll let you know" else "Notify me when it's ready") }
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
