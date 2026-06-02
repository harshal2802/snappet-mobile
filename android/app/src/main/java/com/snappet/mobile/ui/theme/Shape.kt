package com.snappet.mobile.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/**
 * The Pulse corner-radius scale wired into Material 3 [Shapes]: small 10dp, medium 16dp, large 24dp.
 * `MaterialTheme.shapes.medium` is the default card/tile radius across the suite.
 */
val SnappetShapes = Shapes(
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
)
