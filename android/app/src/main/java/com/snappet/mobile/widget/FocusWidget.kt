package com.snappet.mobile.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider as DayNightColorProvider
import androidx.glance.layout.Alignment
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
import com.snappet.mobile.MainActivity
import com.snappet.mobile.ui.home.TodayData
import kotlinx.coroutines.flow.first

/**
 * A launcher widget for focus time (issue #99): today's focused minutes + a "Start focus" button that
 * opens the app straight into the Pomodoro module (carrying the module id through MainActivity →
 * SuiteRouter, the same path as a launcher shortcut). Reads the same Pomodoro Room flow the in-app
 * Today card reads (via [TodayData]). Mirrors the iOS SnappetWidgets focus tile.
 *
 * Starting the foreground-service countdown from a widget tap needs a started activity for the FGS
 * permission anyway, so "Start focus" routes through the app — recorded as a deliberate choice in
 * decisions.md (the headless check-off lives on the Habit widget where no service is involved).
 */
class FocusWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dao = com.snappet.mobile.core.AppContainer.get(context.applicationContext).database.pomodoroDao()
        val sessions = runCatching { dao.allFlow().first() }.getOrDefault(emptyList())
        val focus = TodayData.focus(sessions)
        provideContent { Content(focus.minutesToday) }
    }

    @Composable
    private fun Content(minutesToday: Int) {
        val accent = Color(0xFFFF5A4D)
        Column(
            GlanceModifier.fillMaxSize()
                .background(DayNightColorProvider(day = Color(0xFFF6F6F6), night = Color(0xFF1C1C1E)))
                .padding(12.dp)
                .clickable(actionStartActivity<MainActivity>(actionParametersOf(moduleKey to "pomodoro"))),
            verticalAlignment = Alignment.Top,
        ) {
            Text("Focus", style = TextStyle(fontWeight = FontWeight.Bold, color = ColorProvider(accent)))
            Spacer(GlanceModifier.size(4.dp))
            Text(if (minutesToday > 0) "$minutesToday min today" else "No focus yet",
                style = TextStyle(fontWeight = FontWeight.Medium,
                    color = DayNightColorProvider(day = Color.Black, night = Color.White)))
            Spacer(GlanceModifier.defaultWeight())
            Row(
                GlanceModifier.fillMaxWidth()
                    .background(ColorProvider(accent.copy(alpha = 0.18f)))
                    .padding(8.dp)
                    .clickable(actionStartActivity<MainActivity>(actionParametersOf(moduleKey to "pomodoro"))),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("▶ Start focus", style = TextStyle(color = ColorProvider(accent), fontWeight = FontWeight.Medium))
            }
        }
    }
}
