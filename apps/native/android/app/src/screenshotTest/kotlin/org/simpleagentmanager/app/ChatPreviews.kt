package org.simpleagentmanager.app

import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.*
import androidx.compose.ui.tooling.preview.Preview
import com.android.tools.screenshot.PreviewTest
import org.simpleagentmanager.core.*

private fun span(text: String, code: Boolean = false) = Span(text, false, false, code, false, null)
private val previewItems = listOf(
        ChatItem("user", 0, ChatContent.User("Please add keyboard shortcuts and check accessibility.")),
        ChatItem("agent", 1, ChatContent.Agent("", listOf(
            Block.Heading(2u, listOf(span("Keyboard shortcuts"))),
            Block.Paragraph(listOf(span("I’ve added shortcuts for the main actions. They work with "), span("⌘K", true), span(" and respect the current focus."))),
            Block.ListItem(0u, ListMarker.Task(true), listOf(span("Open the command menu"))),
            Block.ListItem(0u, ListMarker.Task(true), listOf(span("Move between conversations"))),
            Block.Code("kotlin", "Shortcut(Key.K, meta = true) {\n    openCommandMenu()\n}"),
        ))),
        ChatItem("activity", 2, ChatContent.Activity(listOf(ActivityStep.Tool(ToolCall("tool", "Run accessibility checks", false, ToolKind.EXECUTE, ToolStatus.COMPLETED, listOf("app/Chat.kt"), "All checks passed"))), ActivitySummary(3u, 0u, false, null))),
        ChatItem("plan", 3, ChatContent.Plan(listOf(PlanEntry("Add shortcuts", PlanStatus.COMPLETED), PlanEntry("Verify accessibility", PlanStatus.IN_PROGRESS)))),
    )

private fun previewState() = ChatState("project", "session", ChatSession(workspaceId = null, agentSessionId = null, viewerAccess = "owner", isMine = true, id = "session", topic = "Keyboard shortcuts", status = SessionStatus.ACTIVE, messageCount = 4u, startedAt = 0, lastMessageAt = null, taskId = null, isIdle = true, task = null), previewItems, emptyList(), false, false, emptyList(), emptyList(), null, emptyList(), null, false, false, false, null)

@PreviewTest
@Preview(name = "Phone", widthDp = 411, heightDp = 891)
@Composable
fun PhoneChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, onSend = {}) } }

@PreviewTest
@Preview(name = "Dark", widthDp = 411, heightDp = 891)
@Composable
fun DarkChat() { MaterialTheme(colorScheme = darkColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, onSend = {}) } }

@PreviewTest
@Preview(name = "Tablet", widthDp = 1280, heightDp = 800)
@Composable
fun TabletChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, onSend = {}) } }

@PreviewTest
@Preview(name = "Large text", widthDp = 411, heightDp = 891, fontScale = 1.5f)
@Composable
fun LargeTextChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, onSend = {}) } }

@PreviewTest
@Preview(name = "Latest arrow", widthDp = 120, heightDp = 120)
@Composable
fun LatestArrowPreview() {
    MaterialTheme(colorScheme = lightColorScheme()) {
        Surface { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LatestArrow({}) } }
    }
}

@PreviewTest
@Preview(name = "Expanded composer", widthDp = 411, heightDp = 891)
@Composable
fun ExpandedComposerChat() {
    MaterialTheme(colorScheme = lightColorScheme()) {
        ChatContent(previewState(), "Please verify the keyboard shortcuts with a screen reader, then summarize the remaining accessibility improvements.", {}, {}, {}, {}, {}, onSend = {})
    }
}

private fun progressPreviewState() = previewState().copy(
    session = previewState().session?.copy(task = TaskSummary("task", "in_progress", "workspace_creation", null, null, "feature/keyboard-shortcuts", null, "Preparing keyboard shortcut improvements.")),
    provisioning = ProvisioningState(1u, ProvisioningStep.WORKSPACE_CREATION, 0),
    working = true,
    notifications = listOf(Notification("update", "project", "session", "Workspace ready", "The development environment is ready. Progress details remain available here while the conversation stays clear.", "task_started", null, null, null)),
)

@PreviewTest
@Preview(name = "Progress phone", widthDp = 375, heightDp = 700)
@Composable
fun ProgressPhone() {
    MaterialTheme(colorScheme = lightColorScheme()) {
        Surface { Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Progress", style = MaterialTheme.typography.titleLarge)
            ChatProgressContent(progressPreviewState(), {})
        } }
    }
}

@PreviewTest
@Preview(name = "Progress narrow dark", widthDp = 320, heightDp = 700)
@Composable
fun ProgressNarrowDark() {
    MaterialTheme(colorScheme = darkColorScheme()) {
        Surface { Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Progress", style = MaterialTheme.typography.titleLarge)
            ChatProgressContent(progressPreviewState(), {})
        } }
    }
}

@PreviewTest
@Preview(name = "Progress tablet", widthDp = 1280, heightDp = 800)
@Composable
fun ProgressTablet() {
    MaterialTheme(colorScheme = lightColorScheme()) {
        Surface { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 640.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Progress", style = MaterialTheme.typography.titleLarge)
                ChatProgressContent(progressPreviewState(), {})
            }
        } }
    }
}

@PreviewTest
@Preview(name = "Clear conversation", widthDp = 375, heightDp = 700)
@Composable
fun ClearConversation() {
    MaterialTheme(colorScheme = lightColorScheme()) {
        ChatContent(progressPreviewState(), "", {}, {}, {}, {}, {}, toolsMenu = {
            IconButton(onClick = {}) { Icon(Icons.Default.MoreVert, contentDescription = "Session tools") }
        }, onSend = {})
    }
}
