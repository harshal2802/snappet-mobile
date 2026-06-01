package com.snappet.mobile.feature.budget

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A spending category with a monthly limit (e.g. "Groceries", 400/mo). Keyed by a stable
 * [categoryId] (UUID string) so [BudgetTransaction] records reference it independently of the
 * Room row id (categories can be deleted/recreated without dangling references). Mirrors the iOS
 * `BudgetCategory` `@Model`.
 */
@Entity(tableName = "budget_categories")
data class BudgetCategory(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Stable identity used to key [BudgetTransaction] records. */
    val categoryId: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** The budgeted spend ceiling for one calendar month. */
    val monthlyLimit: Double,
    /** When the category was created (epoch millis). */
    val createdAt: Long,
)

/**
 * A single spend logged against a category. [categoryId] matches [BudgetCategory.categoryId] so
 * categories can be deleted/recreated without dangling object references. Mirrors the iOS
 * `BudgetTransaction` `@Model`.
 */
@Entity(tableName = "budget_transactions")
data class BudgetTransaction(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Matches [BudgetCategory.categoryId]. */
    val categoryId: String,
    val amount: Double,
    val note: String = "",
    /** When the spend occurred (epoch millis). */
    val date: Long,
)
