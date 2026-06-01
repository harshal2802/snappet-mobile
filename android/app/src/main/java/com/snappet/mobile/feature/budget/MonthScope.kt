package com.snappet.mobile.feature.budget

import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * A single calendar month, anchored by any timestamp inside it. Centralises what "a month"
 * means so the summary, per-category rows, donut, and trends all agree. The current month is
 * `MonthScope()`; [previous]/[next] step the scope. Mirrors the iOS `MonthScope`.
 */
data class MonthScope(
    /** Start of the month (e.g. May 1, 00:00) — the canonical anchor we store (epoch millis). */
    val start: Long,
) {
    companion object {
        /** Builds the month that contains [anchor] (defaults to now). */
        fun forAnchor(anchor: Long = System.currentTimeMillis()): MonthScope {
            val cal = Calendar.getInstance().apply {
                timeInMillis = anchor
                set(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            return MonthScope(cal.timeInMillis)
        }

        /** The current month. */
        fun current(): MonthScope = forAnchor()
    }

    /** Exclusive upper bound — the start of the next month. */
    val end: Long
        get() {
            val cal = Calendar.getInstance().apply {
                timeInMillis = start
                add(Calendar.MONTH, 1)
            }
            return cal.timeInMillis
        }

    /** True if [date] falls within this month. */
    fun contains(date: Long): Boolean = date in start until end

    /** The month immediately before this one. */
    fun previous(): MonthScope {
        val cal = Calendar.getInstance().apply {
            timeInMillis = start
            add(Calendar.MONTH, -1)
        }
        return forAnchor(cal.timeInMillis)
    }

    /** The month immediately after this one. */
    fun next(): MonthScope {
        val cal = Calendar.getInstance().apply {
            timeInMillis = start
            add(Calendar.MONTH, 1)
        }
        return forAnchor(cal.timeInMillis)
    }

    /** True if this is the current calendar month (used to cap forward navigation). */
    val isCurrent: Boolean
        get() = contains(System.currentTimeMillis())

    /** A label for the month header, e.g. "May 2026". */
    val label: String
        get() = monthYearFmt.format(Date(start))
}

private val monthYearFmt = SimpleDateFormat("MMMM yyyy", Locale.getDefault())

/** Formats a money amount in the user's local currency (e.g. "$400.00"). Mirrors iOS `asCurrency`. */
fun Double.asCurrency(): String = NumberFormat.getCurrencyInstance().format(this)
