package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ImageTileTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun imageDimensionsDoNotChangeReservedTileSpace() {
        val image = mutableStateOf<ImageBitmap?>(null)
        compose.setContent { MaterialTheme { SquareImageTile(image.value, "Preview", 160.dp) } }
        fun assertSquare() {
            compose.onNodeWithContentDescription("Preview")
                .assertWidthIsEqualTo(160.dp).assertHeightIsEqualTo(160.dp)
        }
        assertSquare()
        compose.runOnIdle { image.value = ImageBitmap(600, 120) }
        assertSquare()
        compose.runOnIdle { image.value = ImageBitmap(120, 600) }
        assertSquare()
        compose.runOnIdle { image.value = null }
        assertSquare()
    }
}
