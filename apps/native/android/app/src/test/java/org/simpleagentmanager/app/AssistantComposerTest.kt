package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertEquals
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
class AssistantComposerTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun state(turns: List<AssistantTurn> = emptyList(), pending: AssistantPending? = null) = AssistantState(
        enabled = true, loaded = true, loading = false, busy = false, turns = turns, work = emptyList(),
        nextCursor = null, conversationId = "private", legacyHistoryAvailable = false, earlier = emptyList(),
        earlierCursor = null, earlierLoaded = true, pending = pending, error = null,
    )
    @Test fun emptyDraftCannotSend() {
        compose.setContent { MaterialTheme { AssistantContent(state(), "", {}) } }
        compose.onNodeWithContentDescription("Send").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Jump to latest").assertDoesNotExist()
    }
    @Test fun draftSendsThroughSharedControl() {
        var sends = 0
        compose.setContent { MaterialTheme { AssistantContent(state(), "Review my projects", {}, onSend = { sends++ }) } }
        compose.onNodeWithContentDescription("Send").assertIsEnabled().performClick()
        assertEquals(1, sends)
    }
    @Test fun retryRetainsReceiptWithEmptyLockedEditor() {
        var retries = 0
        compose.setContent { MaterialTheme {
            AssistantContent(state(pending = AssistantPending("receipt", "Original message")), "", {}, onSend = { retries++ })
        } }
        compose.onAllNodes(hasSetTextAction()).assertCountEquals(0)
        compose.onNodeWithContentDescription("Retry").assertIsEnabled().performClick()
        assertEquals(1, retries)
    }
    @Test fun runningTurnCanStopWithEmptyDraft() {
        var stops = 0
        val turn = AssistantTurn("turn", "receipt", "Help", "running", null, null, emptyList(), null)
        compose.setContent { MaterialTheme { AssistantContent(state(listOf(turn)), "", {}, onStop = { stops++ }) } }
        compose.onNodeWithContentDescription("Stop").assertIsEnabled().performClick()
        assertEquals(1, stops)
    }
    @Test fun sharedJumpInterruptsScrollAndReturnsToLatest() {
        val turns = List(30) { AssistantTurn("turn-$it", "receipt-$it", "Question $it", "completed", null, null, emptyList(), null) }
        compose.setContent { MaterialTheme { AssistantContent(state(turns), "", {}) } }
        compose.onNodeWithContentDescription("Jump to latest").performClick()
        compose.onNodeWithText("Question 29").assertIsDisplayed()
        compose.onNodeWithContentDescription("Jump to latest").assertDoesNotExist()
    }
}
