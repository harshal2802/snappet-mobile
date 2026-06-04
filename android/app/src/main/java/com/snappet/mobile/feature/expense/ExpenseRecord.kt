package com.snappet.mobile.feature.expense

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One line item on an itemized receipt: a name, its price, and the people who share it
 * equally. Plain value type (no Room/Compose) so the split math stays testable; persisted on
 * [ExpenseRecord] as an encoded [ExpenseRecord.itemsRaw] string. Mirrors the iOS `ReceiptItem`.
 */
data class ReceiptItem(
    val name: String,
    val price: Double,
    val assignees: List<String> = emptyList(),
)

/**
 * A single expense within a group, referenced by [groupId] (matching [ExpenseGroup.groupId]).
 * The split participants are stored as a comma-joined [participantsRaw] String (no TypeConverter);
 * read them via [participants].
 *
 * Three shapes share this one entity:
 *  - **Even split** ([itemsRaw] empty, [isSettlement] false): [amount] split equally among [participants].
 *  - **Settlement** ([isSettlement] true): a direct transfer — [payer] paid the lone participant [amount].
 *  - **Itemized receipt** ([itemsRaw] non-empty): each [ReceiptItem] split among its own assignees,
 *    with [taxAmount] allocated proportionally and [discountAmount] credited proportionally (see
 *    [ReceiptSplit]); [amount] is the grand total the [payer] paid. Mirrors the iOS `ExpenseRecord`.
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
    /** Encoded receipt line items (empty for an even-split/settlement). Read via [items]. */
    val itemsRaw: String = "",
    /** Tax for an itemized receipt, allocated proportional to each person's pre-tax share. */
    val taxAmount: Double = 0.0,
    /** Discount/instant-savings for an itemized receipt, credited proportional to pre-discount share. */
    val discountAmount: Double = 0.0,
) {
    /** Participants the cost is split among (or the lone recipient for a settlement). */
    val participants: List<String>
        get() = if (participantsRaw.isEmpty()) emptyList() else participantsRaw.split(",")

    /** The receipt line items (empty for an even-split/settlement). */
    val items: List<ReceiptItem>
        get() = decodeItems(itemsRaw)

    /** An itemized receipt rather than an even split / settlement. */
    val isReceipt: Boolean
        get() = itemsRaw.isNotEmpty()

    companion object {
        fun joinParticipants(names: List<String>): String = names.joinToString(",")

        // Control-character separators (Record/Unit/Group) — never present in receipt text, so we
        // can encode items without a Room TypeConverter, matching the repo's comma-joined approach.
        private const val RS = '\u001E' // between items
        private const val US = '\u001F' // between an item's fields (name, price, assignees)
        private const val GS = '\u001D' // between assignee names

        fun encodeItems(items: List<ReceiptItem>): String =
            items.joinToString(RS.toString()) { item ->
                listOf(item.name, item.price.toString(), item.assignees.joinToString(GS.toString()))
                    .joinToString(US.toString())
            }

        fun decodeItems(raw: String): List<ReceiptItem> {
            if (raw.isEmpty()) return emptyList()
            return raw.split(RS).mapNotNull { chunk ->
                val parts = chunk.split(US)
                if (parts.size < 2) return@mapNotNull null
                val price = parts[1].toDoubleOrNull() ?: return@mapNotNull null
                val assignees = if (parts.size >= 3 && parts[2].isNotEmpty()) parts[2].split(GS) else emptyList()
                ReceiptItem(parts[0], price, assignees)
            }
        }
    }
}
