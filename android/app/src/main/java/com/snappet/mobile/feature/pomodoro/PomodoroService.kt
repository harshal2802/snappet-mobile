package com.snappet.mobile.feature.pomodoro

import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.snappet.mobile.R

/**
 * Foreground service hosting the **ongoing countdown notification** while a Pomodoro
 * phase runs (issue #85) — the Android counterpart of the iOS Live Activity. The
 * notification is a system chronometer counting down to the phase's absolute end, so it
 * ticks with zero app CPU and stays correct however long the app is backgrounded. The
 * service holds no timer logic — `PomodoroTimerState` stays the single source of truth;
 * this just keeps the process alive through a phase and the countdown visible.
 */
class PomodoroService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val phaseName = intent?.getStringExtra(EXTRA_PHASE) ?: PomodoroPhase.FOCUS.name
        val end = intent?.getLongExtra(EXTRA_END, 0L) ?: 0L
        val phase = runCatching { PomodoroPhase.valueOf(phaseName) }.getOrDefault(PomodoroPhase.FOCUS)
        PomodoroAlerts.ensureChannels(this)
        startForeground(PomodoroAlerts.RUNNING_NOTIFICATION_ID, countdownNotification(this, phase, end))
        // If the system kills us, the persisted endTime + the chained exact alarm still
        // cover the user; nothing to resume here.
        return START_NOT_STICKY
    }

    companion object {
        const val EXTRA_PHASE = "phase"
        const val EXTRA_END = "endTimeMillis"

        /** The ongoing countdown — system-ticked chronometer to the phase's absolute end.
         *  Shared with the receivers, which refresh it via plain notify() (same id). */
        fun countdownNotification(context: android.content.Context, phase: PomodoroPhase, end: Long) =
            NotificationCompat.Builder(context, PomodoroAlerts.RUNNING_CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(if (phase == PomodoroPhase.FOCUS) "Focusing" else "On a break")
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setWhen(end)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(
                    PendingIntent.getActivity(
                        context, 0,
                        context.packageManager.getLaunchIntentForPackage(context.packageName),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ))
                .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
                .build()
    }
}
