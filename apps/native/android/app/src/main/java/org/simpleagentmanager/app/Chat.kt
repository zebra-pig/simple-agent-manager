package org.simpleagentmanager.app

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.*
import org.simpleagentmanager.core.ChatContent as Content

@Composable
fun ChatScreen(route: Route.Chat, model: ChatModel, onBack: () -> Unit, openUrl: (String) -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable(route.sessionId) { mutableStateOf("") }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(route) {
        model.vm.load(route.projectId, route.sessionId)
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                delay(if (model.vm.state().session?.status in listOf(SessionStatus.STOPPED, SessionStatus.FAILED)) 20_000 else 4_000)
                model.vm.refresh()
            }
        }
    }
    if (state.sessionId == route.sessionId) {
        ChatContent(state, draft, { draft = it }, onBack, openUrl, model::attach, model::detach) {
            val sent = draft
            draft = ""
            model.send(sent) { ok -> if (!ok && draft.isEmpty()) draft = sent }
        }
    } else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

/** Renders snapshots without a view model, network or native runtime. */
@Composable
fun ChatContent(
    state: ChatState, draft: String, onDraft: (String) -> Unit,
    onBack: () -> Unit, openUrl: (String) -> Unit,
    onAttach: (List<Uri>) -> Unit, onRemove: (String) -> Unit, onSend: () -> Unit,
) {
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val atBottom by remember { derivedStateOf { !list.canScrollForward } }
    var followsLatest by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress to list.canScrollForward }.collect { (scrolling, more) ->
            if (scrolling) followsLatest = !more
        }
    }
    val session = state.session
    LaunchedEffect(state.items, state.outbox, state.working) {
        if (followsLatest || state.outbox.isNotEmpty()) {
            withFrameNanos { }
            if (list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1)
        }
    }
    Scaffold(
        topBar = { BackBar(session?.topic ?: stringResource(R.string.session), onBack) { session?.let { StatusDot(it); Spacer(Modifier.width(16.dp)) } } },
        bottomBar = {
            if (session?.status in listOf(SessionStatus.ACTIVE, SessionStatus.SLEEPING))
                Composer(stringResource(R.string.reply_to_agent), draft, onDraft, state.sending, state.attachments, onAttach, onRemove, onSend)
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            LazyColumn(Modifier.widthIn(max = 840.dp).fillMaxSize().align(Alignment.TopCenter).testTag("chat-timeline"), state = list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                session?.task?.let { item("task") { TaskCard(it, openUrl) } }
                if (state.hasMore) item("history") { Text(stringResource(R.string.latest_messages), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(state.items, key = { "message-${it.id}" }) { TimelineItem(it, openUrl) }
                items(state.outbox, key = { it.id }) {
                    Column(horizontalAlignment = Alignment.End, modifier = Modifier.fillMaxWidth()) {
                        UserBubble(it.text)
                        Text(stringResource(if (it.accepted) R.string.message_queued else R.string.message_sending), style = MaterialTheme.typography.labelSmall)
                    }
                }
                if (state.working) item("working") { Text(stringResource(R.string.status_working), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium) }
                state.error?.let { item("error") { ErrorRow(it.message()) } }
                if (state.items.isEmpty() && !state.loading && state.error == null) item("empty") { Text(stringResource(R.string.chat_empty), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            if (state.loading && state.items.isEmpty()) CircularProgressIndicator(Modifier.align(Alignment.Center))
            if (!atBottom) LatestArrow(
                onClick = { scope.launch { list.animateScrollToItem((list.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)) } },
                modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp),
            )
        }
    }
}

@Composable
private fun UserBubble(text: String) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = Modifier.widthIn(max = 340.dp)) {
            SelectionContainer { Text(text, Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) }
        }
    }
}

@Composable
private fun TimelineItem(item: ChatItem, openUrl: (String) -> Unit) {
    when (val content = item.content) {
        is Content.User -> UserBubble(content.text)
        is Content.Agent -> SelectionContainer { MarkdownBlocks(content.blocks, openUrl) }
        is Content.Thinking -> Detail(stringResource(R.string.thinking), content.text)
        is Content.Activity -> {
            var expanded by rememberSaveable(item.id) { mutableStateOf(false) }
            Column {
                TextButton(onClick = { expanded = !expanded }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) {
                    Text(stringResource(R.string.activity_count, content.summary.toolCount.toInt()) + if (content.summary.failedCount > 0u) stringResource(R.string.activity_failed, content.summary.failedCount.toInt()) else "")
                }
                if (content.summary.live) content.summary.liveTitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (expanded) content.steps.forEach { step ->
                    when (step) {
                        is ActivityStep.Thought -> Detail(stringResource(R.string.thinking), step.text)
                        is ActivityStep.Tool -> Column(Modifier.padding(start = 12.dp, bottom = 10.dp)) {
                            val call = step.call
                            Text(call.title ?: toolLabel(call.kind), style = MaterialTheme.typography.bodyMedium, fontFamily = if (call.titleIsCode) FontFamily.Monospace else null, color = if (call.status == ToolStatus.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                            call.locations.forEach { Text(it, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace) }
                            call.output?.let { Detail(stringResource(R.string.tool_output), it, code = true) }
                        }
                    }
                }
            }
        }
        is Content.Plan -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.agent_plan), style = MaterialTheme.typography.titleSmall)
            content.entries.forEach { entry -> Text("${when(entry.status) { PlanStatus.COMPLETED -> "✓"; PlanStatus.IN_PROGRESS -> "◉"; else -> "○" }}  ${entry.content}", color = if (entry.status == PlanStatus.IN_PROGRESS) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        is Content.Notice -> {
            val notice = content.notice
            val headline = notice.headline ?: stringResource(if (notice.source == NoticeSource.WORKSPACE) R.string.workspace_report else R.string.chat_context)
            Surface(shape = MaterialTheme.shapes.medium, color = if (notice.severity == NoticeSeverity.ERROR) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainer) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    Text(headline, style = MaterialTheme.typography.labelLarge)
                    notice.detail?.let { Detail(stringResource(R.string.details), it) }
                }
            }
        }
    }
}

@Composable
private fun Detail(title: String, text: String, code: Boolean = false) {
    var expanded by rememberSaveable(title) { mutableStateOf(false) }
    Column {
        TextButton(onClick = { expanded = !expanded }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) { Text(title) }
        if (expanded) SelectionContainer {
            if (code) CodeBlock(text, null) else Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun toolLabel(kind: ToolKind) = stringResource(when (kind) {
    ToolKind.READ -> R.string.tool_read
    ToolKind.EDIT -> R.string.tool_edit
    ToolKind.DELETE -> R.string.tool_delete
    ToolKind.MOVE -> R.string.tool_move
    ToolKind.SEARCH -> R.string.tool_search
    ToolKind.EXECUTE -> R.string.tool_execute
    ToolKind.THINK -> R.string.thinking
    ToolKind.FETCH -> R.string.tool_fetch
    ToolKind.SWITCH_MODE -> R.string.tool_mode
    ToolKind.OTHER -> R.string.tool_other
})

@Composable
internal fun LatestArrow(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        contentColor = MaterialTheme.colorScheme.onSurface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        shadowElevation = 6.dp,
        modifier = modifier,
    ) {
        IconButton(onClick = onClick, modifier = Modifier.size(48.dp)) {
            Icon(painterResource(R.drawable.ic_arrow_down), contentDescription = stringResource(R.string.jump_latest))
        }
    }
}
