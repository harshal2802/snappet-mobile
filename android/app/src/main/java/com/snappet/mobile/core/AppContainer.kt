package com.snappet.mobile.core

import android.content.Context
import com.snappet.mobile.feature.pomodoro.PomodoroAlerts
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import com.snappet.mobile.feature.pomodoro.PomodoroSettings
import com.snappet.mobile.feature.pomodoro.PomodoroStateStore
import com.snappet.mobile.feature.pomodoro.PomodoroTimerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Process-wide dependency holder — the one place the Room store and [SnappetCore] are wired,
 * mirroring the iOS `AppModel`. No DI framework; a single lazily-built instance injected via
 * a Compose `CompositionLocal` ([com.snappet.mobile.LocalAppContainer]).
 */
class AppContainer private constructor(
    private val appContext: Context,
    val database: SnappetDatabase,
) {
    val core: SnappetCore by lazy { SnappetCore(database.usageDao()) }
    /** Export/import of the whole store as one SAF file (issue #84). */
    val backup: SnappetBackupManager by lazy { SnappetBackupManager(database) }
    /** Pending deep-link / shortcut / widget navigation (issues #91, #99). Mirrors iOS SuiteRouter. */
    val router: SuiteRouter by lazy { SuiteRouter() }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /**
     * The app-owned Pomodoro engine (issue #85): owned here — not `remember {}`-scoped
     * to the composable — so backing out, tab switches, and rotation never kill a
     * running session, and process death restores from the persisted schedule (phases
     * completed while away are logged on the way back in). One seam
     * (`onScheduleChanged`) drives persistence, the foreground-service countdown
     * notification, and the exact phase-end alarm. Mirrors iOS `AppModel.pomodoro` (#70).
     */
    val pomodoro: PomodoroTimerState by lazy {
        val alerts = PomodoroAlerts(appContext)
        val timer = PomodoroTimerState(
            focusMinutes = PomodoroSettings.focusMinutes(appContext),
            breakMinutes = PomodoroSettings.breakMinutes(appContext),
            onFocusCompleted = { minutes, completedAtMillis ->
                scope.launch {
                    database.pomodoroDao().insert(
                        PomodoroSession(minutes = minutes, completedAt = completedAtMillis))
                    core.log("pomodoro", "session", "Focused $minutes min", minutes.toDouble())
                }
            },
        )
        timer.onScheduleChanged = { phase, end ->
            if (end != null) {
                PomodoroStateStore.save(appContext, phase, end)
                alerts.sync(phase, end)
            } else {
                if (timer.isPaused) PomodoroStateStore.savePaused(appContext, phase, timer.remaining)
                else PomodoroStateStore.clear(appContext)
                alerts.clear()
            }
        }
        // Process death/container rebuild: pick the session back up from the persisted
        // schedule (a past end walks the elapsed boundaries and logs completed focuses).
        when (val saved = PomodoroStateStore.load(appContext)) {
            is PomodoroStateStore.Saved.Running -> timer.restore(saved.phase, saved.endTimeMillis)
            is PomodoroStateStore.Saved.Paused -> timer.restorePaused(saved.phase, saved.remainingSeconds)
            null -> Unit
        }
        timer
    }

    companion object {
        @Volatile private var instance: AppContainer? = null

        /**
         * Returns the shared container, building the store on first use. When [freshInMemory]
         * is set (UI tests), it always rebuilds against a throwaway in-memory database so each
         * test run starts from an empty, isolated store — the Android analogue of the iOS
         * `-uiTestFreshStore` launch argument.
         */
        fun get(context: Context, freshInMemory: Boolean = false): AppContainer {
            if (freshInMemory) {
                // Fresh runs drop any persisted session AND the displaced container's
                // service/alarm/notifications, so timer tests can't leak into each other.
                PomodoroStateStore.clear(context.applicationContext)
                PomodoroAlerts(context.applicationContext).clear()
                val fresh = AppContainer(context.applicationContext,
                                         SnappetDatabase.buildInMemory(context.applicationContext))
                instance = fresh
                return fresh
            }
            return instance ?: synchronized(this) {
                instance ?: AppContainer(context.applicationContext,
                                         SnappetDatabase.build(context.applicationContext)).also { instance = it }
            }
        }
    }
}
