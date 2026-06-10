package com.snappet.mobile.feature.pomodoro

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Everything that lets a running Pomodoro phase reach the user outside the app
 * (issue #85): the ongoing chronometer notification (via [PomodoroService]), the exact
 * phase-end alarm (via [PomodoroAlarmReceiver]), and the completion alert itself —
 * Android's counterpart to the iOS Live Activity + scheduled-notification pair (#70).
 * Every entry point is safe to call when notifications are unauthorized (the system
 * just drops them).
 */
class PomodoroAlerts(private val context: Context) {

    /** Reflect a (re)started or auto-advanced phase: ongoing notification + exact alarm. */
    fun sync(phase: PomodoroPhase, endTimeMillis: Long) {
        ensureChannels(context)
        // Ongoing chronometer notification, hosted by the foreground service.
        val service = Intent(context, PomodoroService::class.java)
            .putExtra(PomodoroService.EXTRA_PHASE, phase.name)
            .putExtra(PomodoroService.EXTRA_END, endTimeMillis)
        context.startForegroundService(service)

        // Exact wake-from-Doze alarm at the boundary, so a locked phone still hears the
        // phase end even if the process is later killed. Falls back to an inexact alarm
        // when the user hasn't granted exact-alarm access (API 31+ special access).
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
        if (canExact) {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endTimeMillis, alarmIntent(phase))
        } else {
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endTimeMillis, alarmIntent(phase))
        }
    }

    /** Pause/reset: drop the ongoing notification and the pending alarm. */
    fun clear() {
        context.stopService(Intent(context, PomodoroService::class.java))
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(alarmIntent(PomodoroPhase.FOCUS))
        // Also clear any delivered phase-end alert so a stale banner doesn't linger.
        notificationManager(context).cancel(PHASE_END_NOTIFICATION_ID)
    }

    private fun alarmIntent(phase: PomodoroPhase): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,   // one stable code: re-scheduling replaces, cancel hits it
            Intent(context, PomodoroAlarmReceiver::class.java)
                .putExtra(PomodoroService.EXTRA_PHASE, phase.name),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    companion object {
        const val RUNNING_CHANNEL = "pomodoro.running"
        const val ALERT_CHANNEL = "pomodoro.alerts"
        const val RUNNING_NOTIFICATION_ID = 41
        const val PHASE_END_NOTIFICATION_ID = 42
        private const val ALARM_REQUEST_CODE = 4100

        fun ensureChannels(context: Context) {
            val manager = notificationManager(context)
            manager.createNotificationChannel(
                NotificationChannel(RUNNING_CHANNEL, "Focus timer",
                    NotificationManager.IMPORTANCE_LOW).apply {
                    description = "The running focus/break countdown"
                })
            manager.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL, "Phase complete",
                    NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Focus or break finished"
                })
        }

        fun notificationManager(context: Context): NotificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        /**
         * Pure copy for the phase-end alert — `endedPhase` is the phase that just
         * finished. Mirrors the iOS `phaseEndContent` and is unit-tested on the JVM.
         */
        fun phaseEndContent(endedPhase: PomodoroPhase): Pair<String, String> = when (endedPhase) {
            PomodoroPhase.FOCUS -> "Focus complete" to "Nice work — time for a break."
            PomodoroPhase.BREAK -> "Break's over" to "Back to focus."
        }

        /** Post the phase-end alert (from the alarm receiver, possibly with the app dead). */
        fun postPhaseEnd(context: Context, endedPhase: PomodoroPhase) {
            ensureChannels(context)
            val (title, body) = phaseEndContent(endedPhase)
            val open = PendingIntent.getActivity(
                context, 0,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, ALERT_CHANNEL)
                .setSmallIcon(com.snappet.mobile.R.drawable.ic_launcher_foreground)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .build()
            notificationManager(context).notify(PHASE_END_NOTIFICATION_ID, notification)
        }
    }
}
