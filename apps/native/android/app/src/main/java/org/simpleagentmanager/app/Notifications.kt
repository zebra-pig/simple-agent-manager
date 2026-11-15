package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.*

@Composable
fun NotificationsScreen(app: App, openUrl: (String) -> Unit, openChat: (String, String) -> Unit) {
    val vm = remember(app) { NotificationsViewModel(app) }
    val snapshot = remember(vm) { mutableStateOf(vm.state()) }
    val state by snapshot
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(vm) {
        vm.setObserver(object : NotificationsObserver {
            override fun onStateChanged(state: NotificationsState) { scope.launch { snapshot.value = state } }
        })
        onDispose { vm.clearObserver(); vm.close() }
    }
    LaunchedEffect(vm, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { vm.load("", ""); snapshot.value = vm.state(); delay(10_000) }
        }
    }
    InitialLoading(state.loading) {
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.notifications), style = MaterialTheme.typography.headlineMedium)
                TextButton(onClick = { scope.launch { vm.load("", ""); snapshot.value = vm.state() } }, enabled = !state.loading) { LoadingLabel(stringResource(R.string.refresh_request), state.loading) }
            }
        }
        state.error?.let { item { Text(it.message(), color = MaterialTheme.colorScheme.error) } }
        if (state.items.isEmpty() && state.error == null) item { Text(stringResource(R.string.no_notifications)) }
        items(state.items, key = { it.id }) { item ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(item.title, style = MaterialTheme.typography.titleMedium)
                    val project = item.projectId
                    val session = item.sessionId
                    val id = item.requestId
                    if (project != null && id != null) RequestCard(app, project, session ?: "", id, item.kind == "secret_request", item.kind == "operations_approval")
                    else item.body?.let { Text(it) }
                    if (project != null && session != null) TextButton(onClick = { openChat(project, session) }) { Text(stringResource(R.string.open_conversation)) }
                    item.actionUrl?.let { action -> notificationUrl(app.state().serverUrl, action)?.let { url ->
                        TextButton(onClick = { openUrl(url) }) { Text(stringResource(R.string.open_on_web)) }
                    } }
                    TextButton(onClick = { scope.launch { vm.dismiss(item.id); snapshot.value = vm.state() } }) { Text(stringResource(R.string.dismiss_notification)) }
                }
            }
        }
    }
}
}

@Composable
fun RequestCard(app: App, project: String, session: String, id: String, secret: Boolean, approval: Boolean = false, hideResolved: Boolean = false) {
    val vm = remember(app, project, session, id, secret, approval) { RequestViewModel(app) }
    val snapshot = remember(vm) { mutableStateOf(vm.state()) }
    val state by snapshot
    // Never save secret inputs in saved instance state.
    var value by remember(vm) { mutableStateOf("") }
    var confirmedVersion by remember(vm) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    DisposableEffect(vm) {
        vm.setObserver(object : RequestObserver {
            override fun onStateChanged(state: RequestState) { scope.launch { snapshot.value = state } }
        })
        onDispose { value = ""; vm.clearObserver(); vm.close() }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(vm, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { vm.load(project, session, id, secret, approval); snapshot.value = vm.state(); delay(15_000) }
        }
    }
    fun respond(answer: String, decline: Boolean) {
        scope.launch {
            if (vm.respond(project, session, id, secret, approval, answer, decline, confirmedVersion)) { value = ""; confirmedVersion = null }
            snapshot.value = vm.state()
        }
    }
    // Keep polling while hidden so a genuinely reopened request can reappear.
    if (hideResolved && requestIsResolved(state.status)) return
    val content: @Composable () -> Unit = {
        RequestContent(state, secret, approval, value, { value = it }, confirmedVersion, { confirmedVersion = it }, ::respond) {
            scope.launch { vm.load(project, session, id, secret, approval); snapshot.value = vm.state() }
        }
    }
    if (hideResolved) {
        Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) { content() } }
    } else { content() }
}

@Composable
internal fun RequestContent(
    state: RequestState, secret: Boolean, approval: Boolean,
    value: String, onValue: (String) -> Unit,
    confirmedVersion: String?, onConfirm: (String?) -> Unit,
    onRespond: (String, Boolean) -> Unit, onRefresh: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.title.isNotEmpty()) Text(if (approval) approvalTitle(state.title) else state.title, style = MaterialTheme.typography.titleSmall)
        Text(state.reason)
        if (state.irreversible && state.canRespond) Text(stringResource(R.string.irreversible_approval), color = MaterialTheme.colorScheme.error)
        state.error?.let { Text(it.message(), color = MaterialTheme.colorScheme.error) }
        if (state.canRespond) {
            if (secret) {
                OutlinedTextField(value, onValue, modifier = Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.secret_value)) }, visualTransformation = PasswordVisualTransformation(), enabled = !state.busy)
                state.existingVersion?.let { version ->
                    Text(stringResource(R.string.replace_secret_notice))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(confirmedVersion == version, { onConfirm(if (it) version else null) }, enabled = !state.busy)
                        Text(stringResource(R.string.replace_existing_value), Modifier.weight(1f))
                    }
                }
                Row {
                    Button(onClick = { onRespond(value, false) }, enabled = !state.busy && value.isNotEmpty() && (state.existingVersion == null || state.existingVersion == confirmedVersion)) { Text(stringResource(R.string.save_secret)) }
                    TextButton(onClick = { onRespond("", true) }, enabled = !state.busy) { Text(stringResource(R.string.decline_request)) }
                }
            } else if (state.options.isEmpty()) {
                OutlinedTextField(value, onValue, modifier = Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.your_answer)) }, enabled = !state.busy)
                Button(onClick = { onRespond(value.trim(), false) }, enabled = !state.busy && value.isNotBlank()) { Text(stringResource(R.string.send_answer)) }
            } else state.options.forEach { option ->
                OutlinedButton(onClick = { onRespond(option, false) }, enabled = !state.busy) {
                    if (approval) Text(stringResource(if (option == "approve") R.string.approve_request else R.string.deny_request)) else Text(option)
                }
            }
        } else if (state.status.isNotEmpty()) Text(requestStatus(state.status))
        if (state.deliveryUnconfirmed) Text(stringResource(R.string.request_delivery_unconfirmed))
        state.answer?.let { Text(it) }
        TextButton(onClick = onRefresh, enabled = !state.busy) { LoadingLabel(stringResource(R.string.refresh_request), state.busy) }
    }
}
@Composable
private fun requestStatus(status: String): String = when (status) {
    "pending" -> stringResource(R.string.request_pending)
    "answered" -> stringResource(R.string.request_answered)
    "delivering" -> stringResource(R.string.request_delivering)
    "fulfilled" -> stringResource(R.string.secret_saved)
    "declined" -> stringResource(R.string.request_declined)
    "expired" -> stringResource(R.string.request_expired)
    "approved" -> stringResource(R.string.request_approved)
    "denied" -> stringResource(R.string.request_denied)
    "executed" -> stringResource(R.string.request_executed)
    else -> status
}

@Composable
private fun approvalTitle(title: String): String {
    val parts = title.split(" · ", limit = 2)
    val action = when (parts[0]) {
        "retry_snapshot" -> stringResource(R.string.action_retry_snapshot)
        "rerun_node_cleanup" -> stringResource(R.string.action_rerun_node_cleanup)
        "sleep_session" -> stringResource(R.string.action_sleep_session)
        "delete_workspace" -> stringResource(R.string.action_delete_workspace)
        "delete_node" -> stringResource(R.string.action_delete_node)
        "restart_vm_agent" -> stringResource(R.string.action_restart_vm_agent)
        "cancel_stuck_task" -> stringResource(R.string.action_cancel_stuck_task)
        else -> parts[0]
    }
    return if (parts.size > 1) "$action · ${parts[1]}" else action
}
