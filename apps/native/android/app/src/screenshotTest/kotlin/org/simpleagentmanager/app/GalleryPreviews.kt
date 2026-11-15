package org.simpleagentmanager.app

import androidx.compose.material3.*
import androidx.compose.runtime.*
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.tooling.preview.Preview
import com.android.tools.screenshot.PreviewTest
import org.simpleagentmanager.core.ChatDocument

@Composable
private fun GalleryMock(error: Boolean = false) {
    val documents = remember { List(30) { ChatDocument("$it",
        "Coastal walk — summer photograph with a long filename $it.jpg", "image/jpeg", 100uL,
        "A quiet afternoon beside the sea · Landscape and portrait photos fit without cropping.", false) } }
    val image = remember {
        Bitmap.createBitmap(600, 900, Bitmap.Config.ARGB_8888).apply {
            val canvas = Canvas(this)
            val paint = Paint()
            paint.color = 0xffaec4d3.toInt(); canvas.drawRect(0f, 0f, 600f, 400f, paint)
            paint.color = 0xff477d9b.toInt(); canvas.drawRect(0f, 400f, 600f, 700f, paint)
            paint.color = 0xffd6c5a6.toInt(); canvas.drawRect(0f, 700f, 600f, 900f, paint)
        }.asImageBitmap()
    }
    GalleryLayout(documents, "15", {}) { document ->
        GalleryImageContent(document, if (error) null else image, error, {})
    }
}

@PreviewTest
@Preview(name = "Gallery phone", widthDp = 375, heightDp = 667)
@Composable fun GalleryPhone() { MaterialTheme { GalleryMock() } }

@PreviewTest
@Preview(name = "Gallery tablet", widthDp = 1280, heightDp = 800)
@Composable fun GalleryTablet() { MaterialTheme(colorScheme = darkColorScheme()) { GalleryMock() } }

@PreviewTest
@Preview(name = "Gallery retry phone", widthDp = 375, heightDp = 667)
@Composable fun GalleryRetryPhone() { MaterialTheme { GalleryMock(error = true) } }
