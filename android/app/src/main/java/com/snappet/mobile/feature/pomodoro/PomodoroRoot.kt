package com.snappet.mobile.feature.pomodoro

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.snappet.mobile.core.UsageRecord
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetAccents
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import kotlinx.coroutines.delay

private enum class PomodoroScreen { ROOT, HISTORY }

/** Root entry for the Pomodoro mini-app: a focus timer with history and persisted settings. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PomodoroRoot(onExit: () -> Unit) {
    val context = LocalContext.current
    val container = LocalAppContainer.current

    var screen by remember { mutableStateOf(PomodoroScreen.ROOT) }
    var showSettings by remember { mutableStateOf(false) }
    var focus by remember { mutableStateOf(PomodoroSettings.focusMinutes(context)) }
    var brk by remember { mutableStateOf(PomodoroSettings.breakMinutes(context)) }
    val sessions by container.database.pomodoroDao().allFlow().collectAsState(initial = emptyList())

    // App-owned engine (issue #85): survives back-out/tab-switch/rotation; the container
    // wires session logging, persistence, the countdown notification, and the phase-end
    // alarm. This screen is just a window onto it.
    val timer = container.pomodoro
    LaunchedEffect(Unit) { timer.applyDurations(focus, brk) }

    // Phase-end alerts need POST_NOTIFICATIONS on API 33+ — ask in context, before the
    // first start, like the iOS screen does for UNUserNotifications (#70).
    val notifPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()) { /* best-effort */ }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    // 4x/sec UI ticker — only runs while the timer is running (drift-free; math is wall-clock based).
    LaunchedEffect(timer.isRunning) {
        while (timer.isRunning) {
            timer.tick()
            delay(250)
        }
    }

    when (screen) {
        PomodoroScreen.HISTORY -> PomodoroHistoryScreen(onExit = { screen = PomodoroScreen.ROOT })
        PomodoroScreen.ROOT -> ModuleScaffold(
            title = "Pomodoro",
            onExit = onExit,
            actions = {
                IconButton(onClick = { screen = PomodoroScreen.HISTORY }, modifier = Modifier.testTag("pomodoro.history")) {
                    Icon(Icons.Filled.History, contentDescription = "Session history")
                }
                IconButton(onClick = { showSettings = true }, modifier = Modifier.testTag("pomodoro.settings")) {
                    Icon(Icons.Filled.Tune, contentDescription = "Timer settings")
                }
            },
        ) { padding ->
            PomodoroBody(timer, sessions, padding)
        }
    }

    if (showSettings) {
        ModalBottomSheet(
            onDismissRequest = { showSettings = false },
            sheetState = rememberModalBottomSheetState(),
        ) {
            SettingsSheet(
                focus = focus, brk = brk,
                onFocusChange = {
                    focus = it.coerceIn(PomodoroSettings.focusRange)
                    PomodoroSettings.setFocusMinutes(context, focus)
                    timer.applyDurations(focus, brk)
                },
                onBreakChange = {
                    brk = it.coerceIn(PomodoroSettings.breakRange)
                    PomodoroSettings.setBreakMinutes(context, brk)
                    timer.applyDurations(focus, brk)
                },
                onDone = { showSettings = false },
            )
        }
    }
}

@Composable
private fun PomodoroBody(timer: PomodoroTimerState, sessions: List<PomodoroSession>, padding: PaddingValues) {
    val isFocus = timer.phase == PomodoroPhase.FOCUS
    val reduceMotion = LocalReduceMotion.current
    val targetTint = if (isFocus) SnappetAccents.Tomato else SnappetAccents.Leaf
    val tint by animateColorAsState(
        targetValue = targetTint,
        animationSpec = gated(reduceMotion, SnappetMotion.standard()),
        label = "pomodoroPhaseColor",
    )
    val todayStart = PomodoroStats.startOfDay(System.currentTimeMillis())
    val today = sessions.filter { it.completedAt >= todayStart }
    Column(
        Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(28.dp),
    ) {
        Text(
            timer.phase.title,
            color = tint,
            fontWeight = FontWeight.SemiBold,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(tint.copy(alpha = 0.12f))
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )
        TimerRing(progress = timer.progress.toFloat(), timeText = timer.timeText, tint = tint)
        Controls(timer)
        if (today.isNotEmpty()) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StatCard("${today.size}", if (today.size == 1) "Session" else "Sessions", Modifier.weight(1f))
                StatCard("${today.sumOf { it.minutes }}", "Minutes", Modifier.weight(1f))
            }
        }
        PomodoroFocusChart(PomodoroStats.last7Days(sessions))
    }
}

@Composable
private fun StatCard(value: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TimerRing(progress: Float, timeText: String, tint: Color) {
    val reduceMotion = LocalReduceMotion.current
    val animatedProgress by animateFloatAsState(
        targetValue = progress,
        animationSpec = gated(reduceMotion, SnappetMotion.quick()),
        label = "pomodoroProgress",
    )
    Box(Modifier.size(260.dp).testTag("pomodoro.timeRemaining"), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 18.dp.toPx()
            val inset = stroke / 2
            val arcSize = Size(size.width - stroke, size.height - stroke)
            drawArc(
                color = tint.copy(alpha = 0.15f), startAngle = 0f, sweepAngle = 360f, useCenter = false,
                topLeft = Offset(inset, inset), size = arcSize, style = Stroke(width = stroke),
            )
            drawArc(
                color = tint, startAngle = -90f, sweepAngle = 360f * animatedProgress, useCenter = false,
                topLeft = Offset(inset, inset), size = arcSize, style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Text(timeText, fontSize = 56.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Controls(timer: PomodoroTimerState) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        FilledTonalButton(onClick = { timer.reset() }, modifier = Modifier.weight(1f).testTag("pomodoro.reset")) {
            Icon(Icons.Filled.Refresh, contentDescription = null)
            Text("  Reset")
        }
        if (timer.isRunning) {
            Button(onClick = { timer.pause() }, modifier = Modifier.weight(1f).testTag("pomodoro.pause")) {
                Icon(Icons.Filled.Pause, contentDescription = null)
                Text("  Pause")
            }
        } else {
            Button(onClick = { timer.start() }, modifier = Modifier.weight(1f).testTag("pomodoro.start")) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Text("  Start")
            }
        }
    }
}

@Composable
private fun SettingsSheet(
    focus: Int, brk: Int,
    onFocusChange: (Int) -> Unit, onBreakChange: (Int) -> Unit, onDone: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        StepperRow(
            label = "Focus length", value = focus, suffix = "min",
            rowTag = "pomodoro.focusStepper", valueTag = "pomodoro.focusValue",
            onDec = { onFocusChange(focus - PomodoroSettings.focusStep) },
            onInc = { onFocusChange(focus + PomodoroSettings.focusStep) },
        )
        StepperRow(
            label = "Break length", value = brk, suffix = "min",
            rowTag = "pomodoro.breakStepper", valueTag = "pomodoro.breakValue",
            onDec = { onBreakChange(brk - PomodoroSettings.breakStep) },
            onInc = { onBreakChange(brk + PomodoroSettings.breakStep) },
        )
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth().testTag("pomodoro.settings.done")) {
            Text("Done")
        }
    }
}

@Composable
private fun StepperRow(
    label: String, value: Int, suffix: String,
    rowTag: String, valueTag: String,
    onDec: () -> Unit, onInc: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().testTag(rowTag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, modifier = Modifier.weight(1f))
        Text(
            "$value $suffix",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag(valueTag),
        )
        IconButton(onClick = onDec, modifier = Modifier.testTag("$rowTag.dec")) {
            Icon(Icons.Filled.Remove, contentDescription = "Decrease $label")
        }
        IconButton(onClick = onInc, modifier = Modifier.testTag("$rowTag.inc")) {
            Icon(Icons.Filled.Add, contentDescription = "Increase $label")
        }
    }
}
