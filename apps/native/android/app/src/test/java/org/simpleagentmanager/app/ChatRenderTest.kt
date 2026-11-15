package org.simpleagentmanager.app

import android.app.Application
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNode
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performScrollToIndex
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.simpleagentmanager.core.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-420dpi", application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatRenderTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun span(text: String, code: Boolean = false) = Span(text, false, false, code, false, null)
    private val items = listOf(
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
    private fun render(dark: Boolean = false, expanded: Boolean = false, largeText: Boolean = false, empty: Boolean = false, history: Boolean = false, table: Boolean = false, setup: Boolean = false) {
        val historyItems = if (history) List(20) { i -> ChatItem("history-$i", 0, ChatContent.Agent("Earlier update $i", listOf(Block.Paragraph(listOf(span("Earlier update $i")))))) } else emptyList()
        val tableItems = if (table) listOf(ChatItem("table", 4, ChatContent.Agent("", listOf(Block.Table(
            TableRow(listOf(listOf(span("Action")), listOf(span("Shortcut")), listOf(span("Accessibility")))),
            listOf(TableRow(listOf(listOf(span("Open command menu")), listOf(span("⌘K", true)), listOf(span("Focus moves to search"))))),
        ))))) else emptyList()
        val state = ChatState("project", "session", ChatSession("session", "Keyboard shortcuts", SessionStatus.ACTIVE, 4u, 0, null, null, true, null), if (empty) emptyList() else if (setup) items.take(1) else historyItems + items + tableItems, emptyList(), false, false, emptyList(), if (setup) ProvisioningState(1u, ProvisioningStep.WORKSPACE_CREATION, 0) else null, false, false, null)
        compose.setContent { MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, if (largeText) 1.5f else density.fontScale)) {
                ChatContent(state, "", {}, {}, {}, {}, {}, {})
            }
        } }
        if (expanded) {
            compose.onNodeWithText("Activity · 3 tools").performClick()
            compose.onNodeWithText("Run accessibility checks").assertIsDisplayed()
        }
        compose.waitForIdle()
        if (history) {
            compose.onNodeWithTag("chat-timeline").performScrollToIndex(0)
            compose.onNodeWithContentDescription("Jump to latest").assertIsDisplayed()
        }
        compose.onNodeWithContentDescription("Send").assertIsDisplayed()
        if (setup) compose.onNodeWithText("Cloning repository · 2 of 4").assertIsDisplayed()
        if (empty) compose.onNodeWithText("The conversation will appear here.").assertIsDisplayed()
        if (history) {
            compose.onNodeWithContentDescription("Jump to latest").performClick()
            compose.onNodeWithText("Verify accessibility", substring = true).assertIsDisplayed()
        }
    }
    @Test fun composerKeepsFocusWhenDraftWraps() {
        var sent = ""
        var current = ""
        compose.setContent {
            var draft by remember { mutableStateOf("") }
            MaterialTheme {
                Composer("Message", draft, { draft = it; current = it }, false, emptyList(), {}, {}, { sent = draft })
            }
        }
        val editor = compose.onNode(hasSetTextAction())
        editor.performClick().performTextInput("Please check keyboard shortcuts and accessibility with a screen reader before sending the final summary.")
        editor.assertIsFocused()
        compose.onNodeWithContentDescription("Send").performClick()
        org.junit.Assert.assertEquals(current, sent)
        org.junit.Assert.assertTrue(sent.startsWith("Please check"))
    }
    @Test fun provisioningBelowMessages() = render(setup = true)
    @Test fun historyArrow() = render(history = true)
    @Test fun markdownTable() = render(table = true)
    @Test fun lightChat() = render()
    @Test @Config(qualifiers = "w1280dp-h800dp-160dpi") fun tabletChat() = render()
    @Test fun largeTextChat() = render(largeText = true)
    @Test fun emptyChat() = render(empty = true)
    @Test fun darkChat() = render(dark = true)
    @Test fun expandedActivity() = render(expanded = true)
}
