package com.snappet.mobile.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.testTag
import com.snappet.mobile.ui.theme.LocalReduceMotion
import com.snappet.mobile.ui.theme.SnappetMotion
import com.snappet.mobile.ui.theme.gated
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.snappet.mobile.core.AppModule
import com.snappet.mobile.core.ModuleCategory
import com.snappet.mobile.core.ModuleRegistry
import com.snappet.mobile.ui.LocalAppContainer
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope

/**
 * The App Library: a category-grouped grid of module cards. Tapping a card navigates into the
 * module (logging an "open" usage event centrally), and the module's back arrow returns here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppLibraryScreen() {
    val nav = rememberNavController()
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()

    NavHost(navController = nav, startDestination = "library") {
        composable("library") {
            Scaffold(topBar = { TopAppBar(title = { Text("Apps") }) }) { padding ->
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 12.dp)
                        .testTag("appLibraryGrid"),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    for (category in ModuleCategory.entries) {
                        val modules = ModuleRegistry.all.filter { it.category == category }
                        if (modules.isEmpty()) continue
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            Text(
                                category.title,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(top = 12.dp),
                            )
                        }
                        items(modules, key = { it.id }) { module ->
                            ModuleCard(module) {
                                scope.launch {
                                    container.core.log(module.id, "open", "Opened ${module.title}")
                                }
                                nav.navigate("module/${module.id}")
                            }
                        }
                    }
                }
            }
        }
        composable("module/{id}") { backStack ->
            val id = backStack.arguments?.getString("id")
            val module = id?.let { ModuleRegistry.byId(it) }
            if (module != null) {
                module.content { nav.popBackStack() }
            }
        }
    }
}

@Composable
private fun ModuleCard(module: AppModule, onClick: () -> Unit) {
    val reduceMotion = LocalReduceMotion.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = gated(reduceMotion, SnappetMotion.expressive()),
        label = "moduleCardScale",
    )
    Card(
        onClick = onClick,
        interactionSource = interaction,
        modifier = Modifier
            .fillMaxWidth()
            .height(120.dp)
            .scale(scale)
            .testTag("moduleCard.${module.id}")
            .semantics { contentDescription = "moduleCard.${module.id}" },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.fillMaxSize().padding(14.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Box(
                Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(module.tint.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(module.icon, contentDescription = null, tint = module.tint)
            }
            Column {
                Text(module.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(
                    module.subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
