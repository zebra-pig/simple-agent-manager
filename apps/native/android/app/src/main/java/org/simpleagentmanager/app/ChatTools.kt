@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.simpleagentmanager.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.*
import java.text.DateFormat
import java.util.Date

internal enum class ChatTool(val title: Int) {
    Files(R.string.tool_files), Git(R.string.tool_git), Timeline(R.string.tool_timeline), Resources(R.string.tool_resources), Details(R.string.tool_details)
}

@Composable
fun ChatToolsMenu(model: ChatModel, chat: ChatState, openUrl: (String) -> Unit) {
    var menu by remember(chat.sessionId) { mutableStateOf(false) }
    var tool by remember(chat.sessionId) { mutableStateOf<ChatTool?>(null) }
    var confirm by remember(chat.sessionId) { mutableStateOf(false) }
    var ending by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val session = chat.session
    val drives = session?.let { it.viewerAccess == "owner" || it.viewerAccess == "grantee" || (it.viewerAccess == null && it.isMine) } == true
    val end = if (drives) when (session?.task?.status) {
        "in_progress", "sleeping" -> R.string.tool_complete
        "draft", "ready", "queued", "delegated" -> R.string.tool_cancel
        else -> null
    } else null
    Box {
        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .65f), border = BorderStroke(.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .5f))) {
            IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.session_tools)) }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(24.dp), containerColor = MaterialTheme.colorScheme.surface.copy(alpha = .96f)) {
            ChatToolsMenuItems(chat, ending, onTool = { menu = false; tool = it },
                onWeb = { menu = false; openUrl(model.vm.webToolUrl(it)) }, onEnd = { menu = false; confirm = true })
        }
    }
    if (confirm && end != null) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text(stringResource(end)) }, text = { Text(stringResource(R.string.end_task_message)) },
        confirmButton = { TextButton(onClick = { confirm = false; ending = true; scope.launch { try { model.vm.endTask() } finally { ending = false } } }) { Text(stringResource(end)) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
    )
    tool?.let { selected ->
        val state by model.toolsState.collectAsStateWithLifecycle()
        ModalBottomSheet(onDismissRequest = { tool = null }, containerColor = MaterialTheme.colorScheme.surface.copy(alpha = .97f)) {
            ChatToolContent(selected, chat, state, model.tools, model.vm, openUrl, onClose = { tool = null })
        }
    }
}

@Composable
internal fun ChatToolsMenuItems(chat: ChatState, ending: Boolean, onTool: (ChatTool) -> Unit, onWeb: (WebChatTool) -> Unit, onEnd: () -> Unit) {
    val session = chat.session
    val drives = session?.let { it.viewerAccess == "owner" || it.viewerAccess == "grantee" || (it.viewerAccess == null && it.isMine) } == true
    val end = if (drives) when (session?.task?.status) {
        "in_progress", "sleeping" -> R.string.tool_complete
        "draft", "ready", "queued", "delegated" -> R.string.tool_cancel
        else -> null
    } else null
            Text(stringResource(R.string.workspace_history), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelSmall)
            if (drives && session?.workspaceId != null && session.status == SessionStatus.ACTIVE) {
                ToolMenuItem(ChatTool.Files) { onTool(it) }
                ToolMenuItem(ChatTool.Git) { onTool(it) }
            }
            ToolMenuItem(ChatTool.Timeline) { onTool(it) }
            WebToolMenuItem(R.string.tool_related) { onWeb(WebChatTool.RELATED) }
            ToolMenuItem(ChatTool.Resources) { onTool(it) }
            WebToolMenuItem(R.string.tool_automation) { onWeb(WebChatTool.AUTOMATION) }
            WebToolMenuItem(R.string.tool_comments) { onWeb(WebChatTool.COMMENTS) }
            HorizontalDivider(Modifier.padding(vertical = 6.dp))
            if (session?.viewerAccess != null) WebToolMenuItem(R.string.tool_share) { onWeb(WebChatTool.SHARE) }
            val task = session?.task
            if (task != null) {
                if (!(task.status == "cancelled" && task.terminalReason == "snapshot_expired")) WebToolMenuItem(R.string.tool_retry) { onWeb(WebChatTool.RETRY) }
                WebToolMenuItem(R.string.tool_fork) { onWeb(WebChatTool.FORK) }
            }
            HorizontalDivider(Modifier.padding(vertical = 6.dp))
            if (chat.reportEnabled) WebToolMenuItem(R.string.tool_report) { onWeb(WebChatTool.REPORT) }
            if (end != null) DropdownMenuItem(text = { Text(stringResource(end)) }, enabled = !ending, onClick = { onEnd() })
            ToolMenuItem(ChatTool.Details) { onTool(it) }
}

@Composable
private fun ToolMenuItem(tool: ChatTool, onSelect: (ChatTool) -> Unit) = DropdownMenuItem(text = { Text(stringResource(tool.title)) }, onClick = { onSelect(tool) })

@Composable
private fun WebToolMenuItem(title: Int, onClick: () -> Unit) = DropdownMenuItem(
    text = { Text(stringResource(R.string.web_tool_label, stringResource(title))) }, onClick = onClick,
)

/** Neutral, translucent surfaces with a light rim, shared by the tools. */
@Composable
private fun ToolGlass(content: @Composable ColumnScope.() -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(
        Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        color = colors.surface.copy(alpha = .72f),
        border = BorderStroke(.5.dp, colors.outlineVariant.copy(alpha = .5f)), shadowElevation = 2.dp,
    ) { Column(Modifier.background(Brush.verticalGradient(listOf(colors.onSurface.copy(alpha = .035f), Color.Transparent))).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content) }
}

@Composable
private fun ChatToolContent(tool: ChatTool, chat: ChatState, state: ChatToolsState, vm: ChatToolsViewModel, chatVm: ChatViewModel, openUrl: (String) -> Unit, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var file by remember(tool, chat.sessionId) { mutableStateOf<String?>(null) }
    var diff by remember(tool) { mutableStateOf(false) }
    var staged by remember(tool) { mutableStateOf(false) }
    var filter by remember(tool) { mutableStateOf("") }
    suspend fun refresh() {
        val path = file
        if (path != null) { vm.openFile(path, diff, staged); return }
        when (tool) {
            ChatTool.Files -> vm.browse(state.path.ifEmpty { "." })
            ChatTool.Git -> vm.gitStatus()
            ChatTool.Resources -> vm.resources()
            ChatTool.Details -> {
                val s = chat.session
                val owner = s?.viewerAccess == "owner" || (s?.viewerAccess == null && s?.isMine == true)
                vm.details(if (owner) s?.workspaceId else null, s?.agentSessionId)
            }
            ChatTool.Timeline -> Unit
        }
    }
    fun open(path: String, isDiff: Boolean = false, isStaged: Boolean = false) {
        file = path; diff = isDiff; staged = isStaged
        scope.launch { vm.openFile(path, isDiff, isStaged) }
    }
    LaunchedEffect(tool, chat.sessionId) { refresh() }
    Column(Modifier.fillMaxWidth().fillMaxHeight(.92f).padding(horizontal = 16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(stringResource(tool.title), style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(vertical = 10.dp))
            TextButton(onClick = { scope.launch { refresh() } }, enabled = !state.loading) { Text(stringResource(R.string.tool_refresh)) }
            TextButton(onClick = onClose) { Text(stringResource(R.string.done)) }
        }
        if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant)
        state.error?.let { error -> Text(error.message(), color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(8.dp)) }
        if (file != null) {
            Row {
                TextButton(onClick = { file = null; scope.launch { refresh() } }) { Text(stringResource(R.string.tool_back)) }
                if (diff) TextButton(onClick = { diff = false; scope.launch { vm.openFile(file!!, false, false) } }) { Text(stringResource(R.string.view_file)) }
            }
            SelectionContainer { Text(file!!, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall) }
            CodeContent(state.lines, diff)
        } else {
            if (tool == ChatTool.Files || tool == ChatTool.Git) OutlinedTextField(
                value = filter, onValueChange = { filter = it }, label = { Text(stringResource(R.string.filter_files)) }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), singleLine = true,
            )
            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(bottom = 32.dp), modifier = Modifier.fillMaxWidth()) {
                when (tool) {
                    ChatTool.Files -> {
                        item {
                            Text(state.path, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
                            if (state.path != "." && state.path.isNotEmpty()) TextButton(onClick = {
                                scope.launch { vm.browse(state.path.substringBeforeLast('/', ".").ifEmpty { "." }) }
                            }) { Text(stringResource(R.string.parent_folder)) }
                            if (state.entries.isEmpty() && !state.loading) Text(stringResource(R.string.empty_folder))
                        }
                        items(state.entries.filter { it.name.contains(filter, ignoreCase = true) }, key = { it.name }) { entry ->
                            ToolGlass {
                                TextButton(onClick = {
                                    val path = if (state.path == ".") entry.name else "${state.path}/${entry.name}"
                                    if (entry.kind == "dir") scope.launch { vm.browse(path) } else open(path)
                                }) {
                                    Text(stringResource(if (entry.kind == "dir") R.string.folder_entry else R.string.file_entry, entry.name), modifier = Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurface)
                                }
                            }
                        }
                    }
                    ChatTool.Git -> {
                        if (state.changes.isEmpty() && !state.loading) item { Text(stringResource(R.string.no_changes)) }
                        for (group in 0..2) {
                            val entries = state.changes.filter { if (group == 0) it.staged else if (group == 1) !it.staged && !it.untracked else it.untracked }
                            if (entries.isNotEmpty()) item { Text(stringResource(if (group == 0) R.string.git_staged else if (group == 1) R.string.git_changes else R.string.git_untracked), style = MaterialTheme.typography.titleSmall) }
                            items(entries.filter { it.path.contains(filter, ignoreCase = true) }, key = { "$group:${it.path}" }) { entry ->
                                ToolGlass {
                                    TextButton(onClick = { open(entry.path, !entry.untracked, entry.staged) }) {
                                        Text("${entry.status}  ${entry.path}", fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.fillMaxWidth())
                                    }
                                    entry.oldPath?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
                                }
                            }
                        }
                    }
                    ChatTool.Resources -> {
                        item { Text(stringResource(R.string.resource_caption), style = MaterialTheme.typography.bodySmall) }
                        if (state.points.isEmpty() && !state.loading) item { Text(stringResource(if (state.collection == "pending") R.string.resource_pending else R.string.resource_unavailable)) }
                        if (state.omittedChunks > 0u) item { Text(stringResource(R.string.resource_omitted)) }
                        item { ResourceGraph(stringResource(R.string.chart_cpu), state.points, 1.0) { it.cpuCores } }
                        item { ResourceGraph(stringResource(R.string.chart_memory), state.points, 1048576.0) { it.memoryBytes } }
                        item { ResourceGraph(stringResource(R.string.chart_read), state.points, 1048576.0) { it.readBytes } }
                        item { ResourceGraph(stringResource(R.string.chart_write), state.points, 1048576.0) { it.writeBytes } }
                    }
                    ChatTool.Details -> {
                        item { SessionDetails(chat, state) }
                    }
                    ChatTool.Timeline -> {
                        items(chat.items, key = { it.id }) { message -> ToolGlass {
                            Text(DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(message.createdAt)), style = MaterialTheme.typography.labelSmall)
                            val document = (message.content as? org.simpleagentmanager.core.ChatContent.Document)?.document
                            if (document != null) DocumentCard(document, chat.items.mapNotNull { (it.content as? org.simpleagentmanager.core.ChatContent.Document)?.document }, chatVm)
                            else TimelineItem(message, openUrl)
                        } }
                    }
                }
            }
        }
    }
}

@Composable
internal fun CodeContent(lines: List<CodeLine>, diff: Boolean) {
    val style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
    val measurer = rememberTextMeasurer()
    val longest = lines.maxByOrNull { it.text.length }?.text.orEmpty()
    val textWidth = with(LocalDensity.current) { measurer.measure(AnnotatedString(longest), style = style, softWrap = false).size.width.toDp() }
    SelectionContainer {
        Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            LazyColumn(Modifier.width(maxOf(600.dp, textWidth + if (diff) 110.dp else 68.dp)), contentPadding = PaddingValues(vertical = 12.dp)) {
                if (lines.isEmpty()) item { Text(stringResource(R.string.no_file_content)) }
                items(lines.size) { i ->
                    val line = lines[i]
                    val color = when (line.kind) { CodeKind.ADDED -> Color(0x182eaa68); CodeKind.REMOVED -> Color(0x18e45c68); CodeKind.HEADER -> MaterialTheme.colorScheme.onSurface.copy(alpha = .06f); else -> Color.Transparent }
                    Row(Modifier.fillMaxWidth().background(color).padding(horizontal = 8.dp, vertical = 2.dp)) {
                        if (diff) Text(line.oldNumber?.toString() ?: "", Modifier.width(42.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(line.newNumber?.toString() ?: "", Modifier.width(42.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(line.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, softWrap = false)
                    }
                }
            }
        }
    }
}

/** Each point represents one rollup bucket. No line bridges missing samples or VM runs. */
@Composable
internal fun ResourceGraph(title: String, points: List<ResourcePoint>, unit: Double, value: (ResourcePoint) -> Double?) {
    val data = points.mapNotNull { p -> value(p)?.let { p.time to it / unit } }
    val max = data.maxOfOrNull { it.second }?.coerceAtLeast(.001) ?: 1.0
    val first = points.firstOrNull()?.time ?: 0L
    val last = points.lastOrNull()?.time ?: first + 1
    val ink = MaterialTheme.colorScheme.onSurfaceVariant
    val description = stringResource(R.string.chart_summary, title, data.size, "%.2f".format(max))
    ToolGlass {
        Text(title, style = MaterialTheme.typography.titleSmall)
        Text(stringResource(R.string.chart_peak, "%.2f".format(max)), style = MaterialTheme.typography.labelSmall)
        Canvas(Modifier.fillMaxWidth().height(140.dp).semantics { contentDescription = description }) {
            drawLine(ink.copy(alpha = .25f), Offset(0f, size.height), Offset(size.width, size.height))
            points.zipWithNext().forEach { (a, b) ->
                val av = value(a); val bv = value(b)
                if (av != null && bv != null && a.runId == b.runId && b.time - a.time in 1..60_000) {
                    fun position(p: ResourcePoint, v: Double) = Offset(
                        (((p.time - first).toDouble() / (last - first).coerceAtLeast(1)).toFloat() * size.width).coerceIn(3.dp.toPx(), size.width - 3.dp.toPx()),
                        (size.height - (v / unit / max).toFloat() * (size.height - 8.dp.toPx())).coerceAtLeast(4.dp.toPx()),
                    )
                    drawLine(ink.copy(alpha = .65f), position(a, av), position(b, bv), strokeWidth = 1.5.dp.toPx())
                }
            }
            data.forEach { (time, y) ->
                val x = ((time - first).toDouble() / (last - first).coerceAtLeast(1)).toFloat() * size.width
                drawCircle(ink, 3.dp.toPx(), Offset(x.coerceIn(3.dp.toPx(), size.width - 3.dp.toPx()), (size.height - (y / max).toFloat() * (size.height - 8.dp.toPx())).coerceAtLeast(4.dp.toPx())))
            }
        }
        if (points.isNotEmpty()) Text("${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(first))} – ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(last))}", style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun SessionDetails(chat: ChatState, state: ChatToolsState) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ToolGlass {
            Text(stringResource(R.string.tool_details), style = MaterialTheme.typography.titleSmall)
            SelectionContainer { Text(chat.sessionId, fontFamily = FontFamily.Monospace) }
            chat.session?.let { Text(it.status.name.lowercase()) }
            chat.session?.task?.let { Text(it.status); it.executionStep?.let { s -> Text(s) }; it.outputBranch?.let { b -> Text(b) } }
        }
        state.workspace?.let { w -> ToolGlass {
            Text(stringResource(R.string.infrastructure), style = MaterialTheme.typography.titleSmall)
            Text(w.name); Text(w.status); Text(w.branch)
            w.vmLocation?.let { Text(it) }
            state.node?.let { n ->
                Text(stringResource(R.string.vm_info, n.name, n.status))
                n.healthStatus?.let { Text(it) }; n.cloudProvider?.let { Text(it) }
                n.providerInstanceVcpuCount?.let { Text(stringResource(R.string.vm_cpu, it.toString())) }
                n.providerInstanceMemoryMb?.let { Text(stringResource(R.string.vm_memory, it.toString())) }
            }
        } }
        ToolGlass {
            Text(stringResource(R.string.provider_usage), style = MaterialTheme.typography.titleSmall)
            if (state.limits.isEmpty()) Text(stringResource(R.string.no_provider_limits))
            state.limits.forEach { limit ->
                Text("${limit.provider} · ${limit.windowType}", style = MaterialTheme.typography.labelLarge)
                if (limit.resetElapsed) Text(stringResource(R.string.provider_awaiting)) else {
                    limit.remainingAmount?.let { Text(stringResource(R.string.provider_remaining, it.toString())) }
                    limit.limitAmount?.let { Text(stringResource(R.string.provider_limit, it.toString())) }
                    limit.utilizationPercent?.let {
                        LinearProgressIndicator(progress = { (it / 100).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(stringResource(R.string.provider_used, it.toString()), style = MaterialTheme.typography.labelSmall)
                    }
                }
                Text(stringResource(R.string.provider_observed, DateFormat.getDateTimeInstance().format(Date(limit.observedAt))), style = MaterialTheme.typography.labelSmall)
                limit.resetsAt?.let { Text(stringResource(R.string.provider_resets, DateFormat.getDateTimeInstance().format(Date(it))), style = MaterialTheme.typography.labelSmall) }
            }
        }
    }
}
