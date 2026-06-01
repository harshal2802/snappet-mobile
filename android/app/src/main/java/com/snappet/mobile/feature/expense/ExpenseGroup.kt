package com.snappet.mobile.feature.expense

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A group of people who share expenses (e.g. "Trip", "Roommates"). Keyed by a stable
 * [groupId] (UUID string) so [ExpenseRecord] rows can reference it independently of the Room
 * row id. Participants are stored as a comma-joined [participantsRaw] String (no TypeConverter);
 * read them via [participants]. Mirrors the iOS `ExpenseGroup` `@Model`.
 */
@Entity(tableName = "expense_groups")
data class ExpenseGroup(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Stable identity used to key [ExpenseRecord] rows via `groupId`. */
    val groupId: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** Participant display names, comma-joined for storage. Use [participants] to read. */
    val participantsRaw: String,
    val createdAt: Long,
) {
    /** Participant display names, in order. */
    val participants: List<String>
        get() = if (participantsRaw.isEmpty()) emptyList() else participantsRaw.split(",")

    companion object {
        /** Join a participant list into the stored comma-separated form. */
        fun joinParticipants(names: List<String>): String = names.joinToString(",")
    }
}
