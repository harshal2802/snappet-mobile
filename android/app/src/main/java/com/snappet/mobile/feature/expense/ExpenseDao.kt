package com.snappet.mobile.feature.expense

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface ExpenseDao {
    @Insert
    suspend fun insertGroup(group: ExpenseGroup)

    @Update
    suspend fun updateGroup(group: ExpenseGroup)

    @Delete
    suspend fun deleteGroup(group: ExpenseGroup)

    @Insert
    suspend fun insertExpense(record: ExpenseRecord)

    @Update
    suspend fun updateExpense(record: ExpenseRecord)

    @Delete
    suspend fun deleteExpense(record: ExpenseRecord)

    /** Issue #88: deleting a group must sweep its records — `groupId` is a flat
     *  reference (no Room relation), so nothing cascades on its own (mirrors iOS). */
    @Query("DELETE FROM expense_records WHERE groupId = :groupId")
    suspend fun deleteExpensesFor(groupId: String)

    /** All groups, newest first — mirrors the iOS `@Query(sort: \ExpenseGroup.createdAt, .reverse)`. */
    @Query("SELECT * FROM expense_groups ORDER BY createdAt DESC")
    fun groupsFlow(): Flow<List<ExpenseGroup>>

    /** All expense records across every group, newest first. */
    @Query("SELECT * FROM expense_records ORDER BY date DESC")
    fun expensesFlow(): Flow<List<ExpenseRecord>>
}
