package com.snappet.mobile.feature.expense

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A single expense within a group, referenced by [groupId] (matching [ExpenseGroup.groupId]).
 * The split participants are stored as a comma-joined [participantsRaw] String (no TypeConverter);
 * read them via [participants].
 *
 * When [isSettlement] is true this record is a manual settlement ("[payer] paid the single
 * participant [amount] back") rather than a shared expense: it is not split, and feeds the balance
 * math as a direct transfer moving the pair toward zero. Mirrors the iOS `ExpenseRecord` `@Model`.
 */
@Entity(tableName = "expense_records")
data class ExpenseRecord(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Matches [ExpenseGroup.groupId]. */
    val groupId: String,
    val title: String,
    val amount: Double,
    /** The single participant who paid the bill. */
    val payer: String,
    /** Participants the cost is split equally among, comma-joined. Use [participants] to read. */
    val participantsRaw: String,
    val date: Long,
    /** When true, a direct settlement transfer rather than a shared, split expense. */
    val isSettlement: Boolean = false,
) {
    /** Participants the cost is split among (or the lone recipient for a settlement). */
    val participants: List<String>
        get() = if (participantsRaw.isEmpty()) emptyList() else participantsRaw.split(",")

    companion object {
        fun joinParticipants(names: List<String>): String = names.joinToString(",")
    }
}
