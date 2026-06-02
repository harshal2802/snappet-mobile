import Foundation
import SQLite3

/// Read-only access to the bundled `food.sqlite3` (OFF + USDA FDC).
/// Falls back to seed data when the asset is absent (CI / before the trimmed export is committed).
/// No network calls.
final class FoodCatalog {
    static let shared = FoodCatalog()

    private var db: OpaquePointer?

    private init() { openDatabase() }

    deinit { if let db { sqlite3_close(db) } }

    private func openDatabase() {
        guard let path = Bundle.main.path(forResource: "food", ofType: "sqlite3") else { return }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            db = nil; return
        }
    }

    func search(query: String, limit: Int = 30) -> [FoodItem] {
        if query.isEmpty { return Array(seedData.prefix(limit)) }
        if let db { return sqlSearch(q: "%\(query)%", limit: limit, db: db) }
        let q = query.lowercased()
        return seedData.filter {
            $0.name.lowercased().contains(q) || ($0.brand?.lowercased().contains(q) ?? false)
        }
    }

    func lookup(barcode: String) -> FoodItem? {
        if let db { return sqlLookup(barcode: barcode, db: db) }
        return seedData.first { $0.id == barcode }
    }

    // MARK: - SQLite

    private static let cols = "id,name,brand,kcal_per_100g,protein_per_100g,carbs_per_100g,fat_per_100g,serving_size,serving_label,nutriscore,data_source"

    private func sqlSearch(q: String, limit: Int, db: OpaquePointer) -> [FoodItem] {
        let sql = "SELECT \(Self.cols) FROM foods WHERE name LIKE ? LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let dtor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, q, -1, dtor)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return rows(stmt)
    }

    private func sqlLookup(barcode: String, db: OpaquePointer) -> FoodItem? {
        let sql = "SELECT \(Self.cols) FROM foods WHERE id=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let dtor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, barcode, -1, dtor)
        return rows(stmt).first
    }

    private func rows(_ stmt: OpaquePointer?) -> [FoodItem] {
        var items: [FoodItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func s(_ c: Int32) -> String { String(cString: sqlite3_column_text(stmt, c)) }
            func d(_ c: Int32) -> Double { sqlite3_column_double(stmt, c) }
            let brand: String? = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? s(2) : nil
            let ns: String?    = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? s(9) : nil
            items.append(FoodItem(
                id: s(0), name: s(1), brand: brand,
                kcalPer100g: d(3), proteinPer100g: d(4), carbsPer100g: d(5), fatPer100g: d(6),
                servingSize: d(7), servingLabel: s(8), nutriScore: ns, dataSource: s(10)
            ))
        }
        return items
    }

    // MARK: - Seed data (replaces SQLite when food.sqlite3 is not yet bundled)

    let seedData: [FoodItem] = [
        FoodItem(id: "usda-1",  name: "Chicken Breast, cooked",  brand: nil,             kcalPer100g: 165, proteinPer100g: 31,  carbsPer100g: 0,   fatPer100g: 3.6, servingSize: 85,  servingLabel: "3 oz (85 g)",        nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-2",  name: "Brown Rice, cooked",       brand: nil,             kcalPer100g: 111, proteinPer100g: 2.6, carbsPer100g: 23,  fatPer100g: 0.9, servingSize: 186, servingLabel: "1 cup (186 g)",      nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-3",  name: "Broccoli, raw",            brand: nil,             kcalPer100g: 34,  proteinPer100g: 2.8, carbsPer100g: 7,   fatPer100g: 0.4, servingSize: 91,  servingLabel: "1 cup (91 g)",       nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-4",  name: "Whole Milk",               brand: nil,             kcalPer100g: 61,  proteinPer100g: 3.2, carbsPer100g: 4.8, fatPer100g: 3.3, servingSize: 244, servingLabel: "1 cup (244 ml)",     nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-5",  name: "Banana",                   brand: nil,             kcalPer100g: 89,  proteinPer100g: 1.1, carbsPer100g: 23,  fatPer100g: 0.3, servingSize: 118, servingLabel: "1 medium (118 g)",   nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-6",  name: "Oatmeal, cooked",          brand: nil,             kcalPer100g: 68,  proteinPer100g: 2.4, carbsPer100g: 12,  fatPer100g: 1.4, servingSize: 234, servingLabel: "1 cup (234 g)",      nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-7",  name: "Egg, large",               brand: nil,             kcalPer100g: 143, proteinPer100g: 13,  carbsPer100g: 1.1, fatPer100g: 9.5, servingSize: 50,  servingLabel: "1 large (50 g)",     nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-8",  name: "Greek Yogurt, plain",      brand: nil,             kcalPer100g: 59,  proteinPer100g: 10,  carbsPer100g: 3.6, fatPer100g: 0.4, servingSize: 200, servingLabel: "3/4 cup (200 g)",    nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-9",  name: "Salmon, cooked",           brand: nil,             kcalPer100g: 208, proteinPer100g: 20,  carbsPer100g: 0,   fatPer100g: 13,  servingSize: 85,  servingLabel: "3 oz (85 g)",        nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-10", name: "Almonds",                  brand: nil,             kcalPer100g: 579, proteinPer100g: 21,  carbsPer100g: 22,  fatPer100g: 50,  servingSize: 28,  servingLabel: "1 oz (28 g)",        nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-11", name: "Apple",                    brand: nil,             kcalPer100g: 52,  proteinPer100g: 0.3, carbsPer100g: 14,  fatPer100g: 0.2, servingSize: 182, servingLabel: "1 medium (182 g)",   nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "usda-12", name: "White Rice, cooked",       brand: nil,             kcalPer100g: 130, proteinPer100g: 2.7, carbsPer100g: 28,  fatPer100g: 0.3, servingSize: 186, servingLabel: "1 cup (186 g)",      nutriScore: nil, dataSource: "USDA"),
        FoodItem(id: "off-1",   name: "Cheerios",                 brand: "General Mills", kcalPer100g: 376, proteinPer100g: 12,  carbsPer100g: 73,  fatPer100g: 6.7, servingSize: 28,  servingLabel: "1 cup (28 g)",       nutriScore: "B", dataSource: "OFF"),
        FoodItem(id: "off-2",   name: "Greek Yogurt",             brand: "Chobani",       kcalPer100g: 73,  proteinPer100g: 10,  carbsPer100g: 5,   fatPer100g: 0.7, servingSize: 170, servingLabel: "1 container (170 g)",nutriScore: "A", dataSource: "OFF"),
        FoodItem(id: "off-3",   name: "Whole Grain Bread",        brand: "Dave's Killer", kcalPer100g: 270, proteinPer100g: 11,  carbsPer100g: 46,  fatPer100g: 5,   servingSize: 45,  servingLabel: "1 slice (45 g)",     nutriScore: "B", dataSource: "OFF"),
        FoodItem(id: "off-4",   name: "Peanut Butter",            brand: "Jif",           kcalPer100g: 598, proteinPer100g: 22,  carbsPer100g: 22,  fatPer100g: 51,  servingSize: 32,  servingLabel: "2 tbsp (32 g)",      nutriScore: "D", dataSource: "OFF"),
        FoodItem(id: "off-5",   name: "Orange Juice",             brand: "Tropicana",     kcalPer100g: 44,  proteinPer100g: 0.7, carbsPer100g: 10,  fatPer100g: 0.2, servingSize: 240, servingLabel: "8 fl oz (240 ml)",   nutriScore: "C", dataSource: "OFF"),
    ]
}
