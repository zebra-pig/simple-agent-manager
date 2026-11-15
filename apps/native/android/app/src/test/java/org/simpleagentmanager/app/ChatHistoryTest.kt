package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
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
class ChatHistoryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun state() = ChatState("project", "session", null,
        List(40) { ChatItem("message-$it", it.toLong(), ChatContent.User("Message $it", emptyList())) },
        emptyList(), false, true, emptyList(), emptyList(), null, emptyList(), null,
        false, false, false, null, false, null)

    @Test fun reachingHistoryLoadsAutomaticallyAndKeepsTheVisibleMessage() {
        val list = LazyListState()
        val snapshot = mutableStateOf(state())
        var requests = 0
        compose.setContent {
            MaterialTheme {
                ChatContent(snapshot.value, "", {}, {}, {}, {}, {}, listState = list,
                    onLoadOlder = { requests++; snapshot.value = snapshot.value.copy(loadingHistory = true) }, onSend = {})
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(0, requests); list.requestScrollToItem(0) }
        compose.waitForIdle()
        compose.onNodeWithTag("history-loader").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(1, requests)
            list.requestScrollToItem(1, 12)
        }
        compose.waitForIdle()
        var key: Any? = null
        var offset = 0
        compose.runOnIdle {
            key = list.layoutInfo.visibleItemsInfo.first().key
            offset = list.firstVisibleItemScrollOffset
            val older = List(20) { ChatItem("older-$it", it.toLong() - 20, ChatContent.User("Older $it", emptyList())) }
            snapshot.value = snapshot.value.copy(items = older + snapshot.value.items, loadingHistory = false)
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(key, list.layoutInfo.visibleItemsInfo.first().key)
            assertEquals(offset, list.firstVisibleItemScrollOffset)
            assertEquals(1, requests)
        }
    }

    @Test fun arrivingConversationStartsAtLatestWithoutLoadingHistory() {
        val list = LazyListState()
        val snapshot = mutableStateOf(state().copy(items = emptyList(), hasMore = false, loading = true))
        var requests = 0
        compose.setContent {
            MaterialTheme {
                ChatContent(snapshot.value, "", {}, {}, {}, {}, {}, listState = list,
                    onLoadOlder = { requests++ }, onSend = {})
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { snapshot.value = state() }
        compose.waitForIdle()
        compose.onNodeWithText("Message 39").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, requests) }
    }

    @Test fun historyFailureStopsAutomaticRequestsAndOffersRetry() {
        val list = LazyListState()
        var requests = 0
        compose.setContent {
            MaterialTheme {
                ChatContent(state().copy(historyError = UserError.Offline("Connection failed")), "", {}, {}, {}, {}, {},
                    listState = list, onLoadOlder = { requests++ }, onSend = {})
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { list.requestScrollToItem(0) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(0, requests) }
        compose.onNodeWithText("Retry earlier messages").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(1, requests) }
    }
}
