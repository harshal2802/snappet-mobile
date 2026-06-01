package com.snappet.mobile.feature.journal

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One journal entry in the shared store. Mirrors the iOS `JournalEntry` `@Model`.
 *
 * Tags are stored as a single comma-joined [String] (normalized: trimmed, lowercased,
 * de-duplicated, empties dropped) to avoid needing a Room `TypeConverter` for `List`.
 * Use [tagList] / [joinTags] / [normalizeTags] to move between the two representations.
 */
@Entity(tableName = "journal_entries")
data class JournalEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Optional user-provided title. May be empty. */
    val title: String,
    /** The entry's free-form text. */
    val body: String,
    /** Comma-joined, normalized tags (lowercased, de-duplicated). May be empty. */
    val tags: String,
    /** When the entry was first created (epoch millis). Drives newest-first ordering. */
    val createdAt: Long,
    /** When the entry was last edited (epoch millis; equals [createdAt] until first edit). */
    val updatedAt: Long,
) {
    /** The stored [tags] string split back into a normalized list. */
    val tagList: List<String>
        get() = if (tags.isBlank()) emptyList() else tags.split(",").filter { it.isNotEmpty() }

    companion object {
        /**
         * Normalize raw tag strings: trim whitespace, lowercase, drop empties, and de-duplicate
         * while preserving first-seen order. Mirrors iOS `JournalEntry.normalizeTags`.
         */
        fun normalizeTags(raw: List<String>): List<String> {
            val seen = HashSet<String>()
            val result = ArrayList<String>()
            for (tag in raw) {
                val normalized = tag.trim().lowercase()
                if (normalized.isEmpty() || !seen.add(normalized)) continue
                result.add(normalized)
            }
            return result
        }

        /** Join a list of tags into the stored comma-separated form (after normalizing). */
        fun joinTags(raw: List<String>): String = normalizeTags(raw).joinToString(",")
    }
}
