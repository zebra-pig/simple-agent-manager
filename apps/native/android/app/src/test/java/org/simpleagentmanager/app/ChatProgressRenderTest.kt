package org.simpleagentmanager.app

import android.app.Application
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
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
class ChatProgressRenderTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun state() = ChatState(
        projectId = "p", sessionId = "s", session = ChatSession(null, null, "owner", true, "s", "A conversation", SessionStatus.ACTIVE, 1u, 0, null, null, true,
            TaskSummary("task", "in_progress", "running", null, null, "feature", null, "Task summary")),
        items = listOf(ChatItem("reply", 1, org.simpleagentmanager.core.ChatContent.User("Latest message", emptyList()))),
        outbox = emptyList(), working = true, hasMore = false,
        requests = listOf(RequestRef("new", "s", false, false)),
        notifications = listOf(
            Notification("notice", "p", "s", "Progress notice", "Informational update", "task_started", null, null, null),
            Notification("question", "p", "s", "Older question", null, "needs_input", null, null, "older"),
        ),
        notificationsError = null, attachments = emptyList(),
        provisioning = ProvisioningState(1u, ProvisioningStep.WORKSPACE_CREATION, 0),
        reportEnabled = false, loading = false, sending = false, error = null, loadingHistory = false, historyError = null,
    )

    @OptIn(ExperimentalMaterial3Api::class)
    @Test fun progressIsHiddenUntilOpenedFromSessionMenu() {
        val chat = state()
        compose.setContent {
            var menu by remember { mutableStateOf(false) }
            var progress by remember { mutableStateOf(false) }
            MaterialTheme {
                ChatContent(chat, "", {}, {}, {}, {}, {}, toolsMenu = {
                    TextButton(onClick = { menu = true }) { Text("Session tools") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        ChatToolsMenuItems(chat, false, onTool = { menu = false; progress = it == ChatTool.Progress }, onWeb = {}, onEnd = {})
                    }
                }, requestCard = { Text("Request ${it.id}") }, onSend = {})
                if (progress) ModalBottomSheet(onDismissRequest = { progress = false }) {
                    ChatProgressContent(chat, {})
                }
            }
        }
        compose.onNodeWithText("Latest message").assertIsDisplayed()
        compose.onNodeWithText("Request new").assertIsDisplayed()
        compose.onNodeWithText("Request older").assertIsDisplayed()
        compose.onNodeWithText("Progress notice").assertDoesNotExist()
        compose.onNodeWithText("Task summary").assertDoesNotExist()
        compose.onNodeWithText("Cloning repository · 2 of 4").assertDoesNotExist()
        compose.onNodeWithText("Session tools").performClick()
        compose.onNodeWithText("Progress").performScrollTo().performClick()
        compose.onNodeWithText("Cloning repository · 2 of 4").assertIsDisplayed()
        compose.onNodeWithText("Task summary").assertIsDisplayed()
        compose.onNodeWithText("Progress notice").assertIsDisplayed()
    }

    @Test fun emptyProgressHasAnExplanation() {
        val chat = state().copy(session = null, working = false, provisioning = null, notifications = emptyList())
        compose.setContent { MaterialTheme { ChatProgressContent(chat, {}) } }
        compose.onNodeWithText("No progress updates yet.").assertIsDisplayed()
    }
}
