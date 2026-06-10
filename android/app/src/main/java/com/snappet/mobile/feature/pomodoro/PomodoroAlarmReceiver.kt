package com.snappet.mobile.feature.pomodoro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires at a Pomodoro phase boundary (exact wake-from-Doze alarm, issue #85) and posts
 * the "phase complete" alert — including when the app process has been killed since the
 * phase started; the persisted timer state catches the app up on next open.
 */
class PomodoroAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val phase = runCatching {
            PomodoroPhase.valueOf(intent.getStringExtra(PomodoroService.EXTRA_PHASE) ?: "")
        }.getOrDefault(PomodoroPhase.FOCUS)
        PomodoroAlerts.postPhaseEnd(context, phase)
    }
}
