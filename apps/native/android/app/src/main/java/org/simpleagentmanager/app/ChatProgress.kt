package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import org.simpleagentmanager.core.*

/** Status cards stay out of the conversation and remain available from Session tools. */
@Composable
internal fun ChatProgressContent(state: ChatState, openUrl: (String) -> Unit, serverUrl: String = "") {
    val notifications = state.notifications.filter { it.requestId == null }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        state.provisioning?.let { ProvisioningCard(it) }
        state.session?.task?.let { TaskCard(it, openUrl) }
        if (state.working) Text(stringResource(R.string.status_working), color = MaterialTheme.colorScheme.onSurfaceVariant)
        notifications.forEach { item ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(item.title, style = MaterialTheme.typography.titleSmall)
                    item.body?.let { Text(it) }
                    item.actionUrl?.let { action -> notificationUrl(serverUrl, action)?.let { url ->
                        TextButton(onClick = { openUrl(url) }) { Text(stringResource(R.string.open_on_web)) }
                    } }
                }
            }
        }
        state.notificationsError?.let { Text(it.message(), color = MaterialTheme.colorScheme.error) }
        if (state.provisioning == null && state.session?.task == null && notifications.isEmpty() && !state.working && state.notificationsError == null) {
            Text(stringResource(R.string.no_progress_updates), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
