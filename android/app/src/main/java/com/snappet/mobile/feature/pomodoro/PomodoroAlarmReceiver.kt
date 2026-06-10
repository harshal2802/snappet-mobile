package com.snappet.mobile.feature.pomodoro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires at a Pomodoro phase boundary (exact wake-from-Doze alarm, issue #85). Posts the
 * "phase complete" alert AND advances the chain — computes the now-running phase from
 * the persisted anchor, refreshes the countdown notification, and arms the NEXT
 * boundary's alarm — so every boundary alerts even with the screen off or the process
 * dead (the engine catches up from the same anchor on next open and logs the sessions).
 */
class PomodoroAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PomodoroAlerts(context.applicationContext).advanceDueBoundaries()
    }
}
