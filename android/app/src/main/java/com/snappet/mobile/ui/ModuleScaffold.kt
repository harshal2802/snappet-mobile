package com.snappet.mobile.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

/**
 * Standard chrome for a module screen: a top bar with the title and a back arrow tagged
 * `BackButton` (the suite smoke test taps it to return to the App Library). Use this for a
 * module's root screen (back arrow -> [onExit]) and for deeper screens (back arrow -> pop).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModuleScaffold(
    title: String,
    onExit: () -> Unit,
    actions: @Composable (androidx.compose.foundation.layout.RowScope.() -> Unit) = {},
    floatingActionButton: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        floatingActionButton = floatingActionButton,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(
                        onClick = onExit,
                        modifier = Modifier
                            .testTag("BackButton")
                            .semantics { contentDescription = "Back" },
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = actions,
            )
        },
    ) { padding -> content(padding) }
}
