@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import org.simpleagentmanager.core.Project
import org.simpleagentmanager.core.ProjectDraft
import org.simpleagentmanager.core.ProjectManagementState

@Composable
fun ProjectSettingsScreen(projectId: String?, onBack: () -> Unit, done: (Project?) -> Unit) {
    val model: ProjectManagementModel = viewModel(key = "project-settings:${projectId ?: "new"}")
    val state by model.state.collectAsStateWithLifecycle()
    androidx.activity.compose.BackHandler(enabled = state.saving) {}
    LaunchedEffect(projectId) { model.load(projectId) }
    ProjectSettingsContent(projectId, state, onBack, { model.load(projectId) }, model::repositories,
        { model.save(it, done) }, { model.delete(it, done) })
}

/** The real form can also be rendered by host previews without a live session. */
@Composable
fun ProjectSettingsContent(
    projectId: String?, state: ProjectManagementState, onBack: () -> Unit, retry: () -> Unit,
    repositories: (String, String, String) -> Unit, save: (ProjectDraft) -> Unit, delete: (String) -> Unit,
) {
    val project = state.project?.takeIf { it.id == projectId }
    var name by rememberSaveable(projectId) { mutableStateOf(project?.name ?: "") }
    var description by rememberSaveable(projectId) { mutableStateOf(project?.description ?: "") }
    var branch by rememberSaveable(projectId) { mutableStateOf(project?.defaultBranch ?: "main") }
    var provider by rememberSaveable(projectId) { mutableStateOf("github") }
    var installation by rememberSaveable(projectId) { mutableStateOf("") }
    var repoId by rememberSaveable(projectId) { mutableStateOf<String?>(null) }
    var repoName by rememberSaveable(projectId) { mutableStateOf("") }
    var search by rememberSaveable(projectId) { mutableStateOf("") }
    var loadedFor by rememberSaveable(projectId) { mutableStateOf("") }
    var deleting by rememberSaveable(projectId) { mutableStateOf(false) }
    var confirmation by rememberSaveable(projectId) { mutableStateOf("") }
    LaunchedEffect(project) {
        project?.let { name = it.name; description = it.description ?: ""; branch = it.defaultBranch; provider = it.repoProvider }
    }
    val busy = state.loading || state.saving
    val valid = name.isNotBlank() && branch.isNotBlank() && (project != null || provider == "artifacts" || repoId != null)
    Scaffold(topBar = {
        TopAppBar(title = { Text(if (projectId == null) stringResource(R.string.project_new_project) else stringResource(R.string.project_project_settings)) },
            navigationIcon = { IconButton(onClick = onBack, enabled = !state.saving) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
            } }, actions = {
                TextButton(enabled = valid && !busy && (projectId == null || project != null), onClick = {
                    save(ProjectDraft(name, description, provider, installation, repoId?.toULong(), repoName, branch))
                }) { LoadingLabel(if (projectId == null) stringResource(R.string.project_create) else stringResource(R.string.save), state.saving) }
            })
    }) { padding ->
        InitialLoading(state.loading && !state.initialized, Modifier.padding(padding)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            state.error?.let {
                Text(it.message(), color = MaterialTheme.colorScheme.error)
                if (!state.initialized) OutlinedButton(onClick = retry, enabled = !busy) { Text(stringResource(R.string.project_retry)) }
            }
            if (projectId == null || project != null) {
                SettingsCard(stringResource(R.string.project_general)) {
                    OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.project_project_name)) }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(description, { description = it }, label = { Text(stringResource(R.string.project_description_optional)) }, minLines = 2, enabled = !busy, modifier = Modifier.fillMaxWidth())
                }
                SettingsCard(stringResource(R.string.project_repository)) {
                    if (project != null) {
                        Text(project.repository, style = MaterialTheme.typography.bodyLarge)
                        Text(stringResource(R.string.project_the_repository_provider_is_fixed_after_creation), style = MaterialTheme.typography.bodySmall)
                    } else {
                        ChoiceMenu(stringResource(R.string.project_provider), provider, buildList {
                            add("github" to "GitHub"); add("gitlab" to "GitLab")
                            if (state.artifactsEnabled) add("artifacts" to "SAM-hosted")
                        }, !busy) { provider = it; repoId = null; repoName = ""; branch = "main"; loadedFor = "" }
                        if (provider == "github") {
                            ChoiceMenu(stringResource(R.string.project_github_account), installation, state.installations.map { it.id to it.accountName }, !busy) {
                                installation = it; repoId = null; repoName = ""; loadedFor = ""
                            }
                            if (state.installations.isEmpty()) Text(stringResource(R.string.project_connect_a_github_account_in_sam_on_the_web_then_retry), style = MaterialTheme.typography.bodySmall)
                        }
                        if (provider == "artifacts") {
                            Text(stringResource(R.string.project_sam_creates_a_private_git_repository_for_this_project))
                        } else {
                            OutlinedTextField(search, { search = it }, label = { Text(stringResource(R.string.project_search_repositories)) }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
                            OutlinedButton(enabled = !busy && (provider == "gitlab" || installation.isNotEmpty()), onClick = {
                                repoId = null; loadedFor = "$provider:$installation"; repositories(provider, installation, search)
                            }) { LoadingLabel(stringResource(R.string.project_load_repositories), state.loading) }
                            if (loadedFor == "$provider:$installation") {
                                state.repositories.filter { provider == "gitlab" || it.fullName.contains(search, ignoreCase = true) }.forEach { repo ->
                                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        RadioButton(selected = repoId == repo.id.toString(), enabled = !busy, onClick = {
                                            repoId = repo.id.toString(); repoName = repo.fullName; branch = repo.defaultBranch
                                            if (name.isBlank()) name = repo.fullName.substringAfterLast('/')
                                        })
                                        TextButton(enabled = !busy, onClick = {
                                            repoId = repo.id.toString(); repoName = repo.fullName; branch = repo.defaultBranch
                                            if (name.isBlank()) name = repo.fullName.substringAfterLast('/')
                                        }) { Text(repo.fullName) }
                                    }
                                }
                                if (!busy && state.repositories.isEmpty() && state.error == null) Text(stringResource(R.string.project_no_repositories_found))
                            }
                        }
                    }
                    if (provider != "artifacts") OutlinedTextField(branch, { branch = it }, label = { Text(stringResource(R.string.project_default_branch)) }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
                }
                if (project != null) SettingsCard(stringResource(R.string.project_delete_project)) {
                    Text(stringResource(R.string.project_permanently_deletes_this_project_and_all_associated_data_this_cannot_b))
                    if (deleting) {
                        Text(stringResource(R.string.project_type_name_to_confirm, project.name))
                        OutlinedTextField(confirmation, { confirmation = it }, label = { Text(stringResource(R.string.project_confirm_project_name)) }, enabled = !busy, modifier = Modifier.fillMaxWidth())
                        OutlinedButton(onClick = { delete(confirmation) }, enabled = !busy && confirmation == project.name,
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(stringResource(R.string.project_permanently_delete)) }
                        TextButton(onClick = { deleting = false; confirmation = "" }, enabled = !busy) { Text(stringResource(R.string.cancel)) }
                    } else OutlinedButton(onClick = { deleting = true }, enabled = !busy) { Text(stringResource(R.string.project_delete_project), color = MaterialTheme.colorScheme.error) }
                }
            }
        }
    }
}
}

@Composable
private fun SettingsCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun ChoiceMenu(label: String, value: String, options: List<Pair<String, String>>, enabled: Boolean, select: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled && options.isNotEmpty(), modifier = Modifier.fillMaxWidth()) {
                Text(options.firstOrNull { it.first == value }?.second ?: stringResource(R.string.project_select))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; select(id) }) }
            }
        }
    }
}
