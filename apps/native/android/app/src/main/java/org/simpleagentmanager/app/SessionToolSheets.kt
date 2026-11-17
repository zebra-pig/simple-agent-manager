@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.*
import java.util.UUID

/** Hosts one session tool in a bottom sheet, backed by its Rust view model. */
@Composable
internal fun SessionSheetHost(
    sheet: SessionSheet, chatModel: ChatModel, chat: ChatState, openUrl: (String) -> Unit,
    onOpenSession: (String) -> Unit, onClose: () -> Unit,
) {
    val tools: SessionToolsModel = viewModel()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val projectId = chat.projectId
    val sessionId = chat.sessionId
    ModalBottomSheet(onDismissRequest = onClose, containerColor = MaterialTheme.colorScheme.surface.copy(alpha = .97f)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.92f).padding(horizontal = 16.dp)) {
            when (sheet) {
                SessionSheet.Related -> {
                    val state by tools.relatedState.collectAsStateWithLifecycle()
                    suspend fun load() = tools.related.load(projectId, sessionId)
                    LaunchedEffect(sessionId) { load() }
                    ToolSheetHeader(stringResource(R.string.tool_related), state.loading, { scope.launch { load() } }, onClose)
                    InitialLoading(state.loading && state.work == null) {
                        RelatedContent(state,
                            onIdea = { idea -> openUrl(chatModel.vm.webUrl().substringBefore("/chat/") + "/ideas/" + idea.id) },
                            onFile = { file -> scope.launch { openLibraryFile(context, chatModel.vm, file.id, file.filename, "") } },
                            onPullRequest = { openUrl(it.url) })
                    }
                }
                SessionSheet.Automation -> {
                    val state by tools.automationState.collectAsStateWithLifecycle()
                    var reminding by remember { mutableStateOf(false) }
                    var key by remember { mutableStateOf(UUID.randomUUID().toString()) }
                    suspend fun load() = tools.automation.load(projectId, sessionId)
                    LaunchedEffect(sessionId) { load() }
                    ToolSheetHeader(stringResource(R.string.tool_automation), state.loading, { scope.launch { load() } }, onClose)
                    InitialLoading(state.loading && !state.loaded) {
                        AutomationContent(state, sessionId,
                            onStop = { wait, reason -> scope.launch { tools.automation.stopWaiting(wait.id, reason) } },
                            onRemind = { key = UUID.randomUUID().toString(); reminding = true })
                    }
                    if (reminding) ReminderDialog(state.busy, onDismiss = { reminding = false }) { prompt, due ->
                        scope.launch { if (tools.automation.remindLater(prompt, due, java.util.TimeZone.getDefault().id, key)) reminding = false }
                    }
                }
                SessionSheet.Comments -> {
                    val state by tools.commentsState.collectAsStateWithLifecycle()
                    var open by remember { mutableStateOf<String?>(null) }
                    suspend fun load() { chat.session?.let { tools.comments.load(projectId, it) } }
                    LaunchedEffect(sessionId) { load() }
                    val threadId = open
                    if (threadId == null) {
                        ToolSheetHeader(stringResource(R.string.tool_comments), state.loading, { scope.launch { load() } }, onClose)
                        InitialLoading(state.loading && !state.loaded) { CommentsContent(state, chat) { open = it.id } }
                    } else {
                        ToolSheetHeader(stringResource(R.string.st_comment), state.saving, null, onClose) {
                            IconButton(onClick = { open = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back)) }
                        }
                        CommentThreadContent(state.threads.firstOrNull { it.id == threadId }, state, chat,
                            onReply = { body, send, done -> scope.launch { if (tools.comments.reply(threadId, body, send, UUID.randomUUID().toString())) done() } },
                            onSend = { scope.launch { tools.comments.sendToAgent(threadId, UUID.randomUUID().toString()) } },
                            onResolve = { scope.launch { tools.comments.resolve(threadId) } },
                            onReopen = { scope.launch { tools.comments.reopen(threadId) } })
                    }
                }
                is SessionSheet.NewComment -> {
                    val state by tools.commentsState.collectAsStateWithLifecycle()
                    val clientId = remember(sheet.messageId) { UUID.randomUUID().toString() }
                    LaunchedEffect(sessionId) { if (!state.loaded || state.sessionId != sessionId) chat.session?.let { tools.comments.load(projectId, it) } }
                    ToolSheetHeader(stringResource(R.string.st_new_comment), state.saving, null, onClose)
                    NewCommentContent(sheet.messageId, state, chat) { body, send ->
                        scope.launch { if (tools.comments.create(sheet.messageId, null, body, send, clientId)) onClose() }
                    }
                }
                SessionSheet.Share -> {
                    val state by tools.accessState.collectAsStateWithLifecycle()
                    var confirming by remember { mutableStateOf<Pair<String, Pair<String, Boolean>>?>(null) }
                    val shareable = chat.session?.status in listOf(SessionStatus.ACTIVE, SessionStatus.SLEEPING)
                    suspend fun load() = tools.access.load(projectId, sessionId, shareable)
                    LaunchedEffect(sessionId) { load() }
                    val target = confirming
                    if (target == null) {
                        ToolSheetHeader(stringResource(R.string.tool_share), state.loading, { scope.launch { load() } }, onClose)
                        InitialLoading(state.loading && !state.loaded) {
                            ShareContent(state,
                                onAdd = { confirming = it.userId to (it.label to false) },
                                onRenew = { confirming = it.grantee.id to ((it.grantee.name ?: it.grantee.id) to true) },
                                onRevoke = { scope.launch { tools.access.revoke(it.grantee.id) } })
                        }
                    } else {
                        ToolSheetHeader(stringResource(R.string.tool_share), state.saving, null, onClose) {
                            IconButton(onClick = { confirming = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back)) }
                        }
                        ShareConfirmContent(state, target.second.first, target.second.second, remember { shareDurations() }, { shareEndsAt(state, it, System.currentTimeMillis()) }) { minutes ->
                            scope.launch { if (tools.access.grant(target.first, minutes, true)) confirming = null }
                        }
                    }
                }
                SessionSheet.Report -> {
                    val state by tools.reportState.collectAsStateWithLifecycle()
                    val toolsState by chatModel.toolsState.collectAsStateWithLifecycle()
                    LaunchedEffect(Unit) { tools.report.reset() }
                    val refs = ReportRefs(sessionId, chat.session?.taskId ?: chat.session?.task?.id, toolsState.workspace?.nodeId)
                    ToolSheetHeader(stringResource(R.string.st_report_title), state.submitting, null, onClose)
                    ReportContent(state, refs, remember(refs) { reportRefsPresent(refs) }) { title, details, attach -> scope.launch { tools.report.submit(title, details, attach, refs) } }
                }
                is SessionSheet.Derived -> DerivedSheet(sheet.kind, chat, onOpenSession, onClose)
            }
        }
    }
}

/** Retry or Fork: a prefilled composer with the profile picker; nothing is sent until Send. */
@Composable
private fun ColumnScope.DerivedSheet(kind: DerivedKind, chat: ChatState, onOpenSession: (String) -> Unit, onClose: () -> Unit) {
    val project: ProjectModel = viewModel(key = "derived-${chat.sessionId}-$kind")
    val state by project.state.collectAsStateWithLifecycle()
    var draft by remember(kind) { mutableStateOf("") }
    val session = chat.session
    LaunchedEffect(kind, chat.sessionId) {
        project.vm.load(chat.projectId)
        if (session != null) {
            val prefill = project.vm.derive(kind, session)
            if (draft.isEmpty()) draft = prefill
        }
    }
    ToolSheetHeader(stringResource(if (kind == DerivedKind.RETRY) R.string.tool_retry else R.string.tool_fork), false, null, onClose = { project.vm.cancelDerived(); onClose() })
    Column(Modifier.weight(1f)) {
        state.error?.let { ErrorRow(it.message()) }
        DerivedBanner(kind, state.derived)
    }
    if (state.profiles.isNotEmpty()) ProfileRow(state, onSelect = project::selectProfile, onEdit = null)
    Composer(stringResource(if (kind == DerivedKind.RETRY) R.string.st_retry_placeholder else R.string.st_fork_placeholder), draft, { draft = it },
        busy = state.submitting || state.derived?.promptLoading == true, state.attachments, project::attach, project::detach) {
        project.submit(draft, open = { onClose(); onOpenSession(it) }, sent = { draft = "" })
    }
}
