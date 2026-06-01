package com.snappet.mobile.feature.budget

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface BudgetDao {
    @Insert
    suspend fun insertCategory(category: BudgetCategory)

    @Update
    suspend fun updateCategory(category: BudgetCategory)

    @Delete
    suspend fun deleteCategory(category: BudgetCategory)

    @Insert
    suspend fun insertTransaction(transaction: BudgetTransaction)

    @Update
    suspend fun updateTransaction(transaction: BudgetTransaction)

    @Delete
    suspend fun deleteTransaction(transaction: BudgetTransaction)

    /** Remove every transaction belonging to a deleted category (cascade by FK). */
    @Query("DELETE FROM budget_transactions WHERE categoryId = :categoryId")
    suspend fun deleteTransactionsFor(categoryId: String)

    /** All categories, oldest first — mirrors the iOS `@Query(sort: \BudgetCategory.createdAt)`. */
    @Query("SELECT * FROM budget_categories ORDER BY createdAt ASC")
    fun categoriesFlow(): Flow<List<BudgetCategory>>

    /** All transactions across every category. */
    @Query("SELECT * FROM budget_transactions")
    fun transactionsFlow(): Flow<List<BudgetTransaction>>
}
