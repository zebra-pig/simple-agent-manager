@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
package org.simpleagentmanager.app

import android.text.format.DateUtils
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.simpleagentmanager.core.*
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import org.simpleagentmanager.core.ChatContent as Content

/** Session tools with their own screens (formerly web hand-offs). */
sealed interface SessionSheet {
    data object Related : SessionSheet
    data object Automation : SessionSheet
    data object Comments : SessionSheet
    data object Share : SessionSheet
    data object Report : SessionSheet
    data class Derived(val kind: DerivedKind) : SessionSheet
    data class NewComment(val messageId: String) : SessionSheet
}

private fun now() = System.currentTimeMillis()
internal fun relative(millis: Long): String = DateUtils.getRelativeTimeSpanString(millis, now(), DateUtils.MINUTE_IN_MILLIS).toString()
private fun clock(millis: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(millis))

// MARK: Shared pieces

@Composable
internal fun ToolSheetHeader(title: String, loading: Boolean, onRefresh: (() -> Unit)?, onClose: () -> Unit, leading: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        leading?.invoke()
        Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f).padding(vertical = 10.dp))
        if (onRefresh != null) TextButton(onClick = onRefresh, enabled = !loading) { LoadingLabel(stringResource(R.string.tool_refresh), loading) }
        TextButton(onClick = onClose) { Text(stringResource(R.string.done)) }
    }
}

@Composable
internal fun Pill(text: String, tint: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(text, color = tint, style = MaterialTheme.typography.labelMedium,
        modifier = Modifier.background(tint.copy(alpha = .14f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 2.dp))
}

/** Grouped rows on a neutral surface, like the other tools. */
@Composable
internal fun ToolSection(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        if (title != null) Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerLow,
            border = BorderStroke(.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .5f))) {
            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), content = content)
        }
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
    }
}

@Composable
private fun Row2(title: String, detail: String? = null, modifier: Modifier = Modifier, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, maxLines = 3, overflow = TextOverflow.Ellipsis)
            if (!detail.isNullOrEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        trailing()
    }
}

@Composable
private fun EmptyNote(text: String) = Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp))

// MARK: Related

@Composable
internal fun RelatedContent(state: LinkedWorkState, onIdea: (LinkedIdea) -> Unit, onFile: (LinkedFile) -> Unit, onPullRequest: (LinkedPullRequest) -> Unit) {
    val work = state.work
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
        state.error?.let { item { ErrorRow(it.message()) } }
        if (work == null) {
            if (state.error != null) item { Column(Modifier.padding(16.dp)) { Text(stringResource(R.string.st_related_failed), style = MaterialTheme.typography.titleMedium); Text(stringResource(R.string.st_related_failed_detail)) } }
            return@LazyColumn
        }
        if (work.ideas.isEmpty() && work.files.isEmpty() && work.pullRequests.isEmpty()) item {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.st_nothing_related), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.st_nothing_related_detail), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (work.ideas.isNotEmpty()) item {
            ToolSection(count(stringResource(R.string.st_ideas), work.ideasTotal)) {
                work.ideas.forEach { idea -> Row2(idea.title, relations(idea.relations), Modifier.clickable { onIdea(idea) }) }
            }
        }
        if (work.files.isNotEmpty()) item {
            ToolSection(count(stringResource(R.string.st_files), work.filesTotal)) {
                work.files.forEach { file -> Row2(file.filename, listOf(relations(file.relations), file.directory).filter { it.isNotEmpty() }.joinToString(" · "), Modifier.clickable { onFile(file) }) }
            }
        }
        if (work.pullRequests.isNotEmpty()) item {
            ToolSection(count(stringResource(R.string.st_pull_requests), work.pullRequestsTotal)) {
                work.pullRequests.forEach { pr ->
                    Row2(pr.title ?: stringResource(R.string.st_pull_request_number, pr.number.toString()),
                        "#${pr.number}" + (pr.checks?.let { " · " + checks(it) } ?: ""), Modifier.clickable { onPullRequest(pr) }) {
                        pr.status?.let { Pill(prLabel(it), prTint(it)) }
                    }
                }
            }
        }
    }
}

private fun count(title: String, total: LinkedTotal) = "$title ${total.count}${if (total.lowerBound) "+" else ""}"

@Composable
private fun relations(list: List<LinkRelation>) = list.map {
    stringResource(when (it) {
        LinkRelation.WORKS_ON -> R.string.rel_works_on; LinkRelation.CREATED -> R.string.rel_created; LinkRelation.EDITED -> R.string.rel_edited
        LinkRelation.OPENED -> R.string.rel_opened; LinkRelation.UPLOADED -> R.string.rel_uploaded; LinkRelation.REPLACED -> R.string.rel_replaced
        LinkRelation.LINKED -> R.string.rel_linked; LinkRelation.RELATED -> R.string.rel_related; LinkRelation.DISCUSSES -> R.string.rel_discusses
        LinkRelation.READ -> R.string.rel_read; LinkRelation.VIEWED -> R.string.rel_viewed
    })
}.joinToString(" · ")

@Composable
private fun prLabel(s: PullRequestStatus) = stringResource(when (s) {
    PullRequestStatus.OPEN -> R.string.st_open; PullRequestStatus.DRAFT -> R.string.st_draft
    PullRequestStatus.MERGED -> R.string.st_merged; PullRequestStatus.CLOSED -> R.string.st_closed
})
@Composable
private fun prTint(s: PullRequestStatus) = when (s) {
    PullRequestStatus.OPEN -> Color(0xFF2E9A55); PullRequestStatus.MERGED -> Color(0xFF8A4FD0)
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
@Composable
private fun checks(c: ChecksStatus) = stringResource(when (c) {
    ChecksStatus.PENDING -> R.string.st_checks_pending; ChecksStatus.PASSED -> R.string.st_checks_passed; ChecksStatus.FAILING -> R.string.st_checks_failing
})

// MARK: Automation

@Composable
internal fun AutomationContent(state: AutomationState, sessionId: String, onStop: (ChatWait, String) -> Unit, onRemind: () -> Unit) {
    var showRelays by remember { mutableStateOf(false) }
    var stopping by remember { mutableStateOf<ChatWait?>(null) }
    var reason by remember { mutableStateOf("") }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
        listOfNotNull(state.error, state.waitsError, state.upcomingError).forEach { e -> item { ErrorRow(e.message()) } }
        if (state.canWrite) item {
            ToolSection { Row2(stringResource(R.string.st_remind_later), modifier = Modifier.clickable(onClick = onRemind)) }
        }
        item {
            val waits = state.waits + if (showRelays) state.relays else emptyList()
            ToolSection(stringResource(R.string.st_waiting_for), stringResource(R.string.st_waiting_hint)) {
                if (state.loaded && waits.isEmpty() && state.waitsError == null) EmptyNote(stringResource(R.string.st_not_waiting))
                waits.forEach { wait ->
                    Row2(waitTitle(wait, sessionId), waitSubtitle(wait) + if (wait.owner == WaitOwner.MANAGED) "\n" + stringResource(R.string.st_managed_wait) else "") {
                        if (wait.canStop) TextButton(onClick = { reason = ""; stopping = wait }) { Text(stringResource(R.string.st_stop_waiting), color = MaterialTheme.colorScheme.onSurface) }
                    }
                }
                if (state.relays.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.st_show_relays, state.relays.size), Modifier.weight(1f))
                    Switch(checked = showRelays, onCheckedChange = { showRelays = it })
                }
            }
        }
        item {
            ToolSection(stringResource(R.string.st_coming_up), if (state.upcomingTruncated) stringResource(R.string.st_upcoming_truncated) else null) {
                if (state.loaded && state.upcoming.isEmpty() && state.upcomingError == null) EmptyNote(stringResource(R.string.st_nothing_coming))
                state.upcoming.forEach { row ->
                    val detail = row.dueAt?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it)) }
                        ?: row.maxExecutions?.let { stringResource(R.string.st_runs_used, row.executions.toInt(), it.toInt()) }
                    Row2(upcomingTitle(row), detail, Modifier.alpha(if (row.status == UpcomingStatus.CANCELLED || row.status == UpcomingStatus.ENDED) .6f else 1f)) {
                        upcomingPill(row)?.let { Pill(it.first, it.second) }
                    }
                }
            }
        }
    }
    stopping?.let { wait ->
        AlertDialog(onDismissRequest = { stopping = null },
            title = { Text(stringResource(R.string.st_stop_waiting_title)) },
            text = { Column { Text(waitTitle(wait, sessionId)); OutlinedTextField(reason, { reason = it }, label = { Text(stringResource(R.string.st_why_optional)) }, singleLine = true, modifier = Modifier.padding(top = 12.dp)) } },
            confirmButton = { TextButton(onClick = { stopping = null; onStop(wait, reason) }) { Text(stringResource(R.string.st_stop_waiting)) } },
            dismissButton = { TextButton(onClick = { stopping = null }) { Text(stringResource(R.string.st_keep_waiting)) } })
    }
}

@Composable
private fun waitTitle(wait: ChatWait, sessionId: String): String {
    val what = eventWords(wait.event, wait.subject).first
    if (wait.targetSessionId == null || wait.targetSessionId == sessionId) return stringResource(R.string.st_this_chat_waits, what)
    val who = wait.ownerName ?: stringResource(if (wait.owner == WaitOwner.AGENT) R.string.st_an_agent else R.string.st_someone)
    return stringResource(R.string.st_someone_waits, who, what)
}

@Composable
private fun waitSubtitle(wait: ChatWait): String {
    val parts = mutableListOf(stringResource(R.string.st_since, relative(wait.createdAt)))
    // Mid-sentence: "gives up in 5 hours", not "In 5 hours".
    wait.expiresAt?.let { parts += if (it > now()) stringResource(R.string.st_gives_up, relative(it).replaceFirstChar(Char::lowercase)) else stringResource(R.string.st_past_end) }
    wait.lastMatchedAt?.let { parts += stringResource(R.string.st_last_matched, relative(it).replaceFirstChar(Char::lowercase)) }
    return parts.joinToString(" · ")
}

@Composable
private fun upcomingTitle(row: UpcomingAutomation): String {
    row.title?.let { return it }
    val event = row.event
    if (row.kind == UpcomingKind.WATCH && event != null) return stringResource(R.string.st_when, eventWords(event, row.subject).second)
    return stringResource(if (row.messagesThisChat) R.string.st_message_a_chat else R.string.st_start_a_chat)
}

@Composable
private fun upcomingPill(row: UpcomingAutomation): Pair<String, Color>? {
    val attention = stringResource(R.string.st_check) to Color(0xFFE08A1E)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    return when (row.status) {
        UpcomingStatus.SCHEDULED, UpcomingStatus.ON, UpcomingStatus.DONE, UpcomingStatus.ENDED -> if (row.needsAttention) attention else null
        UpcomingStatus.LATE -> stringResource(R.string.st_waiting_to_start) to Color(0xFFE08A1E)
        UpcomingStatus.STARTING -> stringResource(R.string.st_starting) to muted
        UpcomingStatus.CANCELLED -> stringResource(R.string.st_cancelled) to muted
        UpcomingStatus.PAUSED -> if (row.needsAttention) attention else stringResource(R.string.st_paused) to muted
    }
}

/** "Remind this chat later": one message to this chat at a chosen time. */
@Composable
internal fun ReminderDialog(busy: Boolean, onDismiss: () -> Unit, onSave: (prompt: String, dueAt: Long) -> Unit) {
    var prompt by remember { mutableStateOf("") }
    val date = rememberDatePickerState(initialSelectedDateMillis = now() + 3_600_000)
    val start = java.util.Calendar.getInstance().apply { timeInMillis = now() + 3_600_000 }
    val time = rememberTimePickerState(start.get(java.util.Calendar.HOUR_OF_DAY), start.get(java.util.Calendar.MINUTE))
    var picking by remember { mutableStateOf(false) }
    fun due(): Long {
        val day = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply { timeInMillis = date.selectedDateMillis ?: now() }
        return java.util.Calendar.getInstance().apply {
            set(day.get(java.util.Calendar.YEAR), day.get(java.util.Calendar.MONTH), day.get(java.util.Calendar.DAY_OF_MONTH), time.hour, time.minute, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }.timeInMillis
    }
    if (picking) DatePickerDialog(onDismissRequest = { picking = false }, confirmButton = { TextButton(onClick = { picking = false }) { Text(stringResource(R.string.done)) } }) { DatePicker(date) }
    else AlertDialog(onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.st_remind_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(prompt, { prompt = it }, label = { Text(stringResource(R.string.st_remind_prompt)) }, minLines = 2, modifier = Modifier.fillMaxWidth())
                Text(stringResource(R.string.st_remind_hint), style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = { picking = true }) { Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(due()))) }
                TimeInput(time)
            }
        },
        confirmButton = { TextButton(onClick = { onSave(prompt, due()) }, enabled = prompt.isNotBlank() && !busy && due() > now()) { LoadingLabel(stringResource(R.string.st_save), busy) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}

// Web's describeEventFilter words.
private val eventPhrases = mapOf(
    "issues.opened" to (R.string.ev_issues_opened to R.string.ev_issues_opened_c), "issues.labeled" to (R.string.ev_issues_labeled to R.string.ev_issues_labeled_c),
    "issues.closed" to (R.string.ev_issues_closed to R.string.ev_issues_closed_c), "issue_comment.created" to (R.string.ev_issue_comment to R.string.ev_issue_comment_c),
    "pull_request.opened" to (R.string.ev_pr_opened to R.string.ev_pr_opened_c), "pull_request.closed" to (R.string.ev_pr_closed to R.string.ev_pr_closed_c),
    "pull_request.synchronize" to (R.string.ev_pr_sync to R.string.ev_pr_sync_c), "pull_request.review_requested" to (R.string.ev_pr_review_req to R.string.ev_pr_review_req_c),
    "pull_request_review.submitted" to (R.string.ev_pr_review to R.string.ev_pr_review_c), "pull_request_review_comment.created" to (R.string.ev_pr_review_comment to R.string.ev_pr_review_comment_c),
    "push" to (R.string.ev_push to R.string.ev_push_c), "check_run.completed" to (R.string.ev_ci to R.string.ev_ci_clause), "check_suite.completed" to (R.string.ev_ci to R.string.ev_ci_clause),
    "workflow_run.completed" to (R.string.ev_workflow to R.string.ev_workflow_c), "task.started" to (R.string.ev_task_started to R.string.ev_task_started_c),
    "task.completed" to (R.string.ev_task_completed to R.string.ev_task_completed_c), "task.failed" to (R.string.ev_task_failed to R.string.ev_task_failed_c),
    "task.cancelled" to (R.string.ev_task_cancelled to R.string.ev_task_cancelled_c), "session.failed" to (R.string.ev_session_failed to R.string.ev_session_failed_c),
    "session.archived" to (R.string.ev_session_archived to R.string.ev_session_archived_c), "deployment.release.applied" to (R.string.ev_release_applied to R.string.ev_release_applied_c),
    "deployment.release.failed" to (R.string.ev_release_failed to R.string.ev_release_failed_c), "webhook.accepted" to (R.string.ev_webhook to R.string.ev_webhook_c),
    "webhook.filtered" to (R.string.ev_webhook_filtered to R.string.ev_webhook_filtered_c),
)

@Composable
private fun subjectSuffix(subject: WaitSubject?): String {
    subject ?: return ""
    return when (subject.kind) {
        "commit" -> stringResource(R.string.ev_on_commit, subject.id.take(7))
        "pull_request" -> stringResource(R.string.ev_on_pr, subject.id)
        "issue" -> stringResource(R.string.ev_on_issue, subject.id)
        "task" -> stringResource(R.string.ev_for_task, subject.id.take(8))
        "session" -> stringResource(R.string.ev_for_chat, subject.id.take(8))
        else -> " ${subject.kind.replace('_', ' ')} ${subject.id.take(12)}"
    }
}

/** (noun, clause) for a filter, as web words it. */
@Composable
internal fun eventWords(event: WaitEvent, subject: WaitSubject?): Pair<String, String> {
    val suffix = subjectSuffix(subject)
    return when (event) {
        is WaitEvent.Channel -> {
            val names = event.names.map { "#$it" }
            val where = when {
                names.isEmpty() -> stringResource(R.string.ev_any_channel)
                names.size == 1 -> names[0]
                else -> stringResource(R.string.ev_or, names.dropLast(1).joinToString(", "), names.last())
            }
            stringResource(R.string.ev_post_on, where) to stringResource(R.string.ev_post_on_clause, where)
        }
        is WaitEvent.Ci -> stringResource(R.string.ev_ci) + suffix to stringResource(R.string.ev_ci_clause) + suffix
        is WaitEvent.Known -> eventPhrases[event.eventType]?.let { stringResource(it.first) + suffix to stringResource(it.second) + suffix }
            ?: eventWords(WaitEvent.Named(null, event.eventType), subject)
        is WaitEvent.Named -> {
            val words = event.eventType.replace('.', ' ').replace('_', ' ')
            val family = when (event.source) { "github" -> "GitHub "; "sam.lifecycle" -> "SAM "; null -> ""; else -> "${event.source} " }
            val noun = stringResource(R.string.ev_named, family, words)
            noun + suffix to stringResource(R.string.ev_named_clause, noun) + suffix
        }
        is WaitEvent.Family -> {
            val family = when (event.source) { "github" -> stringResource(R.string.ev_github_activity); "sam.lifecycle" -> stringResource(R.string.ev_sam_activity); else -> null }
            if (suffix.isNotEmpty()) { val f = family ?: stringResource(R.string.ev_an_event); f + suffix to stringResource(R.string.ev_there_is, f) + suffix }
            else (family?.let { stringResource(R.string.ev_matching, it) } ?: stringResource(R.string.ev_matching_events)) to stringResource(R.string.ev_matching_clause)
        }
    }
}

// MARK: Comments

@Composable
internal fun CommentsContent(state: CommentsState, chat: ChatState, onOpen: (CommentThread) -> Unit) {
    var filter by remember(state.sessionId) { mutableStateOf<CommentBucket?>(null) }
    var chose by remember(state.sessionId) { mutableStateOf(false) }
    LaunchedEffect(state.loaded, state.counts.needsYou) { if (!chose && state.loaded) filter = if (state.counts.needsYou > 0u) CommentBucket.NEEDS_YOU else null }
    val shown = state.threads.filter { filter == null || it.bucket == filter }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
        state.error?.let { item { ErrorRow(it.message()) } }
        if (state.counts.all > 0u) item {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(null to (R.string.st_all to state.counts.all), CommentBucket.NEEDS_YOU to (R.string.st_needs_you to state.counts.needsYou),
                    CommentBucket.WITH_AGENT to (R.string.st_with_agent to state.counts.withAgent), CommentBucket.OPEN to (R.string.st_open to state.counts.open),
                    CommentBucket.RESOLVED to (R.string.st_resolved to state.counts.resolved)).forEach { (bucket, label) ->
                    FilterChip(selected = filter == bucket, onClick = { chose = true; filter = bucket },
                        label = { Text("${stringResource(label.first)} ${label.second}") }, modifier = Modifier.alpha(if (label.second == 0u && filter != bucket) .5f else 1f))
                }
            }
        }
        if (state.loaded && state.threads.isEmpty()) item {
            Column(Modifier.padding(16.dp)) { Text(stringResource(R.string.st_no_comments), style = MaterialTheme.typography.titleMedium); Text(stringResource(R.string.st_no_comments_detail), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        } else if (state.loaded && shown.isEmpty()) item {
            Column(Modifier.padding(16.dp)) {
                Text(stringResource(if (filter == CommentBucket.NEEDS_YOU) R.string.st_caught_up else R.string.st_nothing_here), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.st_switch_filters, state.counts.all.toInt()), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (shown.isNotEmpty()) item {
            ToolSection(footer = if (state.hasMore) stringResource(R.string.st_more_comments) else null) {
                shown.forEach { thread ->
                    Column(Modifier.fillMaxWidth().clickable { onOpen(thread) }.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row {
                            Text(thread.quote?.let { "“$it”" } ?: anchorLabel(thread.messageId, chat), Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(relative(thread.lastActivityAt), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(thread.body, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(lastActor(thread), Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Pill(bucketLabel(thread.bucket), bucketTint(thread.bucket))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun CommentThreadContent(
    thread: CommentThread?, state: CommentsState, chat: ChatState,
    onReply: (body: String, send: Boolean, done: () -> Unit) -> Unit, onSend: () -> Unit, onResolve: () -> Unit, onReopen: () -> Unit,
) {
    if (thread == null) { EmptyNote(stringResource(R.string.st_comment_unavailable)); return }
    var reply by remember(thread.id) { mutableStateOf("") }
    var send by remember(thread.id) { mutableStateOf(false) }
    Column {
        LazyColumn(Modifier.weight(1f, fill = false), contentPadding = PaddingValues(bottom = 12.dp)) {
            state.error?.let { item { ErrorRow(it.message()) } }
            item {
                ToolSection(anchorLabel(thread.messageId, chat)) {
                    thread.quote?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    Text(excerpt(thread.messageId, chat), Modifier.padding(horizontal = 16.dp, vertical = 6.dp), maxLines = 4, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item {
                ToolSection(stringResource(R.string.st_thread) + " · " + statusLabel(thread.status)) {
                    Bubble(thread.author, thread.body, thread.createdAt, false)
                    thread.replies.forEach { Bubble(it.author, it.body, it.createdAt, it.sentToAgent) }
                }
            }
            if (state.canComment) item {
                ToolSection {
                    if (thread.status == CommentStatus.OPEN && state.canSendToAgent) Row2(stringResource(R.string.st_send_to_agent), modifier = Modifier.clickable(enabled = !state.saving, onClick = onSend))
                    Row2(stringResource(if (thread.status == CommentStatus.RESOLVED) R.string.st_reopen else R.string.st_resolve),
                        modifier = Modifier.clickable(enabled = !state.saving) { if (thread.status == CommentStatus.RESOLVED) onReopen() else onResolve() })
                }
            }
        }
        if (state.canComment) CommentComposer(reply, { reply = it }, send, { send = it }, stringResource(R.string.st_reply_hint), state.canSendToAgent, state.saving,
            stringResource(if (send) R.string.st_reply_send else R.string.st_reply)) { onReply(reply, send) { reply = ""; send = false } }
    }
}

@Composable
private fun Bubble(author: CommentAuthor, body: String, time: Long, sentToAgent: Boolean) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(authorName(author), fontWeight = FontWeight.SemiBold)
            Text(relative(time), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            if (sentToAgent) Pill(stringResource(R.string.st_sent_to_agent))
        }
        SelectionContainer { Text(body) }
    }
}

/** The composer shared by new comments and replies. */
@Composable
internal fun CommentComposer(text: String, onText: (String) -> Unit, send: Boolean, onSendChange: (Boolean) -> Unit, placeholder: String, canSend: Boolean, saving: Boolean, submit: String, onSubmit: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(vertical = 8.dp), shape = RoundedCornerShape(22.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .9f),
        border = BorderStroke(.5.dp, MaterialTheme.colorScheme.outlineVariant), shadowElevation = 3.dp) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TextField(text, onText, placeholder = { Text(placeholder) }, modifier = Modifier.fillMaxWidth(), minLines = 2, maxLines = 8,
                colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (canSend) SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                    SegmentedButton(selected = !send, onClick = { onSendChange(false) }, shape = SegmentedButtonDefaults.itemShape(0, 2)) { Text(stringResource(R.string.st_add_note), maxLines = 1) }
                    SegmentedButton(selected = send, onClick = { onSendChange(true) }, shape = SegmentedButtonDefaults.itemShape(1, 2)) { Text(stringResource(R.string.st_send_to_agent), maxLines = 1) }
                } else Text(stringResource(R.string.st_reader_hint), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(8.dp))
                OutlinedButton(onClick = onSubmit, enabled = text.isNotBlank() && !saving) { LoadingLabel(submit, saving) }
            }
        }
    }
}

@Composable
internal fun NewCommentContent(messageId: String, state: CommentsState, chat: ChatState, onCreate: (body: String, send: Boolean) -> Unit) {
    var text by remember(messageId) { mutableStateOf("") }
    var send by remember(messageId) { mutableStateOf(false) }
    Column {
        state.error?.let { ErrorRow(it.message()) }
        ToolSection(anchorLabel(messageId, chat), if (state.canSendToAgent && send) stringResource(R.string.st_send_hint) else null) {
            Text(excerpt(messageId, chat), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), maxLines = 6, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (state.loaded && !state.canComment) EmptyNote(stringResource(R.string.st_cannot_comment))
        else CommentComposer(text, { text = it }, send, { send = it }, stringResource(R.string.st_add_comment), state.canSendToAgent, state.saving || !state.loaded,
            stringResource(if (send) R.string.st_comment_send else R.string.st_comment)) { onCreate(text, send) }
    }
}

@Composable
private fun anchorLabel(messageId: String, chat: ChatState) = stringResource(
    when (chat.items.firstOrNull { it.id == messageId }?.content) { is Content.Agent, is Content.Thinking, is Content.Activity -> R.string.st_on_agent_reply; else -> R.string.st_on_message })

@Composable
private fun excerpt(messageId: String, chat: ChatState): String = when (val c = chat.items.firstOrNull { it.id == messageId }?.content) {
    null -> stringResource(R.string.st_earlier_message)
    is Content.User -> c.text
    is Content.Agent -> c.text
    is Content.Thinking -> c.text
    else -> stringResource(R.string.st_agent_activity)
}

@Composable
private fun authorName(a: CommentAuthor) = if (a.isViewer) stringResource(R.string.st_you) else a.name ?: stringResource(if (a.isAgent) R.string.st_agent else R.string.st_someone)

@Composable
private fun lastActor(t: CommentThread): String {
    val actor = t.replies.lastOrNull()?.author ?: t.author
    val replied = t.replies.isNotEmpty()
    if (actor.isViewer) return stringResource(if (replied) R.string.st_you_replied else R.string.st_you_commented)
    return stringResource(if (replied) R.string.st_x_replied else R.string.st_x_commented, authorName(actor))
}

@Composable
private fun bucketLabel(b: CommentBucket) = stringResource(when (b) {
    CommentBucket.NEEDS_YOU -> R.string.st_needs_you; CommentBucket.WITH_AGENT -> R.string.st_with_agent
    CommentBucket.OPEN -> R.string.st_open; CommentBucket.RESOLVED -> R.string.st_resolved
})
@Composable
private fun bucketTint(b: CommentBucket) = when (b) {
    CommentBucket.NEEDS_YOU -> Color(0xFFE08A1E); CommentBucket.WITH_AGENT -> Color(0xFF3D7BD9)
    CommentBucket.OPEN -> MaterialTheme.colorScheme.onSurfaceVariant; CommentBucket.RESOLVED -> Color(0xFF2E9A55)
}
@Composable
private fun statusLabel(s: CommentStatus) = stringResource(when (s) {
    CommentStatus.OPEN -> R.string.st_open; CommentStatus.SENT -> R.string.st_sent_to_agent; CommentStatus.RESOLVED -> R.string.st_resolved
})

// MARK: Share

@Composable
private fun ownerPossessive(owner: AccessPerson?) = if (owner == null || owner.isViewer) stringResource(R.string.st_your) else stringResource(R.string.st_possessive, personName(owner))
@Composable
private fun ownerObject(owner: AccessPerson?) = if (owner == null || owner.isViewer) stringResource(R.string.st_you_lower) else personName(owner)
@Composable
private fun ownerFirstPerson(owner: AccessPerson?) = if (owner == null || owner.isViewer) stringResource(R.string.st_my) else stringResource(R.string.st_possessive, personName(owner))
@Composable
private fun personName(p: AccessPerson) = p.name ?: stringResource(R.string.st_someone)

@Composable
internal fun ShareContent(state: SessionAccessState, onAdd: (ShareCandidate) -> Unit, onRenew: (AccessGrant) -> Unit, onRevoke: (AccessGrant) -> Unit) {
    var search by remember { mutableStateOf("") }
    var removing by remember { mutableStateOf<AccessGrant?>(null) }
    val candidates = state.candidates.filter { search.isBlank() || it.label.contains(search.trim(), true) || it.email?.contains(search.trim(), true) == true }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
        state.error?.let { item { ErrorRow(it.message()) } }
        state.outcome?.let { item { Text(outcomeText(it), Modifier.padding(8.dp), fontWeight = FontWeight.Medium) } }
        item {
            Text(stringResource(if (state.canManage) R.string.st_share_intro_manage else R.string.st_share_intro_view, ownerPossessive(state.owner)),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(4.dp))
        }
        item {
            ToolSection(stringResource(R.string.st_people_with_access)) {
                state.owner?.let { owner ->
                    Row2(if (owner.isViewer) stringResource(R.string.st_you_suffix, personName(owner)) else personName(owner)) { Pill(stringResource(R.string.st_owner)) }
                }
                state.grants.forEach { grant ->
                    val by = if (grant.grantedBy.isViewer) stringResource(R.string.st_you_lower) else grant.grantedBy.name ?: stringResource(R.string.st_someone_lower)
                    val ends = grant.expiresAt - state.serverOffsetMs
                    val minutes = ((ends - now()) / 60_000).toInt()
                    val left = if (minutes < 1) stringResource(R.string.st_under_minute) else stringResource(R.string.st_minutes, minutes)
                    Row2(if (grant.grantee.isViewer) stringResource(R.string.st_you_suffix, personName(grant.grantee)) else personName(grant.grantee),
                        stringResource(R.string.st_added_by, by, left, clock(ends))) {
                        if (state.canRenew && !grant.grantee.isViewer) TextButton(onClick = { onRenew(grant) }) { Text(stringResource(R.string.st_renew), color = MaterialTheme.colorScheme.onSurface) }
                        if (grant.grantee.isViewer || state.canManage) TextButton(onClick = { removing = grant }) {
                            Text(stringResource(if (grant.grantee.isViewer) R.string.st_leave else R.string.st_revoke_now), color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                if (state.loaded && state.grants.isEmpty()) EmptyNote(stringResource(R.string.st_only_owner))
            }
        }
        if (state.loaded && state.canManage) item {
            ToolSection(stringResource(R.string.st_add_teammate)) {
                val none = state.noCandidates
                when {
                    !state.canAdd -> EmptyNote(stringResource(R.string.st_chat_ended))
                    none != null -> EmptyNote(stringResource(when (none) { NoCandidates.NOBODY_ELSE -> R.string.st_nobody_else; NoCandidates.ONLY_VIEWERS -> R.string.st_only_viewers; NoCandidates.EVERYONE_HAS_ACCESS -> R.string.st_everyone_has_access }))
                    else -> {
                        if (state.candidates.size > 6) OutlinedTextField(search, { search = it }, label = { Text(stringResource(R.string.st_search_teammates)) }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp))
                        candidates.forEach { person -> Row2(person.label, person.email?.takeIf { it != person.label }, Modifier.clickable { onAdd(person) }) }
                    }
                }
            }
        }
    }
    removing?.let { grant ->
        val cascades = state.grants.any { it.id != grant.id && it.grantedBy.id == grant.grantee.id }
        AlertDialog(onDismissRequest = { removing = null },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(if (grant.grantee.isViewer) stringResource(R.string.st_leave_confirm) else stringResource(R.string.st_revoke_confirm, personName(grant.grantee)))
                    Text((if (!cascades) "" else stringResource(if (grant.grantee.isViewer) R.string.st_cascade_you else R.string.st_cascade_they)) + stringResource(R.string.st_work_keeps_running), style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = { TextButton(onClick = { removing = null; onRevoke(grant) }) { Text(stringResource(if (grant.grantee.isViewer) R.string.st_leave else R.string.st_revoke_now), color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } })
    }
}

/** Picking how long, and acknowledging that it runs on the owner's accounts. */
@Composable
/** `durations` and `endsAt` come from the core (`share_durations`, `share_ends_at`). */
internal fun ShareConfirmContent(state: SessionAccessState, name: String, renewing: Boolean, durations: List<UInt>, endsAt: (UInt) -> Long, onConfirm: (minutes: UInt) -> Unit) {
    var minutes by remember(name) { mutableStateOf<UInt?>(null) }
    var understood by remember(name) { mutableStateOf(false) }
    val owner = state.owner
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
        item { Text(stringResource(if (renewing) R.string.st_renew_access else R.string.st_share_with, name), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(4.dp)) }
        item {
            ToolSection {
                listOf(stringResource(R.string.st_warn_1, name), stringResource(R.string.st_warn_2), stringResource(R.string.st_warn_3, ownerPossessive(owner), ownerObject(owner)),
                    stringResource(R.string.st_warn_4, ownerPossessive(owner), name), stringResource(R.string.st_warn_5, name)).forEach {
                    Text("•  $it", Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        item {
            val footer = minutes?.let {
                val end = endsAt(it)
                stringResource(if (end < now() + it.toLong() * 60_000) R.string.st_ends_at_capped else R.string.st_ends_at, clock(end))
            }
            ToolSection(stringResource(R.string.st_how_long), footer) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(12.dp)) {
                    durations.forEachIndexed { i, value ->
                        SegmentedButton(selected = minutes == value, onClick = { minutes = value }, shape = SegmentedButtonDefaults.itemShape(i, durations.size)) {
                            Text(if (value == 60u) stringResource(R.string.st_one_hour) else stringResource(R.string.st_minutes, value.toInt()), maxLines = 1)
                        }
                    }
                }
            }
        }
        item {
            ToolSection {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.st_understand, ownerFirstPerson(owner)), Modifier.weight(1f))
                    Switch(checked = understood, onCheckedChange = { understood = it })
                }
            }
        }
        item {
            Button(onClick = { minutes?.let(onConfirm) }, enabled = minutes != null && understood && !state.saving, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                LoadingLabel(stringResource(if (renewing) R.string.st_renew else R.string.st_share), state.saving)
            }
        }
    }
}

@Composable
private fun outcomeText(o: ShareOutcome): String {
    @Composable fun extras(cascaded: UInt, cancelled: UInt, you: Boolean) = buildList {
        if (cascaded > 0u) {
            val people = if (cascaded == 1u) stringResource(R.string.st_one_person) else stringResource(R.string.st_people, cascaded.toInt())
            add(stringResource(if (you) R.string.st_also_removed_you else R.string.st_also_removed_they, people))
        }
        if (cancelled > 0u) {
            val messages = if (cancelled == 1u) stringResource(R.string.st_one_message) else stringResource(R.string.st_messages, cancelled.toInt())
            add(stringResource(R.string.st_cancelled_messages, messages))
        }
    }
    return when (o) {
        is ShareOutcome.Granted -> stringResource(R.string.st_granted, o.name, clock(o.until))
        is ShareOutcome.Renewed -> stringResource(R.string.st_renewed, o.name, clock(o.until))
        is ShareOutcome.AlreadyShared -> stringResource(R.string.st_already_shared, o.name, clock(o.until))
        is ShareOutcome.Revoked -> (listOf(stringResource(R.string.st_revoked, o.name)) + extras(o.cascaded, o.cancelledMessages, false)).joinToString(" ")
        is ShareOutcome.Left -> (listOf(stringResource(R.string.st_left)) + extras(o.cascaded, o.cancelledMessages, true)).joinToString(" ")
    }
}

// MARK: Retry / Fork

@Composable
internal fun DerivedBanner(kind: DerivedKind, derived: DerivedTask?) {
    ToolSection {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val label = derived?.parentLabel.orEmpty()
            Text(stringResource(if (kind == DerivedKind.RETRY) R.string.st_retrying else R.string.st_forking, label), style = MaterialTheme.typography.titleMedium)
            derived?.parentBranch?.let { Text(stringResource(R.string.st_branch, it), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            derived?.errorMessage?.let { Text(stringResource(R.string.st_error, it), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 4) }
            if (derived?.promptLoading == true) Text(stringResource(R.string.st_loading_prompt), style = MaterialTheme.typography.labelMedium)
            if (derived?.promptError != null) Text(stringResource(R.string.st_prompt_failed), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelMedium)
            Text(stringResource(if (kind == DerivedKind.RETRY) R.string.st_retry_explain else R.string.st_fork_explain), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
        }
    }
}

// MARK: Report

@Composable
/** `present`: the non-empty reference keys (`report_refs_present`). */
internal fun ReportContent(state: ReportState, refs: ReportRefs, present: List<String>, onSubmit: (title: String, details: String, attach: Boolean) -> Unit) {
    var title by remember { mutableStateOf("") }
    var details by remember { mutableStateOf("") }
    var attach by remember { mutableStateOf(false) }
    val done = state.submitted
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        state.error?.let { item { ErrorRow(it.message()) } }
        if (done != null) item {
            ToolSection {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(R.string.st_report_submitted), style = MaterialTheme.typography.titleMedium)
                    if (done.message.isNotEmpty()) Text(done.message)
                    SelectionContainer { Text(stringResource(R.string.st_report_id, done.id)) }
                    Text(stringResource(R.string.st_report_status, humanize(done.status)))
                    if (done.attached.isNotEmpty()) Text(stringResource(R.string.st_refs_attached, done.attached.map { refLabel(it) }.joinToString(", ")))
                }
            }
        } else {
            item { Text(stringResource(R.string.st_report_intro), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(4.dp)) }
            item { OutlinedTextField(title, { if (it.length <= 200) title = it }, label = { Text(stringResource(R.string.st_report_summary)) }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
            item { OutlinedTextField(details, { if (it.length <= 5000) details = it }, label = { Text(stringResource(R.string.st_report_details)) }, minLines = 4, modifier = Modifier.fillMaxWidth()) }
            if (present.isNotEmpty()) item {
                ToolSection {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.st_attach_refs), Modifier.weight(1f))
                        Switch(checked = attach, onCheckedChange = { attach = it })
                    }
                    if (attach) present.forEach { key ->
                        Row2(refLabel(key)) { Text(refValue(key, refs), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelMedium) }
                    }
                }
            }
            item {
                Button(onClick = { onSubmit(title, details, attach) }, enabled = title.isNotBlank() && details.isNotBlank() && !state.submitting, modifier = Modifier.fillMaxWidth()) {
                    LoadingLabel(stringResource(R.string.st_submit), state.submitting)
                }
            }
        }
    }
}

@Composable
private fun refLabel(key: String) = when (key) {
    "sessionId" -> stringResource(R.string.ref_session); "taskId" -> stringResource(R.string.ref_task); "nodeId" -> stringResource(R.string.ref_node)
    "errorId" -> stringResource(R.string.ref_error); "diagnosisId" -> stringResource(R.string.ref_diagnosis); else -> key
}
private fun refValue(key: String, refs: ReportRefs) = when (key) { "sessionId" -> refs.sessionId; "taskId" -> refs.taskId; "nodeId" -> refs.nodeId; else -> null }.orEmpty()

/** Web takes new comments on user and agent messages, not notices or tool activity. */
internal fun commentable(item: ChatItem) = item.content is Content.User || item.content is Content.Agent
