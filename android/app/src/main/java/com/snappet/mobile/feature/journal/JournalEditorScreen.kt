package com.snappet.mobile.feature.journal

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch

/**
 * View / edit a single journal entry. Used for brand-new entries ([entry] == null, logs usage on
 * save) and for editing existing ones. Mirrors the iOS `JournalEditorView`. [onExit] returns to
 * the list.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun JournalEditorScreen(entry: JournalEntry?, onExit: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val dao = container.database.journalDao()
    val isNew = entry == null

    // Issue #86: drafts survive rotation/process death. Keyed by the entry id so switching to a
    // different entry never restores a stale draft; null is a valid stable key for a new entry.
    var title by rememberSaveable(entry?.id) { mutableStateOf(entry?.title ?: "") }
    var body by rememberSaveable(entry?.id) { mutableStateOf(entry?.body ?: "") }
    var tags by rememberSaveable(entry?.id) { mutableStateOf(entry?.tagList ?: emptyList()) }
    var tagInput by rememberSaveable(entry?.id) { mutableStateOf("") }

    // Fold the current (possibly comma-separated) tag input into the chip list, normalized.
    fun commitTags() {
        val pieces = tagInput.split(",").filter { it.isNotBlank() }
        if (pieces.isEmpty()) {
            tagInput = ""
            return
        }
        tags = JournalEntry.normalizeTags(tags + pieces)
        tagInput = ""
    }

    fun save() {
        commitTags()
        val trimmedTitle = title.trim()
        val trimmedBody = body.trim()

        // Drop an entirely empty new entry rather than persisting a blank row.
        if (isNew && trimmedTitle.isEmpty() && trimmedBody.isEmpty() && tags.isEmpty()) {
            onExit()
            return
        }

        val now = System.currentTimeMillis()
        val joinedTags = JournalEntry.joinTags(tags)
        scope.launch {
            if (isNew) {
                dao.insert(
                    JournalEntry(
                        title = trimmedTitle,
                        body = body,
                        tags = joinedTags,
                        createdAt = now,
                        updatedAt = now,
                    )
                )
                container.core.log(
                    module = "journal",
                    action = "entry",
                    summary = "Journaled: ${firstWords(trimmedTitle, trimmedBody)}",
                )
            } else {
                dao.update(
                    entry!!.copy(title = trimmedTitle, body = body, tags = joinedTags, updatedAt = now)
                )
            }
        }
        onExit()
    }

    ModuleScaffold(
        title = if (isNew) "New Entry" else "Entry",
        onExit = onExit,
        actions = {
            IconButton(onClick = { save() }, modifier = Modifier.testTag("journal.save")) {
                Icon(Icons.Filled.Check, contentDescription = "Save entry")
            }
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                singleLine = true,
                label = { Text("Title (optional)") },
                modifier = Modifier.fillMaxWidth().testTag("journal.titleField"),
            )
            OutlinedTextField(
                value = body,
                onValueChange = { body = it },
                label = { Text("Entry") },
                modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp).testTag("journal.bodyField"),
            )

            if (tags.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    tags.forEach { tag ->
                        AssistChip(
                            onClick = { tags = tags.filterNot { it == tag } },
                            label = { Text("#$tag") },
                            trailingIcon = { Icon(Icons.Filled.Close, contentDescription = "Remove tag $tag") },
                        )
                    }
                }
            }
            OutlinedTextField(
                value = tagInput,
                onValueChange = { newValue ->
                    tagInput = newValue
                    // Commit on comma so a "tag," entry produces a chip without pressing return.
                    if (newValue.contains(",")) commitTags()
                },
                singleLine = true,
                label = { Text("Add a tag") },
                modifier = Modifier.fillMaxWidth().testTag("journal.tagField"),
            )
        }
    }
}

/** The title if present, otherwise the first ~5 words of the body. */
private fun firstWords(title: String, body: String): String {
    if (title.isNotEmpty()) return title
    return body.split(Regex("\\s+")).filter { it.isNotEmpty() }.take(5).joinToString(" ")
}
