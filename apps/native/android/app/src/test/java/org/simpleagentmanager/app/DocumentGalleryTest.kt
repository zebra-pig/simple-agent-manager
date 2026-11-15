package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.simpleagentmanager.core.ChatDocument

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DocumentGalleryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val documents = List(30) { ChatDocument("image-$it", "Photo $it", "image/png", 100uL, "", false) }

    @Test fun opensSelectedImageAndSwipesWithoutLoadingEntireGallery() {
        val loaded = mutableSetOf<String>()
        compose.setContent { MaterialTheme {
            DocumentGalleryContent(documents, "image-15", { document ->
                loaded += document.fileId
                ImageBitmap(120, 240)
            }, {})
        } }
        compose.onNodeWithText("16 of 30").assertIsDisplayed()
        compose.onNodeWithContentDescription("Photo 15").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        compose.onNodeWithText("17 of 30").assertIsDisplayed()
        compose.onNodeWithContentDescription("Previous").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("16 of 30").assertIsDisplayed()
        compose.runOnIdle { assertTrue("Only nearby pages should load", loaded.size < 10) }
    }

    @Test fun retryRecoversAndSingleImageHasNoPagePill() {
        var attempts = 0
        compose.setContent { MaterialTheme {
            DocumentGalleryContent(documents.take(1), "image-0", {
                attempts++
                if (attempts == 1) null else ImageBitmap(240, 120)
            }, {})
        } }
        compose.onNodeWithText("Retry").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Photo 0").assertIsDisplayed()
        compose.onNodeWithContentDescription("Next").assertDoesNotExist()
    }
}
