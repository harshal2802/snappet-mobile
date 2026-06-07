package com.snappet.mobile.feature.expense

/**
 * The kind of receipt being scanned. Drives a [ReceiptProfile] that tunes how [ReceiptParser]
 * extracts line items vs. metadata (and how [ReceiptClassifier] guesses the type for [AUTO]).
 * Affects parsing only — the saved receipt is a plain itemized expense — so no schema change.
 * Mirrors the iOS `ReceiptType`.
 */
enum class ReceiptType(val displayName: String) {
    AUTO("Auto"),
    GROCERY("Grocery"),
    WAREHOUSE("Warehouse"),
    RESTAURANT("Restaurant"),
    GAS("Gas"),
    PHARMACY("Pharmacy"),
    RETAIL("Retail"),
    GENERIC("Other");

    /** Resolve a concrete type for [text]: [AUTO] classifies, anything else is itself. */
    fun resolved(text: String): ReceiptType = if (this == AUTO) ReceiptClassifier.classify(text) else this

    /** The parsing profile for this type ([AUTO] falls back to generic — resolve first). */
    val profile: ReceiptProfile
        get() = ReceiptProfile.forType(if (this == AUTO) GENERIC else this)
}

/**
 * Per-type tuning for [ReceiptParser]: extra metadata keywords to skip, tip-line prefixes, and
 * whether to collapse to a single fuel line. Pure value type. Mirrors the iOS `ReceiptProfile`.
 */
data class ReceiptProfile(
    val extraSkipKeywords: List<String>,
    val tipKeywordPrefixes: List<String>,
    val fuelOnly: Boolean,
) {
    companion object {
        val GENERIC = ReceiptProfile(emptyList(), emptyList(), false)

        fun forType(type: ReceiptType): ReceiptProfile = when (type) {
            ReceiptType.RESTAURANT -> ReceiptProfile(
                listOf("SERVER", "TABLE", "GUEST", "CHECK #", "ORDER #", "DINE", "TO GO", "SEAT"),
                listOf("TIP", "GRATUITY"), false,
            )
            ReceiptType.GAS -> ReceiptProfile(
                listOf("PUMP", "GALLON", "PRICE/GAL", "PRICE PER", "UNLEADED", "REGULAR",
                    "PREMIUM", "DIESEL", "GRADE", "AUTH"),
                emptyList(), true,
            )
            ReceiptType.PHARMACY -> ReceiptProfile(
                listOf("PRESCRIPTION", "NDC", "PHARMACY", "REFILL", "COPAY"), emptyList(), false,
            )
            ReceiptType.RETAIL -> ReceiptProfile(
                listOf("CASHIER", "REGISTER", "STORE #", "SKU"), emptyList(), false,
            )
            else -> GENERIC
        }
    }
}

/**
 * Pure, device-free guess of a receipt's [ReceiptType] from its text — backs the [ReceiptType.AUTO]
 * option. Scores each type by signature-keyword hits and picks the best; no hits → generic.
 * Mirrors the iOS `ReceiptClassifier`.
 */
object ReceiptClassifier {
    private val signatures: List<Pair<ReceiptType, List<String>>> = listOf(
        ReceiptType.RESTAURANT to listOf("SERVER", "GRATUITY", "TABLE", "GUEST", "DINE", "CHECK #"),
        ReceiptType.GAS to listOf("GALLON", "UNLEADED", "PUMP", "FUEL", "DIESEL", "PRICE/GAL"),
        ReceiptType.WAREHOUSE to listOf("WHOLESALE", "MEMBER", "INSTANT SAVINGS", "COSTCO", "SAM'S CLUB", "BJ'S"),
        ReceiptType.PHARMACY to listOf("PHARMACY", "PRESCRIPTION", "RX ", "NDC", "REFILL", "COPAY"),
        ReceiptType.GROCERY to listOf("GROCERY", "PRODUCE", "SUPERMARKET", "SAFEWAY", "KROGER", "TRADER JOE"),
    )

    fun classify(text: String): ReceiptType {
        val upper = text.uppercase()
        var best = ReceiptType.GENERIC
        var bestScore = 0
        for ((type, keywords) in signatures) {
            val score = keywords.count { upper.contains(it) }
            if (score > bestScore) {
                bestScore = score
                best = type
            }
        }
        return if (bestScore > 0) best else ReceiptType.GENERIC
    }
}
