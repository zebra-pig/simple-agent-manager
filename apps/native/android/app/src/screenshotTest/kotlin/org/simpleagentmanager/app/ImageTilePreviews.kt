package org.simpleagentmanager.app

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.android.tools.screenshot.PreviewTest
import org.simpleagentmanager.core.*
import java.io.ByteArrayOutputStream

@Composable
private fun ImageTiles() {
    val wide = remember { Bitmap.createBitmap(600, 120, Bitmap.Config.ARGB_8888).apply {
        eraseColor(0xff477d9b.toInt())
        for (x in 240 until 360) for (y in 0 until height) setPixel(x, y, 0xffd6ad70.toInt())
    } }
    val tall = remember { Bitmap.createBitmap(120, 600, Bitmap.Config.ARGB_8888).apply {
        eraseColor(0xff56836d.toInt())
        for (x in 0 until width) for (y in 240 until 360) setPixel(x, y, 0xffb9cbd8.toInt())
    } }
    val bytes = remember { ByteArrayOutputStream().use { wide.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() } }
    Surface { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Image uploads", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AttachmentChip(Attachment("ready", "landscape.png", 200uL, "image/png", AttachmentStatus.Ready, "upload", bytes), {})
            AttachmentChip(Attachment("loading", "portrait.png", 200uL, "image/png", AttachmentStatus.Uploading, null, null), {})
        }
        Text("Inline images · crop to fill", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SquareImageTile(wide.asImageBitmap(), "Landscape", 160.dp)
            SquareImageTile(tall.asImageBitmap(), "Portrait", 160.dp)
        }
        Text("Space reserved before loading", style = MaterialTheme.typography.titleMedium)
        SquareImageTile(null, "Loading image", 160.dp)
    } }
}

@PreviewTest
@Preview(name = "Image tiles phone", widthDp = 375, heightDp = 650)
@Composable
fun ImageTilesPhone() { MaterialTheme { ImageTiles() } }

@PreviewTest
@Preview(name = "Image tiles tablet", widthDp = 1280, heightDp = 800)
@Composable
fun ImageTilesTablet() { MaterialTheme(colorScheme = darkColorScheme()) { ImageTiles() } }
