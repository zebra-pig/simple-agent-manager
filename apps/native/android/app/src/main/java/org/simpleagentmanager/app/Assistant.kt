@file:OptIn(ExperimentalMaterial3Api::class)
package org.simpleagentmanager.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.simpleagentmanager.core.*
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Account-scoped, encrypted receipts; commit synchronously before a turn is submitted. */
private class AssistantPersistence(context: Context) : AssistantStore {
    private val prefs = context.getSharedPreferences("assistant-retry", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("sam-assistant", null) as SecretKey?)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("sam-assistant", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    override fun load(scope: String): AssistantPending? = runCatching {
        val blob = Base64.decode(prefs.getString(scope, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, 12))
        val json = JSONObject(String(cipher.doFinal(blob, 12, blob.size - 12)))
        AssistantPending(json.getString("requestKey"), json.getString("message"))
    }.getOrNull()
    override fun save(scope: String, pending: AssistantPending): Boolean = runCatching {
        val json = JSONObject().put("requestKey", pending.requestKey).put("message", pending.message)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        prefs.edit().putString(scope, Base64.encodeToString(cipher.iv + cipher.doFinal(json.toString().toByteArray()), Base64.NO_WRAP)).commit()
    }.getOrDefault(false)
    override fun clear(scope: String) { prefs.edit().remove(scope).commit() }
}

@Composable
fun AssistantScreen(app: App, openUrl: (String) -> Unit, openChat: (String, String) -> Unit) {
    val context = LocalContext.current
    val vm = remember(app) { AssistantViewModel(app, AssistantPersistence(context.applicationContext)) }
    val snapshot = remember(vm) { mutableStateOf(vm.state()) }
    val state by snapshot
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var draft by rememberSaveable { mutableStateOf("") }
    var voiceBusy by remember { mutableStateOf(false) }
    val active = state.turns.any { it.state == "running" || it.state == "accepted" }
    DisposableEffect(vm) {
        vm.setObserver(object : AssistantObserver {
            override fun onStateChanged(state: AssistantState) { scope.launch { snapshot.value = state } }
        })
        onDispose { vm.clearObserver(); vm.close() }
    }
    LaunchedEffect(vm, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { vm.refresh(); delay(if (state.turns.any { it.state == "running" || it.state == "accepted" }) 2_000 else 10_000) }
        }
    }
    fun open(link: String) {
        val parts = link.split('/').filter { it.isNotEmpty() }
        if (link.startsWith("/projects/") && parts.size == 4 && parts[2] == "chat") {
            openChat(android.net.Uri.decode(parts[1]), android.net.Uri.decode(parts[3]))
        } else notificationUrl(app.state().serverUrl, link)?.let(openUrl)
    }
    AssistantContent(state, draft, onDraft = { draft = it }, voiceBusy = voiceBusy, open = ::open, openChat = openChat,
        onRefresh = { scope.launch { vm.refresh() } }, onStop = { scope.launch { vm.stop() } },
        onSend = { scope.launch { vm.send(draft, UUID.randomUUID().toString()); if (vm.state().pending == null) draft = "" } },
        onSeen = { scope.launch { vm.markSeen(it) } }, onEarlier = { scope.launch { vm.loadEarlier() } },
        onOlder = { scope.launch { vm.loadOlder() } }, onConfirm = { id, approved -> scope.launch { vm.confirm(id, approved) } },
        onReconcile = { scope.launch { vm.reconcile(it) } },
        voice = { AssistantVoiceButton(vm, enabled = !state.busy && state.pending == null && !active,
            onText = { draft += (if (draft.isBlank()) "" else " ") + it }, onBusy = { voiceBusy = it }) })
}

/** Pure screen, also used by host-rendered phone and tablet previews. */
@Composable
internal fun AssistantContent(
    state: AssistantState, draft: String, onDraft: (String) -> Unit,
    voiceBusy: Boolean = false, open: (String) -> Unit = {}, openChat: (String, String) -> Unit = { _, _ -> },
    onRefresh: () -> Unit = {}, onStop: () -> Unit = {}, onSend: () -> Unit = {}, onSeen: (String) -> Unit = {},
    onEarlier: () -> Unit = {}, onOlder: () -> Unit = {}, onConfirm: (String, Boolean) -> Unit = { _, _ -> },
    onReconcile: (String) -> Unit = {}, voice: @Composable () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val active = state.turns.any { it.state == "running" || it.state == "accepted" }
    Scaffold(topBar = {
        TopAppBar(title = { Text("SAM") }, actions = {
            IconButton(onClick = { open("/settings") }) { Icon(Icons.Default.Settings, stringResource(R.string.assistant_settings)) }
        })
    }, bottomBar = {
        Surface(tonalElevation = 3.dp) {
            Column(Modifier.fillMaxWidth().imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.error?.let { error ->
                    Text(error.message(), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onRefresh, enabled = !state.loading) { Text(stringResource(R.string.refresh_request)) }
                }
                state.pending?.let { Text(it.message, style = MaterialTheme.typography.bodySmall, maxLines = 4) }
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    voice()
                    OutlinedTextField(value = draft, onValueChange = onDraft, placeholder = { Text(stringResource(R.string.ask_sam)) },
                        modifier = Modifier.weight(1f), maxLines = 6, enabled = state.pending == null && !state.busy)
                    if (active) OutlinedButton(onClick = onStop, enabled = !state.busy) { Text(stringResource(R.string.stop_sam)) }
                    else Button(onClick = onSend, enabled = !state.busy && !voiceBusy && state.enabled && state.loaded && (state.error == null || state.pending != null) && (draft.isNotBlank() || state.pending != null)) {
                        Text(stringResource(if (state.pending != null) R.string.retry else R.string.send))
                    }
                }
                if (active) Text(stringResource(R.string.stop_sam_hint), style = MaterialTheme.typography.bodySmall)
            }
        }
    }) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            LazyColumn(state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item { Text(stringResource(R.string.sam_private), style = MaterialTheme.typography.bodySmall) }
                if (state.work.isNotEmpty()) item {
                    AssistantDisclosure(stringResource(R.string.project_work)) {
                        state.work.forEach { work ->
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(work.taskTitle ?: stringResource(R.string.untitled_task), style = MaterialTheme.typography.titleMedium)
                                work.projectName?.let { Text(it) }
                                Text(work.status.replace('_', ' '))
                                if (work.attention) Text(stringResource(R.string.needs_attention))
                                work.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                                TextButton(onClick = {
                                    work.sessionId?.let { openChat(work.projectId, it) }
                                        ?: open("/projects/${work.projectId}/tasks/${work.taskId}")
                                }) { Text(stringResource(if (work.sessionId != null) R.string.open_conversation else R.string.open_on_web)) }
                                if ((work.updates?.unread ?: 0u) > 0u) {
                                    Text(stringResource(R.string.sam_new_updates, work.updates!!.unread.toInt()))
                                    TextButton(onClick = { onSeen(work.actionId) }, enabled = !state.busy) { Text(stringResource(R.string.mark_seen)) }
                                }
                            }
                            HorizontalDivider()
                        }
                    }
                }
                if (state.legacyHistoryAvailable) item {
                    AssistantDisclosure(stringResource(R.string.earlier_sam_history)) {
                        state.earlier.forEach { message -> Text(message.role); AssistantMarkdown(message.content, open) }
                        if (!state.earlierLoaded || state.earlierCursor != null) TextButton(onClick = onEarlier, enabled = !state.loading) { Text(stringResource(R.string.load_older)) }
                    }
                }
                if (state.nextCursor != null) item { TextButton(onClick = onOlder, enabled = !state.loading) { Text(stringResource(R.string.load_older)) } }
                if (state.loading && !state.loaded) item { CircularProgressIndicator() }
                if (state.loaded && state.turns.isEmpty()) item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.sam_welcome), style = MaterialTheme.typography.headlineSmall)
                        listOf(R.string.sam_suggest_attention, R.string.sam_suggest_running, R.string.sam_suggest_ideas).forEach { id ->
                            val suggestion = stringResource(id)
                            OutlinedButton(onClick = { onDraft(suggestion) }) { Text(suggestion) }
                        }
                    }
                }
                items(state.turns, key = { it.id }) { turn ->
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            Surface(shape = MaterialTheme.shapes.large, tonalElevation = 2.dp) { Text(turn.message, Modifier.padding(16.dp)) }
                        }
                        Text("SAM · ${turn.state.replace('_', ' ')}", style = MaterialTheme.typography.labelSmall)
                        if (turn.state == "accepted" || turn.state == "running") turn.live?.let { live ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { CircularProgressIndicator(Modifier.size(16.dp)); Text(live.phase) }
                            live.thinking?.let { AssistantDisclosure(stringResource(R.string.sam_thinking)) { Text(it) } }
                            live.activity.forEach { Text("${assistantOperation(it.operation)} · ${it.state}", style = MaterialTheme.typography.bodySmall) }
                            if (live.text.isNotEmpty()) AssistantMarkdown(live.text, open)
                        }
                        turn.response?.let { AssistantMarkdown(it, open) }
                        turn.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        turn.actions.forEach { action ->
                            AssistantActionCard(action, state.busy, open = open,
                                confirm = { onConfirm(action.id, it) },
                                reconcile = { onReconcile(action.id) })
                        }
                    }
                }
                item { Spacer(Modifier.height(48.dp)) }
            }
            FilledTonalIconButton(onClick = { scope.launch { list.animateScrollToItem((list.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)) } },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp)) {
                Icon(AssistantIcons.Down, stringResource(R.string.jump_latest))
            }
        }
    }
}

@Composable
private fun AssistantActionCard(action: AssistantAction, busy: Boolean, open: (String) -> Unit, confirm: (Boolean) -> Unit, reconcile: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(assistantOperation(action.operation), style = MaterialTheme.typography.titleMedium)
            Text(if (action.available == false) stringResource(R.string.sam_unavailable_action) else action.state.replace('_', ' '))
            if (action.available != false) {
                val approval = action.state == "approval_required"
                if (approval) Text(stringResource(when (action.operation) {
                    "sam_work_stop" -> R.string.sam_confirm_stop_hint
                    "sam_agent_answer" -> R.string.sam_confirm_answer_hint
                    else -> R.string.sam_confirm_hint
                }))
                if (action.inputJson != "{}" || action.resultJson != null) {
                    AssistantDisclosure(stringResource(R.string.exact_request), initiallyOpen = approval) { Text(action.inputJson, fontFamily = FontFamily.Monospace) }
                    action.resultJson?.let { AssistantDisclosure(stringResource(R.string.recorded_result)) { Text(it, fontFamily = FontFamily.Monospace) } }
                }
                assistantActionLink(action)?.let { link -> TextButton(onClick = { open(link) }) { Text(stringResource(R.string.open_on_web)) } }
                if (approval) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { confirm(true) }, enabled = !busy, colors = if (action.operation == "sam_work_stop") ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error) else ButtonDefaults.buttonColors()) { Text(stringResource(R.string.sam_confirm)) }
                    OutlinedButton(onClick = { confirm(false) }, enabled = !busy) { Text(stringResource(R.string.sam_decline)) }
                }
                if (action.state == "uncertain") {
                    Text(stringResource(R.string.sam_uncertain))
                    if (action.operation == "sam_chat_start") TextButton(onClick = reconcile, enabled = !busy) { Text(stringResource(R.string.check_outcome)) }
                }
            }
        }
    }
}
@Composable
private fun AssistantDisclosure(title: String, initiallyOpen: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    var open by rememberSaveable { mutableStateOf(initiallyOpen) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = { open = !open }) { Text(if (open) "▾ $title" else "▸ $title") }
        if (open) content()
    }
}
@Composable
private fun AssistantMarkdown(text: String, open: (String) -> Unit) {
    val foreground = MaterialTheme.colorScheme.onSurface.toArgb()
    val links = MaterialTheme.colorScheme.primary.toArgb()
    val html = remember(text) { assistantMarkdownHtml(text) }
    AndroidView(modifier = Modifier.fillMaxWidth(), factory = { context ->
        android.widget.TextView(context).apply {
            setTextIsSelectable(true)
            movementMethod = android.text.method.LinkMovementMethod.getInstance()
            textSize = 16f
        }
    }, update = { view ->
        view.setTextColor(foreground); view.setLinkTextColor(links)
        val rendered = android.text.SpannableString(android.text.Html.fromHtml(html, android.text.Html.FROM_HTML_MODE_COMPACT))
        rendered.getSpans(0, rendered.length, android.text.style.URLSpan::class.java).forEach { span ->
            val start = rendered.getSpanStart(span); val end = rendered.getSpanEnd(span)
            rendered.removeSpan(span)
            rendered.setSpan(object : android.text.style.ClickableSpan() {
                override fun onClick(widget: android.view.View) { open(span.url) }
            }, start, end, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        view.text = rendered
    })
}
private fun assistantOperation(operation: String) = operation.removePrefix("sam_").replace('_', ' ').replaceFirstChar { it.uppercase() }
