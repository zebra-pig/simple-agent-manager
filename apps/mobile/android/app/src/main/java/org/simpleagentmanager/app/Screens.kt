@file:OptIn(ExperimentalMaterial3Api::class)

package org.simpleagentmanager.app

import android.os.Build
import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
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
import org.simpleagentmanager.core.AuthStatus
import org.simpleagentmanager.core.ChatMessage
import org.simpleagentmanager.core.ChatSession
import org.simpleagentmanager.core.MessageRole
import org.simpleagentmanager.core.Project
import org.simpleagentmanager.core.SessionStatus
import org.simpleagentmanager.core.TaskSummary

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
    when (val route = session.stack.last()) {
        Route.Projects -> ProjectsScreen(projects, onOpen = { session.push(Route.Project(it.id, it.name)) }, onAccount = { session.push(Route.Account) })
        Route.Account -> AccountScreen(app, onBack = session::pop, onSignOut = { session.signOut() })
        is Route.Project -> ProjectScreen(route, project, onBack = session::pop, onOpen = { session.push(Route.Chat(route.id, it)) })
        is Route.Chat -> ChatScreen(route, chat, onBack = session::pop, openUrl = openUrl)
    }
}

@Composable
private fun SignInScreen(app: AppState, onSignIn: (String) -> Unit, onOpen: (String) -> Unit, onCancel: () -> Unit) {
    var server by rememberSaveable { mutableStateOf(app.serverUrl) }
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.padding(24.dp).navigationBarsPadding().imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.weight(1f))
            Text("SAM", style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
            Text("Your coding agents, at hand.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            val pending = app.signIn
            if (pending != null) {
                Text("Approve this code in the browser", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(pending.userCode, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                CircularProgressIndicator()
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { onOpen(pending.verificationUrl) }) { Text("Open again") }
                    TextButton(onClick = onCancel) { Text("Cancel") }
                }
            } else {
                OutlinedTextField(
                    value = server,
                    onValueChange = { server = it },
                    label = { Text("Server") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
                app.error?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
                Button(
                    onClick = { onSignIn(server) },
                    enabled = app.status != AuthStatus.SIGNING_IN && server.isNotBlank(),
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) { Text("Sign in") }
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
                title = { Text("Projects") },
                actions = { IconButton(onClick = onAccount) { Icon(Icons.Default.AccountCircle, contentDescription = "Account") } },
            )
        },
    ) { padding ->
        PullToRefreshBox(isRefreshing = state.loading && state.projects.isNotEmpty(), onRefresh = { model.load() }, modifier = Modifier.padding(padding)) {
            LazyColumn(Modifier.fillMaxSize()) {
                state.error?.let { item { ErrorRow(it) } }
                items(state.projects, key = { it.id }) { project ->
                    val repo = project.repository
                    ListItem(
                        headlineContent = { Text(project.name) },
                        supportingContent = if (repo != null) {
                            { Text(repo) }
                        } else null,
                        trailingContent = if (project.activeSessionCount > 0u) {
                            { Text("${project.activeSessionCount} active", color = Color(0xFF22C55E), style = MaterialTheme.typography.labelMedium) }
                        } else null,
                        modifier = Modifier.clickable { onOpen(project) },
                    )
                    HorizontalDivider()
                }
            }
            Empty(
                loading = state.loading && state.projects.isEmpty(),
                empty = state.projects.isEmpty() && state.error == null,
                text = "No projects. Create one in SAM on the web to get started.",
            )
        }
    }
}

@Composable
private fun ProjectScreen(route: Route.Project, model: ProjectModel, onBack: () -> Unit, onOpen: (sessionId: String) -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable(route.id) { mutableStateOf("") }
    LaunchedEffect(route.id) { model.load(route.id) }
    // A switch keeps the previous project's rows until the core resets them.
    val sessions = if (state.projectId == route.id) state.sessions else emptyList()
    Scaffold(
        topBar = { BackBar(route.name, onBack) },
        bottomBar = {
            Composer("Describe a task…", draft, { draft = it }, busy = state.submitting) {
                model.submit(draft, open = onOpen, sent = { draft = "" })
            }
        },
    ) { padding ->
        PullToRefreshBox(isRefreshing = state.loading && sessions.isNotEmpty(), onRefresh = { model.load(route.id) }, modifier = Modifier.padding(padding)) {
            LazyColumn(Modifier.fillMaxSize()) {
                state.error?.let { item { ErrorRow(it) } }
                items(sessions, key = { it.id }) { session ->
                    ListItem(
                        leadingContent = { StatusDot(session) },
                        headlineContent = { Text(session.topic ?: "Untitled session", maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text("${statusLabel(session)} · ${ago(session.lastMessageAt ?: session.startedAt)}") },
                        modifier = Modifier.clickable { onOpen(session.id) },
                    )
                    HorizontalDivider()
                }
            }
            Empty(
                loading = state.loading && sessions.isEmpty(),
                empty = sessions.isEmpty() && state.error == null,
                text = "No sessions yet. Describe a task below and an agent picks it up.",
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
    val list = rememberLazyListState()
    // Follow the conversation: the last message's row, after the optional task card.
    LaunchedEffect(messages.lastOrNull()?.id) {
        if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1 + if (session?.task != null) 1 else 0)
    }

    Scaffold(
        topBar = {
            BackBar(session?.topic ?: "Session", onBack) {
                if (session != null) {
                    StatusDot(session)
                    Spacer(Modifier.size(16.dp))
                }
            }
        },
        bottomBar = {
            if (session != null && (session.status == SessionStatus.ACTIVE || session.status == SessionStatus.SLEEPING)) {
                Composer("Reply to the agent…", draft, { draft = it }, busy = state.sending) {
                    model.send(draft) { draft = "" }
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            LazyColumn(state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                session?.task?.let { task -> item { TaskCard(task, openUrl) } }
                items(messages, key = { it.id }) { MessageRow(it) }
                if (current) state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
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
            Text(listOfNotNull(humanize(task.status), step?.let(::humanize)).joinToString(" · "), fontWeight = FontWeight.Bold)
            task.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            task.outputSummary?.let { Text(it) }
            val pr = task.outputPrUrl
            if (pr != null) {
                TextButton(onClick = { openUrl(pr) }, contentPadding = PaddingValues(0.dp)) { Text("Open pull request") }
            } else {
                task.outputBranch?.let { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}

@Composable
private fun AccountScreen(app: AppState, onBack: () -> Unit, onSignOut: () -> Unit) {
    Scaffold(topBar = { BackBar("Account", onBack) }) { padding ->
        Column(Modifier.padding(padding)) {
            app.viewer?.let { viewer ->
                ListItem(headlineContent = { Text(viewer.name) }, supportingContent = { Text(viewer.email) })
            } ?: Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            ListItem(headlineContent = { Text("Server") }, supportingContent = { Text(app.serverUrl) })
            app.error?.let { ErrorRow(it) }
            TextButton(onClick = onSignOut, modifier = Modifier.padding(horizontal = 8.dp)) {
                Text("Sign out", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun BackBar(title: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
        actions = actions,
    )
}

/** Text field + send button under a list. */
@Composable
private fun Composer(placeholder: String, text: String, onChange: (String) -> Unit, busy: Boolean, onSend: () -> Unit) {
    Surface(tonalElevation = 3.dp) {
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
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
                    IconButton(onClick = onSend, enabled = text.isNotBlank()) {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send")
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
private fun ErrorRow(message: String) {
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

private fun statusLabel(session: ChatSession) = when (session.status) {
    SessionStatus.ACTIVE -> if (session.isIdle) "Waiting for you" else "Working"
    SessionStatus.SLEEPING -> "Sleeping"
    SessionStatus.STOPPED -> "Stopped"
    SessionStatus.FAILED -> "Failed"
    SessionStatus.UNKNOWN -> "Unknown"
}

/** `in_progress` -> `In progress`. */
private fun humanize(value: String) = value.replace('_', ' ').replaceFirstChar { it.uppercase() }

private fun ago(millis: Long): String = DateUtils.getRelativeTimeSpanString(millis).toString()
