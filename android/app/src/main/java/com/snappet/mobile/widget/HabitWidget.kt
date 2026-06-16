package com.snappet.mobile.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.glance.color.ColorProvider as DayNightColorProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.action.actionStartActivity
import com.snappet.mobile.MainActivity
import com.snappet.mobile.core.AppContainer
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.habit.HabitStats
import com.snappet.mobile.ui.home.TodayData
import kotlinx.coroutines.flow.first

/**
 * A launcher widget for habits (issue #99): today's done/total + best streak, and a tap target that
 * checks off the next undone habit **without opening the app** (headless Glance [ActionCallback] →
 * Room write → widget refresh). Tapping the body opens the Habits module. Reads the same Room flows
 * the in-app Today cards read (via [TodayData]). Mirrors the iOS SnappetWidgets habit tile.
 */
class HabitWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dao = AppContainer.get(context.applicationContext).database.habitDao()
        // Suspend one-shot reads happen HERE (not in the composable); Glance re-runs provideGlance on
        // updateAll() after a check-off, so the snapshot stays fresh.
        val habits = runCatching { dao.habitsFlow().first() }.getOrDefault(emptyList())
        val completions = runCatching { dao.completionsFlow().first() }.getOrDefault(emptyList())
        provideContent { Content(habits, completions) }
    }

    @Composable
    private fun Content(
        habits: List<com.snappet.mobile.feature.habit.Habit>,
        completions: List<HabitCompletion>,
    ) {
        val today = TodayData.habits(habits, completions)
        val accent = Color(0xFF34C759)

        Column(
            GlanceModifier.fillMaxSize()
                .background(DayNightColorProvider(day = Color(0xFFF6F6F6), night = Color(0xFF1C1C1E)))
                .padding(12.dp)
                .clickable(actionStartActivity<MainActivity>(
                    actionParametersOf(moduleKey to "habit"))),
            verticalAlignment = Alignment.Top,
        ) {
            Text("Habits", style = TextStyle(fontWeight = FontWeight.Bold,
                color = ColorProvider(accent)))
            Spacer(GlanceModifier.size(4.dp))
            Text("${today.doneToday}/${today.total} today",
                style = TextStyle(fontWeight = FontWeight.Medium,
                    color = DayNightColorProvider(day = Color.Black, night = Color.White)))
            if (today.bestStreak > 0) {
                Text("🔥 ${today.bestStreak}-day streak",
                    style = TextStyle(color = ColorProvider(Color(0xFFFF9500))))
            }
            Spacer(GlanceModifier.defaultWeight())
            val firstUndone = habits.firstOrNull { !TodayData.isHabitDoneToday(it.habitId, completions) }
            if (firstUndone != null) {
                Row(
                    GlanceModifier.fillMaxWidth()
                        .background(ColorProvider(accent.copy(alpha = 0.18f)))
                        .padding(8.dp)
                        .clickable(actionRunCallback<CheckHabitAction>(
                            actionParametersOf(HabitIdKey to firstUndone.habitId))),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("✓ ${firstUndone.name}",
                        style = TextStyle(color = ColorProvider(accent), fontWeight = FontWeight.Medium))
                }
            } else if (today.total > 0) {
                Text("All done — nice.", style = TextStyle(color = ColorProvider(accent)))
            }
        }
    }
}

/** Headless check-off: writes a completion for today, then refreshes every habit widget. */
class CheckHabitAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val habitId = parameters[HabitIdKey] ?: return
        val container = AppContainer.get(context.applicationContext)
        val dao = container.database.habitDao()
        val today = HabitStats.startOfDay(System.currentTimeMillis())
        val completions = dao.completionsFlow().first()
        val existing = completions.firstOrNull { it.habitId == habitId && it.day == today }
        if (existing == null) {
            dao.insertCompletion(HabitCompletion(habitId = habitId, day = today))
            container.core.log("habit", "complete", "Completed a habit (widget)")
        }
        HabitWidget().updateAll(context)
    }
}
