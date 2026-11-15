package org.simpleagentmanager.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.simpleagentmanager.core.ProvisioningState
import org.simpleagentmanager.core.ProvisioningStep

/** First-boot notice below the conversation, with the web chat's four stages. */
@Composable
internal fun ProvisioningCard(state: ProvisioningState) {
    val stages = listOf(R.string.setup_vm, R.string.setup_clone, R.string.setup_install, R.string.setup_agent)
    val stage = state.stage.toInt().coerceIn(stages.indices)
    var now by remember(state.startedAt) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.startedAt) {
        while (true) { delay(1_000); now = System.currentTimeMillis() }
    }
    val seconds = if (state.startedAt > 0) ((now - state.startedAt) / 1_000).coerceAtLeast(0) else 0
    val elapsed = if (seconds < 60) stringResource(R.string.setup_seconds, seconds)
        else stringResource(R.string.setup_minutes, seconds / 60, seconds % 60)
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // Keep the frequently ticking clock out of the live region.
            Text(
                stringResource(R.string.setup_stage, stringResource(stages[stage]), stage + 1),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
            )
            Text(elapsed, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                stringResource(R.string.setup_detail, stringResource(state.step.detailResource())),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                stages.forEachIndexed { index, _ ->
                    androidx.compose.foundation.layout.Box(
                        Modifier.weight(1f).height(3.dp).background(
                            if (index <= stage) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                            RoundedCornerShape(2.dp),
                        )
                    )
                }
            }
        }
    }
}

private fun ProvisioningStep.detailResource(): Int = when (this) {
    ProvisioningStep.WAITING -> R.string.setup_waiting
    ProvisioningStep.NODE_SELECTION -> R.string.setup_node_selection
    ProvisioningStep.WAITING_FOR_NODE_CAPACITY -> R.string.setup_capacity
    ProvisioningStep.NODE_PROVISIONING -> R.string.setup_node_provisioning
    ProvisioningStep.NODE_AGENT_READY -> R.string.setup_node_ready
    ProvisioningStep.WORKSPACE_CREATION -> R.string.setup_workspace_creation
    ProvisioningStep.WORKSPACE_DISPATCH -> R.string.setup_workspace_dispatch
    ProvisioningStep.WORKSPACE_READY -> R.string.setup_workspace_ready
    ProvisioningStep.ATTACHMENT_TRANSFER -> R.string.setup_attachments
    ProvisioningStep.AGENT_SESSION -> R.string.setup_agent_session
}
