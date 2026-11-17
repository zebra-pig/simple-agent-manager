package org.simpleagentmanager.app

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PortsScreen(model: ChatModel, workspaceId: String, openUrl: (String) -> Unit) {
    val state by model.portsState.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var confirmPublic by remember { mutableStateOf(false) }
    val busy = state.loading || state.saving || state.opening != null
    val shareTitle = stringResource(R.string.ports_share)
    LaunchedEffect(workspaceId) {
        model.ports.load(workspaceId)
        while (true) { model.ports.refresh(); delay(10_000) }
    }
    LazyColumn(Modifier.fillMaxWidth().fillMaxHeight(.9f).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(bottom = 32.dp)) {
        item { Text(stringResource(R.string.ports_title), style = MaterialTheme.typography.headlineSmall) }
        item {
            Text(stringResource(if (!state.loaded) R.string.ports_checking else if (state.publicEnabled) R.string.ports_public else R.string.ports_private), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(if (state.publicEnabled) R.string.ports_public_help else R.string.ports_private_help))
            TextButton(enabled = state.loaded && !busy, onClick = {
                if (state.publicEnabled) scope.launch { model.ports.setPublic(false) } else confirmPublic = true
            }) { Text(stringResource(if (state.publicEnabled) R.string.ports_make_private else R.string.ports_expose)) }
        }
        state.error?.let { error -> item { Text(error.message(), color = MaterialTheme.colorScheme.error) } }
        item { TextButton(enabled = !busy, onClick = { scope.launch { model.ports.refresh() } }) { Text(stringResource(R.string.tool_refresh)) } }
        if (state.loading) item { CircularProgressIndicator() }
        if (state.loaded && state.ports.isEmpty()) item {
            Text(stringResource(when (state.readiness) {
                "ready" -> R.string.ports_empty
                "sleeping", "stopped", "evicted" -> R.string.ports_sleeping
                "gone", "deleted" -> R.string.ports_gone
                else -> R.string.ports_waiting
            }))
        }
        items(state.ports, key = { it.port }) { port ->
            HorizontalDivider()
            Text(stringResource(R.string.ports_number, port.port.toInt()), style = MaterialTheme.typography.titleMedium)
            if (port.label.isNotEmpty()) Text(port.label)
            Text(port.url, style = MaterialTheme.typography.bodySmall)
            Row {
                TextButton(enabled = !busy, onClick = { scope.launch { model.ports.openPort(port.port)?.let(openUrl) } }) { Text(stringResource(R.string.ports_open)) }
                if (state.publicEnabled) TextButton(onClick = {
                    val send = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, port.url) }
                    context.startActivity(Intent.createChooser(send, shareTitle))
                }) { Text(shareTitle) }
            }
        }
    }
    if (confirmPublic) AlertDialog(
        onDismissRequest = { confirmPublic = false },
        title = { Text(stringResource(R.string.ports_confirm)) },
        text = { Text(stringResource(R.string.ports_confirm_help)) },
        confirmButton = { TextButton(onClick = { confirmPublic = false; scope.launch { model.ports.setPublic(true) } }) { Text(stringResource(R.string.ports_expose)) } },
        dismissButton = { TextButton(onClick = { confirmPublic = false }) { Text(stringResource(R.string.cancel)) } },
    )
}
