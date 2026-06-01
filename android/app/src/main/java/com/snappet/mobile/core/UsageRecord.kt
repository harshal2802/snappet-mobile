package com.snappet.mobile.core

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * Snappet Core — the shared on-device data layer.
 *
 * Every mini-app logs what the user did to a single `UsageRecord` table; the Home
 * dashboard aggregates across all of them to show "historical sub-app usage." This
 * is the contract that turns a bag of mini-apps into a suite whose value compounds.
 * On-device only (Room / local store) — nothing is transmitted.
 */
@Entity(tableName = "usage_records")
data class UsageRecord(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** The mini-app that produced this record (matches `AppModule.id`). */
    val module: String,
    /** A short verb for what happened (e.g. "open", "session", "export", "entry"). */
    val action: String,
    /** Human-readable one-line summary shown in the activity feed. */
    val summary: String,
    /** Optional numeric the dashboard can sum/chart (minutes, dollars, reps, …). */
    val metric: Double? = null,
    /** Epoch milliseconds. */
    val timestamp: Long = System.currentTimeMillis(),
)
