package com.snappet.mobile.ui

/**
 * Pure (no Compose / no Android) builders for the spoken `contentDescription` of the suite's
 * custom-drawn charts (issue #98). A raw [androidx.compose.foundation.Canvas] is invisible to
 * TalkBack, so every chart attaches a one-line summary built here. Kept pure so the wording is
 * unit-tested with synthetic inputs in `SnappetTests` — no device, no rendering.
 *
 * Mirrors the spirit of iOS's accessibility summaries: lead with the headline number, then the
 * total, in plain English a screen-reader user can act on ("Focused 3 of 7 days, 85 minutes total").
 */
object ChartAccessibility {

    /**
     * A weekday-bar chart (Home's 7-day actions, Pomodoro's 7-day focus minutes). [values] are the
     * per-day magnitudes oldest→newest; [unit] is the singular noun for one bar's value (e.g.
     * "minute", "action"). Announces how many days had any activity, the total, and the busiest day.
     * [dayLabels] (oldest→newest, e.g. "Mon"…"Sun") name the busiest day when supplied.
     */
    fun weekBarSummary(
        title: String,
        values: List<Int>,
        unit: String,
        dayLabels: List<String> = emptyList(),
    ): String {
        if (values.isEmpty()) return "$title: no data yet."
        val activeDays = values.count { it > 0 }
        val total = values.sum()
        val unitPlural = if (total == 1) unit else "${unit}s"
        if (total == 0) return "$title: no $unitPlural in the last ${values.size} days."
        val maxIdx = values.indices.maxByOrNull { values[it] } ?: 0
        val busiest = dayLabels.getOrNull(maxIdx)
        val busiestClause = if (busiest != null && values[maxIdx] > 0) {
            val v = values[maxIdx]
            " Busiest day $busiest with $v ${if (v == 1) unit else "${unit}s"}."
        } else ""
        return "$title: active $activeDays of ${values.size} days, $total $unitPlural total.$busiestClause"
    }

    /**
     * The Kilter board render: a count of lit holds broken down by role. [roleCounts] maps a role
     * name ("start"/"middle"/"finish"/"foot") to how many holds carry it. Announces the total and the
     * per-role tallies so a non-sighted climber knows the climb's shape without seeing the canvas.
     */
    fun boardSummary(roleCounts: Map<String, Int>): String {
        val total = roleCounts.values.sum()
        if (total == 0) return "Empty board, no holds set."
        // Spoken in route order; only mention roles that are present.
        val order = listOf("start" to "start", "middle" to "hand", "finish" to "finish", "foot" to "foot")
        val parts = order.mapNotNull { (key, spoken) ->
            val n = roleCounts[key] ?: 0
            if (n > 0) "$n $spoken${if (n == 1) "" else "s"}" else null
        }
        return "Climb with $total holds: ${parts.joinToString(", ")}."
    }

    /** Tally hold roles from a list of role-name strings (Kilter holds carry a [String] role). */
    fun roleCountsOf(roles: List<String>): Map<String, Int> = roles.groupingBy { it }.eachCount()
}
