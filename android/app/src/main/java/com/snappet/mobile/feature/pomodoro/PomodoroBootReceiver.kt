package com.snappet.mobile.feature.pomodoro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * AlarmManager alarms don't survive a reboot, but the persisted Pomodoro schedule does
 * (issue #85 review): re-arm the boundary chain from the saved anchor — posting any
 * boundary that elapsed during the reboot — so a session started before the restart
 * still alerts. No-op when nothing was running.
 */
class PomodoroBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        PomodoroAlerts(context.applicationContext).advanceDueBoundaries()
    }
}
