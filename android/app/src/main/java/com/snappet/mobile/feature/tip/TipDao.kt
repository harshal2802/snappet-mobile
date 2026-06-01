package com.snappet.mobile.feature.tip

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface TipDao {
    @Insert
    suspend fun insert(calculation: TipCalculation)

    /** All calculations, newest first — drives the history list. */
    @Query("SELECT * FROM tip_calculations ORDER BY createdAt DESC")
    fun allFlow(): Flow<List<TipCalculation>>
}
