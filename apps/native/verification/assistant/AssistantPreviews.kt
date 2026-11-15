package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.android.tools.screenshot.PreviewTest
import org.simpleagentmanager.core.*

private fun state(turns: List<AssistantTurn> = emptyList()) = AssistantState(
    enabled = true, loaded = true, loading = false, busy = false, turns = turns, work = emptyList(),
    nextCursor = null, conversationId = "private", legacyHistoryAvailable = false, earlier = emptyList(),
    earlierCursor = null, earlierLoaded = false, pending = null, error = null,
)
@Composable
private fun PreviewShell(state: AssistantState, draft: String = "") {
    MaterialTheme {
        Scaffold(bottomBar = { MainTabs(false, {}, {}, assistant = true, assistantEnabled = true) }) { padding ->
            Box(Modifier.padding(padding)) {
                AssistantContent(state, draft, onDraft = {}, voice = { IconButton({}) { Icon(AssistantIcons.Microphone, "Record voice message") } })
            }
        }
    }
}
@PreviewTest
@Preview(widthDp = 393, heightDp = 900, showBackground = true)
@Preview(widthDp = 900, heightDp = 1000, showBackground = true, name = "Tablet")
@Composable
fun AssistantWelcomePreview() { PreviewShell(state()) }

@PreviewTest
@Preview(widthDp = 393, heightDp = 1100, showBackground = true)
@Preview(widthDp = 900, heightDp = 1100, showBackground = true, name = "Tablet")
@Composable
fun AssistantConfirmationPreview() {
    PreviewShell(state(listOf(AssistantTurn("t1", "key", "Stop the old preview workspace after I confirm.", "completed",
        "The workspace is still running. Review the exact request before confirming.", null,
        listOf(AssistantAction("a1", "sam_work_stop", "{\"projectId\":\"release-tools\",\"sessionId\":\"preview-chat\"}", "approval_required", null, true)), null))))
}
@PreviewTest
@Preview(widthDp = 393, heightDp = 900, showBackground = true)
@Composable
fun AssistantRunningPreview() {
    PreviewShell(state(listOf(AssistantTurn("t1", "key", "What needs my attention?", "running", null, null, emptyList(),
        AssistantLive("working", 2400uL, "I found two projects with updates.", null, listOf(AssistantActivity("read1", "sam_inbox_get", "completed")))))))
}
@PreviewTest
@Preview(widthDp = 393, heightDp = 900, showBackground = true)
@Composable
fun AssistantRetryPreview() {
    PreviewShell(state().copy(pending = AssistantPending("key", "Show my recent ideas"), error = UserError.Server("Could not send. Retry uses the same request.")))
}
