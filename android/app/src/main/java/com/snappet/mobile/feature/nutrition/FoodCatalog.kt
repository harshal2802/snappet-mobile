package com.snappet.mobile.feature.nutrition

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

data class FoodItem(
    val id: String,
    val name: String,
    val brandName: String = "",
    val dataSource: String = "seed",
    val kcalPer100g: Double,
    val proteinPer100g: Double,
    val carbsPer100g: Double,
    val fatPer100g: Double,
    val nutriScore: String = "C",
    val barcode: String = "",
)

/**
 * Read-only wrapper around the bundled `food.sqlite3` catalog (Open Food Facts + USDA FDC).
 * Falls back to [seedData] when the asset has not yet been bundled (CI / simulator builds).
 * Mirrors iOS `FoodCatalog` — same SQLite schema and seed set.
 */
class FoodCatalog(context: Context) {

    private var db: SQLiteDatabase? = null

    init {
        val file = context.getDatabasePath("food.sqlite3")
        if (file.exists()) {
            runCatching {
                db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
            }
        }
    }

    fun search(query: String, limit: Int = 20): List<FoodItem> {
        val d = db
        if (d != null && query.isNotBlank()) {
            val cursor = d.rawQuery(
                """
                SELECT id, product_name, brands, data_source,
                       energy_kcal_100g, proteins_100g, carbohydrates_100g, fat_100g,
                       nutriscore_grade, code
                FROM foods
                WHERE product_name LIKE ? OR brands LIKE ?
                ORDER BY product_name ASC LIMIT ?
                """.trimIndent(),
                arrayOf("%$query%", "%$query%", limit.toString()),
            )
            cursor.use {
                val out = mutableListOf<FoodItem>()
                while (cursor.moveToNext()) out += row(cursor)
                return out
            }
        }
        return seedData
            .filter { query.isBlank() || it.name.contains(query, ignoreCase = true) || it.brandName.contains(query, ignoreCase = true) }
            .take(limit)
    }

    fun lookup(barcode: String): FoodItem? {
        val d = db
        if (d != null && barcode.isNotBlank()) {
            val cursor = d.rawQuery(
                """
                SELECT id, product_name, brands, data_source,
                       energy_kcal_100g, proteins_100g, carbohydrates_100g, fat_100g,
                       nutriscore_grade, code
                FROM foods WHERE code = ? LIMIT 1
                """.trimIndent(),
                arrayOf(barcode),
            )
            cursor.use { if (cursor.moveToFirst()) return row(cursor) }
        }
        return seedData.firstOrNull { it.barcode == barcode }
    }

    fun close() { db?.close() }

    private fun row(cursor: Cursor) = FoodItem(
        id           = cursor.getString(0) ?: "",
        name         = cursor.getString(1) ?: "",
        brandName    = cursor.getString(2) ?: "",
        dataSource   = cursor.getString(3) ?: "off",
        kcalPer100g  = cursor.getDouble(4),
        proteinPer100g = cursor.getDouble(5),
        carbsPer100g = cursor.getDouble(6),
        fatPer100g   = cursor.getDouble(7),
        nutriScore   = cursor.getString(8)?.uppercase() ?: "C",
        barcode      = cursor.getString(9) ?: "",
    )

    companion object {
        val seedData: List<FoodItem> = listOf(
            FoodItem("seed-001", "Chicken Breast",  "Generic", "seed", 165.0, 31.0,  0.0,  3.6, "A"),
            FoodItem("seed-002", "Brown Rice",       "Generic", "seed", 216.0,  4.5, 44.8,  1.8, "B"),
            FoodItem("seed-003", "Broccoli",         "Generic", "seed",  34.0,  2.8,  7.0,  0.4, "A"),
            FoodItem("seed-004", "Whole Milk",       "Generic", "seed",  61.0,  3.2,  4.8,  3.3, "C"),
            FoodItem("seed-005", "Large Egg",        "Generic", "seed", 155.0, 13.0,  1.1, 11.0, "B"),
            FoodItem("seed-006", "Banana",           "Generic", "seed",  89.0,  1.1, 23.0,  0.3, "A"),
            FoodItem("seed-007", "Oats",             "Generic", "seed", 389.0, 16.9, 66.3,  6.9, "A"),
            FoodItem("seed-008", "Greek Yoghurt",    "Generic", "seed",  97.0,  9.0,  3.6,  5.0, "B"),
            FoodItem("seed-009", "Salmon",           "Generic", "seed", 208.0, 20.0,  0.0, 13.0, "A"),
            FoodItem("seed-010", "White Bread",      "Generic", "seed", 265.0,  9.0, 49.0,  3.2, "D"),
            FoodItem("seed-011", "Cheddar Cheese",   "Generic", "seed", 402.0, 25.0,  1.3, 33.0, "D"),
            FoodItem("seed-012", "Apple",            "Generic", "seed",  52.0,  0.3, 14.0,  0.2, "A"),
            FoodItem("seed-013", "Olive Oil",        "Generic", "seed", 884.0,  0.0,  0.0, 100.0, "C"),
            FoodItem("seed-014", "Black Beans",      "Generic", "seed", 132.0,  8.9, 23.7,  0.5, "A"),
            FoodItem("seed-015", "Almonds",          "Generic", "seed", 579.0, 21.2, 21.6, 49.9, "B"),
            FoodItem("seed-016", "Sweet Potato",     "Generic", "seed",  86.0,  1.6, 20.1,  0.1, "A"),
            FoodItem("seed-017", "Tuna (canned)",    "Generic", "seed", 116.0, 25.5,  0.0,  1.0, "A"),
        )
    }
}
