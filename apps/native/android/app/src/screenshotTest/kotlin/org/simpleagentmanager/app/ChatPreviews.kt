package org.simpleagentmanager.app

import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

private fun previewState() = ChatState("project", "session", ChatSession("session", "Keyboard shortcuts", SessionStatus.ACTIVE, 4u, 0, null, null, true, null), previewItems, emptyList(), false, false, emptyList(), null, false, false, null)

@PreviewTest
@Preview(name = "Phone", widthDp = 411, heightDp = 891)
@Composable
fun PhoneChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, {}) } }

@PreviewTest
@Preview(name = "Dark", widthDp = 411, heightDp = 891)
@Composable
fun DarkChat() { MaterialTheme(colorScheme = darkColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, {}) } }

@PreviewTest
@Preview(name = "Tablet", widthDp = 1280, heightDp = 800)
@Composable
fun TabletChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, {}) } }

@PreviewTest
@Preview(name = "Large text", widthDp = 411, heightDp = 891, fontScale = 1.5f)
@Composable
fun LargeTextChat() { MaterialTheme(colorScheme = lightColorScheme()) { ChatContent(previewState(), "", {}, {}, {}, {}, {}, {}) } }

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
        ChatContent(previewState(), "Please verify the keyboard shortcuts with a screen reader, then summarize the remaining accessibility improvements.", {}, {}, {}, {}, {}, {})
    }
}
