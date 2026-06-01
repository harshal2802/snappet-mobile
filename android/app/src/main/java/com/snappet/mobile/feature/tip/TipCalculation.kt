package com.snappet.mobile.feature.tip

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A single committed tip calculation, persisted so the Tip mini-app can show a history of past
 * splits. Stored flat (no relationships): each row is a self-contained snapshot of the inputs
 * (`bill`, `tipPct`, `people`) and the derived outputs (`tipAmount`, `total`) at the moment the
 * bill committed, keyed for display by `createdAt`. Mirrors the iOS `TipCalculation` `@Model`.
 */
@Entity(tableName = "tip_calculations")
data class TipCalculation(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** The raw bill amount the tip was computed on. */
    val bill: Double,
    /** Effective tip percentage applied (may be fractional when round-up adjusts it). */
    val tipPct: Double,
    /** Number of people the total was split between. */
    val people: Int,
    /** Tip portion in the bill's currency. */
    val tipAmount: Double,
    /** Grand total (bill + tip), after any round-up. */
    val total: Double,
    /** When the calculation was committed (epoch millis; used for newest-first sorting). */
    val createdAt: Long,
)
