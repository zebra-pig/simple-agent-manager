@file:OptIn(ExperimentalMaterial3Api::class)

package org.simpleagentmanager.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.simpleagentmanager.core.AgentProfile
import org.simpleagentmanager.core.ProjectState
import org.simpleagentmanager.core.permissionModes
import org.simpleagentmanager.core.profileDraft
import org.simpleagentmanager.core.supportedEfforts
import org.simpleagentmanager.core.taskModes

/**
 * Which agent profile the next task runs with: a chip above the composer that
 * opens the project's profiles, with "Edit" and "New profile" for the editor.
 */
@Composable
internal fun ProfileRow(state: ProjectState, onSelect: (String) -> Unit, onEdit: (profileId: String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val selected = state.profiles.firstOrNull { it.id == state.selectedProfileId }
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        Box {
            AssistChip(
                onClick = { open = true },
                label = {
                    Column {
                        Text(selected?.name ?: stringResource(R.string.project_defaults), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        selected?.let {
                            Text(profileSummary(it), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                        }
                    }
                },
                trailingIcon = { Icon(Icons.Default.ArrowDropDown, contentDescription = stringResource(R.string.agent_profile)) },
            )
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                state.profiles.forEach { profile ->
                    DropdownMenuItem(
                        text = { Text(profile.name) },
                        leadingIcon = {
                            if (profile.id == state.selectedProfileId) Icon(Icons.Default.Check, contentDescription = null) else Box(Modifier.size(24.dp))
                        },
                        onClick = {
                            open = false
                            onSelect(profile.id)
                        },
                    )
                }
                if (state.profiles.isNotEmpty()) HorizontalDivider()
                if (selected != null && selected.editable) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.edit_profile_named, selected.name)) },
                        leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                        onClick = {
                            open = false
                            onEdit(selected.id)
                        },
                    )
                }
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.new_profile)) },
                    leadingIcon = { Icon(Icons.Default.Add, contentDescription = null) },
                    onClick = {
                        open = false
                        onEdit(null)
                    },
                )
            }
        }
    }
}

/**
 * Creates or edits one of the project's agent profiles. Fields left on
 * "Default" (or empty) use the project's settings.
 */
@Composable
internal fun ProfileEditorScreen(route: Route.ProfileEditor, model: ProjectModel, onBack: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val profile = state.profiles.firstOrNull { it.id == route.profileId }
    var draft by remember(route) { mutableStateOf(profileDraft(profile)) }
    var confirmDelete by rememberSaveable(route) { mutableStateOf(false) }
    LaunchedEffect(route) { model.loadAgents() }

    val agents = state.agents.map { it.id to it.name }.let { list ->
        if (draft.agentType.isNotEmpty() && list.none { it.first == draft.agentType }) listOf(draft.agentType to draft.agentType) + list else list
    }
    val efforts = supportedEfforts(draft.agentType)
    val default = stringResource(R.string.profile_default)

    Scaffold(
        topBar = {
            BackBar(stringResource(if (route.profileId == null) R.string.new_profile else R.string.edit_profile), onBack) {
                if (state.savingProfile) {
                    CircularProgressIndicator(Modifier.size(24.dp).padding(end = 8.dp))
                } else {
                    TextButton(onClick = { model.saveProfile(route.profileId, draft, done = onBack) }, enabled = draft.name.isNotBlank()) {
                        Text(stringResource(R.string.save))
                    }
                }
            }
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.profileError?.let { Text(it.message(), color = MaterialTheme.colorScheme.error) }
            OutlinedTextField(draft.name, { draft = draft.copy(name = it) }, label = { Text(stringResource(R.string.profile_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(draft.description, { draft = draft.copy(description = it) }, label = { Text(stringResource(R.string.profile_description)) }, maxLines = 3, modifier = Modifier.fillMaxWidth())
            Choice(stringResource(R.string.profile_agent), draft.agentType, agents) { agent ->
                // Another agent may not have this effort level.
                val effort = draft.effort.takeIf { it.isEmpty() || it in supportedEfforts(agent) } ?: ""
                draft = draft.copy(agentType = agent, effort = effort)
            }
            OutlinedTextField(
                draft.model,
                { draft = draft.copy(model = it) },
                label = { Text(stringResource(R.string.profile_model)) },
                placeholder = { Text(stringResource(R.string.profile_model_default)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            if (efforts.isNotEmpty()) {
                Choice(stringResource(R.string.profile_effort), draft.effort, listOf("" to default) + efforts.map { it to effortLabel(it) }) {
                    draft = draft.copy(effort = it)
                }
            }
            Choice(stringResource(R.string.profile_permissions), draft.permissionMode, listOf("" to default) + permissionModes().map { it to permissionModeLabel(it) }) {
                draft = draft.copy(permissionMode = it)
            }
            Choice(stringResource(R.string.profile_work_type), draft.taskMode, listOf("" to default) + taskModes().map { it to taskModeLabel(it) }) {
                draft = draft.copy(taskMode = it)
            }
            OutlinedTextField(
                draft.systemPromptAppend,
                { draft = draft.copy(systemPromptAppend = it) },
                label = { Text(stringResource(R.string.profile_instructions)) },
                supportingText = { Text(stringResource(R.string.profile_instructions_help)) },
                minLines = 3,
                maxLines = 10,
                modifier = Modifier.fillMaxWidth(),
            )
            if (profile != null) {
                TextButton(onClick = { confirmDelete = true }, enabled = !state.savingProfile) {
                    Text(stringResource(R.string.delete_profile), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }

    if (confirmDelete && profile != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.delete_profile_named, profile.name)) },
            text = { Text(stringResource(R.string.delete_profile_detail)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    model.deleteProfile(profile.id, done = onBack)
                }) { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/** A labelled value that opens a menu of `options` (value to label). */
@Composable
private fun Choice(label: String, value: String, options: List<Pair<String, String>>, onSelect: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        ListItem(
            headlineContent = { Text(label) },
            supportingContent = { Text(options.firstOrNull { it.first == value }?.second ?: value) },
            trailingContent = { Icon(Icons.Default.ArrowDropDown, contentDescription = null) },
            modifier = Modifier.clickable { open = true },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (id, name) ->
                DropdownMenuItem(
                    text = { Text(name) },
                    onClick = {
                        open = false
                        onSelect(id)
                    },
                )
            }
        }
    }
}

/** "claude-opus-5-5 · Max": what the profile runs, under its name. */
@Composable
private fun profileSummary(profile: AgentProfile): String =
    listOfNotNull(profile.model ?: profile.agentType, profile.effort?.takeIf { it != "auto" }?.let { effortLabel(it) }).joinToString(" · ")

/** `AGENT_EFFORT_LEVELS` for people. */
@Composable
private fun effortLabel(effort: String): String = when (effort) {
    "low" -> stringResource(R.string.effort_low)
    "medium" -> stringResource(R.string.effort_medium)
    "high" -> stringResource(R.string.effort_high)
    "xhigh" -> stringResource(R.string.effort_xhigh)
    "max" -> stringResource(R.string.effort_max)
    else -> humanize(effort)
}

/** `AGENT_PERMISSION_MODE_LABELS` in packages/shared/src/constants/agent-settings.ts. */
@Composable
private fun permissionModeLabel(mode: String): String = when (mode) {
    "default" -> stringResource(R.string.permission_default)
    "acceptEdits" -> stringResource(R.string.permission_accept_edits)
    "plan" -> stringResource(R.string.permission_plan)
    "dontAsk" -> stringResource(R.string.permission_dont_ask)
    "bypassPermissions" -> stringResource(R.string.permission_bypass)
    else -> humanize(mode)
}

/** `TASK_MODES`: a task ends in a pull request, a conversation doesn't. */
@Composable
private fun taskModeLabel(mode: String): String = when (mode) {
    "task" -> stringResource(R.string.work_type_task)
    "conversation" -> stringResource(R.string.work_type_conversation)
    else -> humanize(mode)
}
