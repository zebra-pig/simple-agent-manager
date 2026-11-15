package org.simpleagentmanager.app

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.material3.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.simpleagentmanager.core.*
import java.io.File

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
    private fun render(name: String, dark: Boolean = false, expanded: Boolean = false, largeText: Boolean = false, empty: Boolean = false) {
        val state = ChatState("project", "session", ChatSession("session", "Keyboard shortcuts", SessionStatus.ACTIVE, 4u, 0, null, null, true, null), if (empty) emptyList() else items, emptyList(), false, false, emptyList(), false, false, null)
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
        compose.runOnIdle {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            val file = File("build/outputs/chat-previews/$name.png")
            file.parentFile.mkdirs()
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }

        }
    }
    @Test fun lightChat() = render("chat-light")
    @Test
    @Config(qualifiers = "w1280dp-h800dp-160dpi")
    fun tabletChat() = render("chat-tablet")
    @Test fun largeTextChat() = render("chat-large-text", largeText = true)
    @Test fun emptyChat() = render("chat-empty", empty = true)
    @Test fun darkChat() = render("chat-dark", dark = true)
    @Test fun expandedActivity() = render("chat-activity", expanded = true)
}
