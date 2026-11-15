package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.MutatePriority
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import kotlinx.coroutines.*
import org.junit.Assert.*
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
class ChatJumpTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun jumpCancelsUserScrollAndFollowsNewMessages() {
        val list = LazyListState()
        lateinit var scope: CoroutineScope
        val messages = mutableStateOf(List(40) { index ->
            ChatItem("message-$index", index.toLong(), ChatContent.User("Message $index", emptyList()))
        })
        compose.setContent {
            scope = rememberCoroutineScope()
            MaterialTheme {
                val state = ChatState("project", "session", null, messages.value, emptyList(), false, false,
                    emptyList(), emptyList(), null, emptyList(), null, false, false, false, null, false, null)
                ChatContent(state, "", {}, {}, {}, {}, {}, listState = list, onSend = {})
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { list.requestScrollToItem(0) }
        compose.waitForIdle()
        lateinit var scrolling: Job
        compose.runOnIdle {
            scrolling = scope.launch {
                list.scroll(MutatePriority.UserInput) {
                    scrollBy(20f)
                    awaitCancellation()
                }
            }
        }
        compose.runOnIdle { assertTrue("Test must click during an active user scroll", list.isScrollInProgress) }
        compose.onNodeWithContentDescription("Jump to latest").assertIsDisplayed().performClick()
        compose.waitForIdle()
        compose.runOnIdle {
            assertTrue("Existing user scroll must be cancelled", scrolling.isCancelled)
            assertFalse(list.canScrollForward)
        }
        compose.onNodeWithText("Message 39").assertIsDisplayed()
        compose.runOnIdle {
            messages.value += ChatItem("new", 40, ChatContent.User("New live message", emptyList()))
        }
        compose.waitForIdle()
        compose.onNodeWithText("New live message").assertIsDisplayed()
    }
}
