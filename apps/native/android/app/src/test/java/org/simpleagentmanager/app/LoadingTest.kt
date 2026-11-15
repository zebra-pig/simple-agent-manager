package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LoadingTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun initialLoadGatesContentAndRefreshKeepsItsPosition() {
        val loading = mutableStateOf(true)
        compose.setContent {
            MaterialTheme {
                Column {
                    Button({}, Modifier.testTag("refresh")) { LoadingLabel("Refresh", loading.value) }
                    InitialLoading(loading.value) { Text("Loaded content", Modifier.testTag("content")) }
                }
            }
        }
        compose.onNodeWithTag("content").assertDoesNotExist()
        compose.runOnIdle { loading.value = false }
        compose.onNodeWithTag("content").assertIsDisplayed()
        val contentBounds = compose.onNodeWithTag("content").fetchSemanticsNode().boundsInRoot
        val buttonBounds = compose.onNodeWithTag("refresh").fetchSemanticsNode().boundsInRoot
        compose.runOnIdle { loading.value = true }
        compose.onNodeWithTag("content").assertIsDisplayed()
        assertEquals(contentBounds, compose.onNodeWithTag("content").fetchSemanticsNode().boundsInRoot)
        assertEquals(buttonBounds, compose.onNodeWithTag("refresh").fetchSemanticsNode().boundsInRoot)
        compose.runOnIdle { loading.value = false }
        assertEquals(contentBounds, compose.onNodeWithTag("content").fetchSemanticsNode().boundsInRoot)
    }
}
