@file:OptIn(ExperimentalMaterial3Api::class)

package org.simpleagentmanager.app

import android.net.Uri
import android.os.Build
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import org.simpleagentmanager.core.AppState
import org.simpleagentmanager.core.Attachment
import org.simpleagentmanager.core.AttachmentStatus
import org.simpleagentmanager.core.AuthStatus
import org.simpleagentmanager.core.ChatMessage
import org.simpleagentmanager.core.ChatSession
import org.simpleagentmanager.core.MessageRole
import org.simpleagentmanager.core.Project
import org.simpleagentmanager.core.SessionStatus
import org.simpleagentmanager.core.TaskSummary
import org.simpleagentmanager.core.UserError
import org.simpleagentmanager.core.deploymentName
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource

@Composable
fun SamTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

@Composable
fun Root(
    session: SessionModel,
    projects: ProjectListModel,
    project: ProjectModel,
    chat: ChatModel,
    openUrl: (String) -> Unit,
) {
    val app by session.state.collectAsStateWithLifecycle()
    LaunchedEffect(app.status) { if (app.status == AuthStatus.SIGNED_IN) projects.load() }
    if (app.status != AuthStatus.SIGNED_IN) {
        return SignInScreen(app, onSignIn = { session.signIn(it, openUrl) }, onOpen = openUrl, onCancel = session::cancelSignIn)
    }

    BackHandler(enabled = session.stack.size > 1, onBack = session::pop)
    val rootRoute = session.stack.last()
    Scaffold(bottomBar = {
        if (rootRoute == Route.Projects || rootRoute == Route.Notifications) {
            MainTabs(rootRoute == Route.Notifications,
                onProjects = { session.stack.clear(); session.stack.add(Route.Projects) },
                onNotifications = { session.stack.clear(); session.stack.add(Route.Notifications) },
            )
        }
    }) { tabPadding ->
        Box(Modifier.padding(tabPadding)) {
            when (val route = rootRoute) {
                Route.Notifications -> NotificationsScreen(session.app, openUrl) { p, s -> session.push(Route.Chat(p, s)) }
                Route.Projects -> ProjectsScreen(projects, onOpen = { session.push(Route.Project(it.id, it.name)) }, onAccount = { session.push(Route.Account) })
                Route.Account -> AccountScreen(app, onBack = session::pop, onSignOut = { session.signOut() })
                is Route.Project -> ProjectScreen(
                    route, project, onBack = session::pop,
                    onOpen = { session.push(Route.Chat(route.id, it)) },
                    onEditProfile = { session.push(Route.ProfileEditor(route.id, it)) },
                )
                is Route.Chat -> ChatScreen(route, chat, onBack = session::pop, openUrl = openUrl)
                is Route.ProfileEditor -> ProfileEditorScreen(route, project, onBack = session::pop)
            }
        }
    }
}

@Composable
internal fun MainTabs(notifications: Boolean, onProjects: () -> Unit, onNotifications: () -> Unit) {
    androidx.compose.material3.NavigationBar {
        NavigationBarItem(selected = !notifications, onClick = onProjects,
            icon = { Icon(Icons.AutoMirrored.Filled.List, null) }, label = { Text(stringResource(R.string.projects)) })
        NavigationBarItem(selected = notifications, onClick = onNotifications,
            icon = { Icon(Icons.Default.Notifications, null) }, label = { Text(stringResource(R.string.notifications)) })
    }
}

@Composable
private fun SignInScreen(app: AppState, onSignIn: (String) -> Unit, onOpen: (String) -> Unit, onCancel: () -> Unit) {
    var server by rememberSaveable { mutableStateOf("") }
    // Self-hosters type their own deployment; everyone else just taps Sign in.
    var otherServer by rememberSaveable { mutableStateOf(false) }
    val deployment = deploymentName(app.serverUrl)
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.padding(24.dp).navigationBarsPadding().imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.weight(1f))
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
            Text(stringResource(R.string.tagline), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            val pending = app.signIn
            if (pending != null) {
                Text(stringResource(R.string.approve_code), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(pending.userCode, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                CircularProgressIndicator()
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { onOpen(pending.verificationUrl) }) { Text(stringResource(R.string.open_again)) }
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
                }
            } else {
                if (otherServer) {
                    OutlinedTextField(
                        value = server,
                        onValueChange = { server = it },
                        label = { Text(stringResource(R.string.server)) },
                        placeholder = { Text("example.com") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                app.error?.let { Text(it.message(), color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
                Button(
                    onClick = { onSignIn(if (otherServer) server else app.serverUrl) },
                    enabled = app.status != AuthStatus.SIGNING_IN && (!otherServer || server.isNotBlank()),
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) { Text(stringResource(R.string.sign_in)) }
                if (otherServer) {
                    TextButton(onClick = { otherServer = false }) { Text(stringResource(R.string.use_server, deployment)) }
                } else {
                    Text(stringResource(R.string.signs_in_to, deployment), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = { otherServer = true }) { Text(stringResource(R.string.use_another_server)) }
                }
            }
        }
    }
}

@Composable
private fun ProjectsScreen(model: ProjectListModel, onOpen: (Project) -> Unit, onAccount: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.projects)) },
                actions = { IconButton(onClick = onAccount) { Icon(Icons.Default.AccountCircle, contentDescription = stringResource(R.string.account)) } },
            )
        },
    ) { padding ->
        PullToRefreshBox(isRefreshing = state.loading && state.projects.isNotEmpty(), onRefresh = { model.load() }, modifier = Modifier.padding(padding)) {
            LazyColumn(Modifier.fillMaxSize()) {
                state.error?.let { item { ErrorRow(it.message()) } }
                items(state.projects, key = { it.id }) { project ->
                    val repo = project.repository
                    ListItem(
                        headlineContent = { Text(project.name) },
                        supportingContent = if (repo != null) {
                            { Text(repo) }
                        } else null,
                        trailingContent = if (project.activeSessionCount > 0u) {
                            { Text(pluralStringResource(R.plurals.active_sessions, project.activeSessionCount.toInt(), project.activeSessionCount.toInt()), color = Color(0xFF22C55E), style = MaterialTheme.typography.labelMedium) }
                        } else null,
                        modifier = Modifier.clickable { onOpen(project) },
                    )
                    HorizontalDivider()
                }
            }
            Empty(
                loading = state.loading && state.projects.isEmpty(),
                empty = state.projects.isEmpty() && state.error == null,
                text = stringResource(R.string.no_projects, stringResource(R.string.app_name)),
            )
        }
    }
}

@Composable
private fun ProjectScreen(
    route: Route.Project,
    model: ProjectModel,
    onBack: () -> Unit,
    onOpen: (sessionId: String) -> Unit,
    onEditProfile: (profileId: String?) -> Unit,
) {
    val state by model.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable(route.id) { mutableStateOf("") }
    LaunchedEffect(route.id) { model.load(route.id) }
    // A switch keeps the previous project's rows until the core resets them.
    val sessions = if (state.projectId == route.id) state.sessions else emptyList()
    Scaffold(
        topBar = { BackBar(route.name, onBack) },
        bottomBar = {
            val current = state.projectId == route.id
            val attachments = if (current) state.attachments else emptyList()
            Column {
                if (current && (state.profiles.isNotEmpty() || !state.loading)) {
                    ProfileRow(state, onSelect = model::selectProfile, onEdit = onEditProfile)
                }
                Composer(stringResource(R.string.describe_task), draft, { draft = it }, busy = state.submitting, attachments, model::attach, model::detach) {
                    model.submit(draft, open = onOpen, sent = { draft = "" })
                }
            }
        },
    ) { padding ->
        PullToRefreshBox(isRefreshing = state.loading && sessions.isNotEmpty(), onRefresh = { model.load(route.id) }, modifier = Modifier.padding(padding)) {
            LazyColumn(Modifier.fillMaxSize()) {
                state.error?.let { item { ErrorRow(it.message()) } }
                items(sessions, key = { it.id }) { session ->
                    ListItem(
                        leadingContent = { StatusDot(session) },
                        headlineContent = { Text(session.topic ?: stringResource(R.string.untitled_session), maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text("${statusLabel(session)} · ${ago(session.lastMessageAt ?: session.startedAt)}") },
                        modifier = Modifier.clickable { onOpen(session.id) },
                    )
                    HorizontalDivider()
                }
            }
            Empty(
                loading = state.loading && sessions.isEmpty(),
                empty = sessions.isEmpty() && state.error == null,
                text = stringResource(R.string.no_sessions),
            )
        }
    }
}

@Composable
private fun ChatScreen(route: Route.Chat, model: ChatModel, onBack: () -> Unit, openUrl: (String) -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable(route.sessionId) { mutableStateOf("") }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Poll while on screen and in front; there is no push channel yet.
    LaunchedEffect(route) {
        model.vm.load(route.projectId, route.sessionId)
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val status = model.vm.state().session?.status
                delay(if (status == SessionStatus.STOPPED || status == SessionStatus.FAILED) 20_000 else 4_000)
                model.vm.refresh()
            }
        }
    }
    val current = state.sessionId == route.sessionId
    val messages = if (current) state.messages else emptyList()
    val session = state.session.takeIf { current }
    val provisioning = state.provisioning.takeIf { current }
    val list = rememberLazyListState()
    // Follow the conversation: the last message's row, after the optional task card.
    LaunchedEffect(messages.lastOrNull()?.id, provisioning != null) {
        val count = messages.size + (if (session?.task != null && provisioning == null) 1 else 0) + (if (provisioning != null) 1 else 0)
        if (count > 0) list.animateScrollToItem(count - 1)
    }

    Scaffold(
        topBar = {
            BackBar(session?.topic ?: stringResource(R.string.session), onBack) {
                if (session != null) {
                    StatusDot(session)
                    Spacer(Modifier.size(16.dp))
                }
            }
        },
        bottomBar = {
            if (session != null && (session.status == SessionStatus.ACTIVE || session.status == SessionStatus.SLEEPING)) {
                Composer(stringResource(R.string.reply_to_agent), draft, { draft = it }, busy = state.sending, if (current) state.attachments else emptyList(), model::attach, model::detach) {
                    model.send(draft) { draft = "" }
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            LazyColumn(state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (provisioning == null) session?.task?.let { task -> item { TaskCard(task, openUrl) } }
                items(messages, key = { it.id }) { message ->
                    if (message.requests.isEmpty()) MessageRow(message)
                    message.requests.forEach { request ->
                        RequestCard(model.app, route.projectId, request.sessionId ?: route.sessionId, request.id, request.secret, request.approval)
                    }
                }
                items(state.notifications.filter { n -> n.requestId == null || messages.none { m -> m.requests.any { it.id == n.requestId } } }, key = { "notification-${it.id}" }) { n ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp)) {
                            Text(n.title, style = MaterialTheme.typography.titleSmall)
                            n.requestId?.let { RequestCard(model.app, route.projectId, route.sessionId, it, n.kind == "secret_request", n.kind == "operations_approval") }
                                ?: n.body?.let { Text(it) }
                            n.actionUrl?.let { action -> org.simpleagentmanager.core.notificationUrl(model.app.state().serverUrl, action)?.let { url ->
                                TextButton(onClick = { openUrl(url) }) { Text(stringResource(R.string.open_on_web)) }
                            } }
                        }
                    }
                }
                state.notificationsError?.let { item { Text(it.message(), color = MaterialTheme.colorScheme.error) } }
                provisioning?.let { item(key = "provisioning") { ProvisioningCard(it) } }
                if (current) state.error?.let { item { Text(it.message(), color = MaterialTheme.colorScheme.error) } }
            }
            if (messages.isEmpty() && (state.loading || !current)) CircularProgressIndicator(Modifier.align(Alignment.Center))
        }
    }
}

@Composable
private fun MessageRow(message: ChatMessage) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    when (message.role) {
        MessageRole.USER -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Text(
                message.content,
                Modifier.widthIn(max = 320.dp)
                    .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(14.dp))
                    .padding(10.dp),
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
        MessageRole.ASSISTANT -> Text(message.content)
        MessageRole.THINKING -> Text(message.content, color = muted, fontStyle = FontStyle.Italic, maxLines = 4, overflow = TextOverflow.Ellipsis)
        MessageRole.TOOL -> Text(
            message.content,
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp)).padding(8.dp),
            color = muted,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        MessageRole.SYSTEM, MessageRole.PLAN, MessageRole.UNKNOWN -> Text(message.content, color = muted, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun TaskCard(task: TaskSummary, openUrl: (String) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val step = task.executionStep?.takeIf { task.status == "in_progress" || task.status == "queued" }
            Text(listOfNotNull(taskStatusLabel(task.status), step?.let(::humanize)).joinToString(" · "), fontWeight = FontWeight.Bold)
            task.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            task.outputSummary?.let { Text(it) }
            val pr = task.outputPrUrl
            if (pr != null) {
                TextButton(onClick = { openUrl(pr) }, contentPadding = PaddingValues(0.dp)) { Text(stringResource(R.string.open_pull_request)) }
            } else {
                task.outputBranch?.let { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}

@Composable
private fun AccountScreen(app: AppState, onBack: () -> Unit, onSignOut: () -> Unit) {
    Scaffold(topBar = { BackBar(stringResource(R.string.account), onBack) }) { padding ->
        Column(Modifier.padding(padding)) {
            app.viewer?.let { viewer ->
                ListItem(headlineContent = { Text(viewer.name) }, supportingContent = { Text(viewer.email) })
            } ?: Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            ListItem(headlineContent = { Text(stringResource(R.string.server)) }, supportingContent = { Text(app.serverUrl) })
            app.error?.let { ErrorRow(it.message()) }
            TextButton(onClick = onSignOut, modifier = Modifier.padding(horizontal = 8.dp)) {
                Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
internal fun BackBar(title: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back)) } },
        actions = actions,
    )
}

/**
 * Attach button, text field and send button under a list, with the attached
 * files above the field. Files dropped on it are attached too.
 */
@Composable
private fun Composer(
    placeholder: String,
    text: String,
    onChange: (String) -> Unit,
    busy: Boolean,
    attachments: List<Attachment>,
    onAttach: (List<Uri>) -> Unit,
    onRemove: (String) -> Unit,
    onSend: () -> Unit,
) {
    var dropHover by remember { mutableStateOf(false) }
    val ready = attachments.all { it.status is AttachmentStatus.Ready }
    Surface(
        tonalElevation = 3.dp,
        modifier = Modifier.fileDropTarget(onHover = { dropHover = it }, onDrop = onAttach),
        border = if (dropHover) BorderStroke(2.dp, MaterialTheme.colorScheme.primary) else null,
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(vertical = 8.dp)) {
            if (attachments.isNotEmpty()) AttachmentStrip(attachments, onRemove)
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.Bottom) {
                Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) { AttachButton(onAttach) }
                OutlinedTextField(
                    value = text,
                    onValueChange = onChange,
                    placeholder = { Text(placeholder) },
                    maxLines = 6,
                    modifier = Modifier.weight(1f),
                )
                Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
                    if (busy) {
                        CircularProgressIndicator(Modifier.size(24.dp))
                    } else {
                        IconButton(onClick = onSend, enabled = (text.isNotBlank() || attachments.isNotEmpty()) && ready) {
                            Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.send))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusDot(session: ChatSession) {
    val color = when (session.status) {
        SessionStatus.ACTIVE -> if (session.isIdle) Color(0xFFF59E0B) else Color(0xFF22C55E)
        SessionStatus.SLEEPING -> Color(0xFF3B82F6)
        SessionStatus.FAILED -> Color(0xFFEF4444)
        SessionStatus.STOPPED, SessionStatus.UNKNOWN -> Color.Gray
    }
    Box(Modifier.size(10.dp).background(color, CircleShape))
}

@Composable
internal fun ErrorRow(message: String) {
    Text(message, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
}

@Composable
private fun Empty(loading: Boolean, empty: Boolean, text: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        when {
            loading -> CircularProgressIndicator()
            empty -> Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun statusLabel(session: ChatSession) = stringResource(
    when (session.status) {
        SessionStatus.ACTIVE -> if (session.isIdle) R.string.status_waiting else R.string.status_working
        SessionStatus.SLEEPING -> R.string.status_sleeping
        SessionStatus.STOPPED -> R.string.status_stopped
        SessionStatus.FAILED -> R.string.status_failed
        SessionStatus.UNKNOWN -> R.string.status_unknown
    },
)

/** `TaskStatus` values (TASK_STATUSES in packages/shared/src/types/task.ts) for people. */
@Composable
private fun taskStatusLabel(status: String): String = when (status) {
    "draft" -> stringResource(R.string.task_draft)
    "ready" -> stringResource(R.string.task_ready)
    "queued" -> stringResource(R.string.task_queued)
    "delegated" -> stringResource(R.string.task_delegated)
    "in_progress" -> stringResource(R.string.task_in_progress)
    "sleeping" -> stringResource(R.string.status_sleeping)
    "completed" -> stringResource(R.string.task_completed)
    "failed" -> stringResource(R.string.status_failed)
    "cancelled" -> stringResource(R.string.task_cancelled)
    else -> humanize(status)
}

/** The core sends no wording; this gives a `UserError` its words. */
@Composable
fun UserError.message(): String = when (this) {
    is UserError.Offline -> stringResource(R.string.error_offline)
    UserError.SessionEnded -> stringResource(R.string.error_session_ended)
    is UserError.InvalidServer -> stringResource(R.string.error_invalid_server, input)
    UserError.HttpsRequired -> stringResource(R.string.error_https_required)
    UserError.SignInExpired -> stringResource(R.string.error_sign_in_expired)
    is UserError.Server -> message
    is UserError.Unexpected -> stringResource(R.string.error_unexpected, detail)
    UserError.FileEmpty -> stringResource(R.string.error_file_empty)
    is UserError.FileTooLarge -> stringResource(R.string.error_file_too_large, Formatter.formatShortFileSize(LocalContext.current, maxBytes.toLong()))
    UserError.FileUnreadable -> stringResource(R.string.error_file_unreadable)
    is UserError.TooManyFiles -> stringResource(R.string.error_too_many_files, max.toInt())
    is UserError.AttachmentsTooLarge -> stringResource(R.string.error_attachments_too_large, Formatter.formatShortFileSize(LocalContext.current, maxBytes.toLong()))
    UserError.AttachmentsNotReady -> stringResource(R.string.error_attachments_not_ready)
    UserError.ProfileNameRequired -> stringResource(R.string.error_profile_name_required)
    UserError.EffortNotSupported -> stringResource(R.string.error_effort_not_supported)
    is UserError.InvalidProfileNumber -> stringResource(R.string.error_invalid_profile_number, field.label())
}

/** Execution steps are progress detail: `in_progress` -> `In progress`, not translated. */
internal fun humanize(value: String) = value.replace('_', ' ').replaceFirstChar { it.uppercase() }

private fun ago(millis: Long): String = DateUtils.getRelativeTimeSpanString(millis).toString()
