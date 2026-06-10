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
        // phase end even if the process is later killed (USE_EXACT_ALARM keeps the exact
        // path the default for a timer app; inexact fallback if access is ever off).
        armAlarm(endTimeMillis)
    }

    /** Pause/reset: drop the ongoing notification and the pending alarm. */
    fun clear() {
        context.stopService(Intent(context, PomodoroService::class.java))
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(alarmIntent())
        // Also clear both notifications so neither a stale alert nor a receiver-posted
        // countdown (not owned by the service) lingers.
        notificationManager(context).cancel(PHASE_END_NOTIFICATION_ID)
        notificationManager(context).cancel(RUNNING_NOTIFICATION_ID)
    }

    private fun alarmIntent(): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,   // one stable code: re-scheduling replaces, cancel hits it
            Intent(context, PomodoroAlarmReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * Re-arm the boundary alarm without starting the foreground service — safe from a
     * receiver running in a background-started process. The receivers chain the WHOLE
     * session off this: each boundary posts its alert, computes the next boundary from
     * the persisted anchor ([PomodoroSchedule] — the same walk the engine's restore
     * does, so they can't disagree), refreshes the countdown notification via plain
     * notify(), and arms the next alarm (issue #85 review: a single un-chained alarm
     * meant every boundary after the first was silent and the countdown went stale).
     */
    fun advanceDueBoundaries(now: Long = System.currentTimeMillis()) {
        val saved = PomodoroStateStore.load(context) as? PomodoroStateStore.Saved.Running ?: return
        val position = PomodoroSchedule.at(
            saved.phase, saved.endTimeMillis,
            PomodoroSettings.focusMinutes(context), PomodoroSettings.breakMinutes(context), now)
        position.endedPhase?.let { postPhaseEnd(context, it) }
        armAlarm(position.endTimeMillis)
        postCountdown(position.phase, position.endTimeMillis)
    }

    private fun armAlarm(endTimeMillis: Long) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
        if (canExact) {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endTimeMillis, alarmIntent())
        } else {
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endTimeMillis, alarmIntent())
        }
    }

    /** The countdown notification WITHOUT the service (background-safe refresh; replaces
     *  the FGS notification when the service is still alive — same id/channel). */
    private fun postCountdown(phase: PomodoroPhase, endTimeMillis: Long) {
        notificationManager(context).notify(
            RUNNING_NOTIFICATION_ID,
            PomodoroService.countdownNotification(context, phase, endTimeMillis))
    }

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
