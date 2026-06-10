package com.snappet.mobile.feature.journal

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Root entry for the Journal mini-app: a list of entries (newest first) with create / edit /
 * delete, plus live search by title, body, or tag. Mirrors the iOS `JournalRootView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JournalRoot(onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val dao = container.database.journalDao()

    // Issue #86: navigation state as saveable primitives (a sealed screen carrying the full
    // JournalEntry is not Bundle-able). editorOpen with a null editingEntryId means a new entry.
    var editorOpen by rememberSaveable { mutableStateOf(false) }
    var editingEntryId by rememberSaveable { mutableStateOf<Long?>(null) }
    var searchText by rememberSaveable { mutableStateOf("") }
    val entries by dao.allFlow().collectAsState(initial = emptyList())
    val editingEntry = entries.firstOrNull { it.id == editingEntryId }

    fun closeEditor() {
        editorOpen = false
        editingEntryId = null
    }

    // System back mirrors the editor's top-bar arrow: close, discarding the unsaved draft.
    // Disabled at the list root so back falls through to the app-level NavHost (issue #86).
    BackHandler(enabled = editorOpen) { closeEditor() }

    // Only compose the editor once the id resolves to a row (or is null = new entry): composing
    // it with a transiently-null entry while the flow loads would re-key the drafts and wipe a
    // rotation-restored draft. A deleted row self-heals to the list.
    if (editorOpen && (editingEntryId == null || editingEntry != null)) {
        JournalEditorScreen(
            entry = editingEntry,
            onExit = { closeEditor() },
        )
    } else {
        ModuleScaffold(
            title = "Journal",
            onExit = onExit,
            actions = {
                IconButton(
                    onClick = {
                        editingEntryId = null
                        editorOpen = true
                    },
                    modifier = Modifier.testTag("journal.add"),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "New entry")
                }
            },
        ) { padding ->
            JournalListBody(
                entries = entries,
                searchText = searchText,
                onSearchChange = { searchText = it },
                onClearSearch = { searchText = "" },
                onAdd = {
                    editingEntryId = null
                    editorOpen = true
                },
                onOpen = {
                    editingEntryId = it.id
                    editorOpen = true
                },
                onDelete = { entry -> scope.launch { dao.delete(entry) } },
                padding = padding,
            )
        }
    }
}

private fun JournalEntry.matches(query: String): Boolean {
    if (query.isEmpty()) return true
    return title.lowercase().contains(query) ||
        body.lowercase().contains(query) ||
        tagList.any { it.contains(query) }
}

@Composable
private fun JournalListBody(
    entries: List<JournalEntry>,
    searchText: String,
    onSearchChange: (String) -> Unit,
    onClearSearch: () -> Unit,
    onAdd: () -> Unit,
    onOpen: (JournalEntry) -> Unit,
    onDelete: (JournalEntry) -> Unit,
    padding: PaddingValues,
) {
    val query = searchText.trim().lowercase()
    val filtered = entries.filter { it.matches(query) }

    Column(Modifier.fillMaxSize().padding(padding)) {
        OutlinedTextField(
            value = searchText,
            onValueChange = onSearchChange,
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("journal.search"),
            placeholder = { Text("Search title, body, or tag") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (searchText.isNotEmpty()) {
                    IconButton(onClick = onClearSearch, modifier = Modifier.testTag("journal.search.clear")) {
                        Icon(Icons.Filled.Clear, contentDescription = "Clear search")
                    }
                }
            },
        )

        when {
            entries.isEmpty() -> EmptyState(
                title = "No entries yet",
                message = "Tap + to write your first journal entry.",
                onAdd = onAdd,
            )

            filtered.isEmpty() -> EmptyState(
                title = "No results",
                message = "No entries match \"$searchText\".",
                onAdd = null,
            )

            else -> LazyColumn(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(filtered, key = { it.id }) { entry ->
                    JournalRow(entry = entry, onClick = { onOpen(entry) }, onDelete = { onDelete(entry) })
                }
            }
        }
    }
}

@Composable
private fun EmptyState(title: String, message: String, onAdd: (() -> Unit)?) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 32.dp),
            )
            if (onAdd != null) {
                TextButton(onClick = onAdd, modifier = Modifier.testTag("journal.add")) {
                    Icon(Icons.Filled.Add, contentDescription = null)
                    Text("  New Entry")
                }
            }
        }
    }
}

@Composable
private fun JournalRow(entry: JournalEntry, onClick: () -> Unit, onDelete: () -> Unit) {
    val dateFmt = remember { SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()) }
    Row(
        Modifier
            .fillMaxWidth()
            .testTag("journalRow")
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            // The list row renders the title as plain Text so the UI test can find it by text.
            Text(
                text = displayTitle(entry),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                dateFmt.format(Date(entry.createdAt)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (entry.tagList.isNotEmpty()) {
                Text(
                    entry.tagList.joinToString(" ") { "#$it" },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        IconButton(onClick = onDelete, modifier = Modifier.testTag("journal.delete")) {
            Icon(Icons.Filled.Close, contentDescription = "Delete entry")
        }
    }
}

/** The title if present, otherwise the first line of the body, otherwise "Untitled". */
private fun displayTitle(entry: JournalEntry): String {
    val trimmed = entry.title.trim()
    if (trimmed.isNotEmpty()) return trimmed
    val firstLine = entry.body.lineSequence().firstOrNull()?.trim().orEmpty()
    return firstLine.ifEmpty { "Untitled" }
}
