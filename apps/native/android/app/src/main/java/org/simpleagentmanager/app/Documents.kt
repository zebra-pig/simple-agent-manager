package org.simpleagentmanager.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.Canvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.simpleagentmanager.core.ChatDocument
import org.simpleagentmanager.core.ChatViewModel

private val ChatDocument.image: Boolean
  get() =
    mimeType != "image/svg+xml" &&
      filename.substringAfterLast('.', "").lowercase() != "svg" &&
      (mimeType.startsWith("image/") ||
        filename.substringAfterLast('.', "").lowercase() in
          setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"))

// Decode near the display size rather than allocating the source image's full pixel count.
private suspend fun decode(bytes: ByteArray, max: Int): ImageBitmap? =
  withContext(Dispatchers.Default) {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val options = BitmapFactory.Options()
    while (
      bounds.outWidth / options.inSampleSize > max || bounds.outHeight / options.inSampleSize > max
    ) options.inSampleSize *= 2
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)?.asImageBitmap()
  }

@Composable
fun DocumentCard(document: ChatDocument, documents: List<ChatDocument>, core: ChatViewModel, compactImage: Boolean = false) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var thumbnail by remember(document.fileId) { mutableStateOf<ImageBitmap?>(null) }
  var gallery by remember { mutableStateOf(false) }
  var busy by remember { mutableStateOf(false) }
  var failed by remember { mutableStateOf(false) }
  val label = document.filename.ifEmpty { stringResource(R.string.document_file) }
  LaunchedEffect(document.fileId) {
    if (document.image && !document.unavailable)
      core.documentBytes(document.fileId)?.let { thumbnail = decode(it, 440) }
  }
  OutlinedCard(
    onClick = {
      if (document.image) gallery = true
      else
        scope.launch {
          busy = true
          failed = false
          try {
            val bytes = core.documentBytes(document.fileId)
            if (bytes == null) failed = true
            else {
              val file =
                withContext(Dispatchers.IO) {
                  val folder = File(context.cacheDir, "documents").apply { mkdirs() }
                  // Expire old previews; only this narrow directory is shared with the OS.
                  folder
                    .listFiles()
                    ?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000 }
                    ?.forEach { it.deleteRecursively() }
                  val dir = File(folder, java.util.UUID.randomUUID().toString()).apply { mkdirs() }
                  File(dir, File(label).name.takeUnless { it == "." || it == ".." } ?: "File")
                    .apply { writeBytes(bytes) }
                }
              val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
              val type = document.mimeType.takeIf { it.isNotBlank() } ?: "application/octet-stream"
              val intent =
                Intent(Intent.ACTION_VIEW)
                  .setDataAndType(uri, type)
                  .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
              try {
                context.startActivity(intent)
              } catch (_: ActivityNotFoundException) {
                failed = true
              }
            }
          } catch (_: java.io.IOException) {
            failed = true
          } finally {
            busy = false
          }
        }
    },
    enabled = !busy && !document.unavailable && document.fileId.isNotEmpty(),
    modifier = Modifier.widthIn(max = 260.dp),
  ) {
    if (compactImage && document.image) SquareImageTile(thumbnail, label, 120.dp)
    else DocumentCardContent(document, thumbnail, busy, failed)
  }
  if (gallery)
    DocumentGallery(
      documents.filter { it.image && !it.unavailable && it.fileId.isNotEmpty() },
      document.fileId,
      core,
    ) {
      gallery = false
    }
}

@Composable
private fun DocumentGallery(
  documents: List<ChatDocument>,
  initial: String,
  core: ChatViewModel,
  close: () -> Unit,
) {
  if (documents.isEmpty()) return
  Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    DocumentGalleryContent(documents, initial, { document ->
      core.documentBytes(document.fileId)?.let { decode(it, 2048) }
    }, close)
  }
}

@Composable
internal fun DocumentGalleryContent(
  documents: List<ChatDocument>,
  initial: String,
  load: suspend (ChatDocument) -> ImageBitmap?,
  close: () -> Unit,
) {
  GalleryLayout(documents, initial, close) { document -> GalleryPage(document, load) }
}

@Composable
internal fun GalleryLayout(
  documents: List<ChatDocument>, initial: String, close: () -> Unit,
  pageContent: @Composable (ChatDocument) -> Unit,
) {
  if (documents.isEmpty()) return
  val pager = rememberPagerState(
    initialPage = documents.indexOfFirst { it.fileId == initial }.coerceAtLeast(0),
    pageCount = { documents.size },
  )
  val document = documents[pager.currentPage.coerceAtMost(documents.lastIndex)]
  Surface(Modifier.fillMaxSize()) {
    Column(Modifier.safeDrawingPadding()) {
      Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(document.filename, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
          style = MaterialTheme.typography.titleSmall)
        TextButton(onClick = close) { Text(stringResource(R.string.document_done)) }
      }
      HorizontalPager(
        pager, Modifier.weight(1f).fillMaxWidth(), key = { documents[it].fileId },
        beyondViewportPageCount = 1,
      ) { page -> pageContent(documents[page]) }
      if (documents.size > 1) {
        Surface(
          Modifier.align(Alignment.CenterHorizontally).padding(vertical = 12.dp),
          shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {
          Text(stringResource(R.string.document_position, pager.currentPage + 1, documents.size),
            Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            style = MaterialTheme.typography.labelLarge)
        }
      }
    }
  }
}

@Composable
private fun GalleryPage(document: ChatDocument, load: suspend (ChatDocument) -> ImageBitmap?) {
  var bitmap by remember(document.fileId) { mutableStateOf<ImageBitmap?>(null) }
  var failed by remember(document.fileId) { mutableStateOf(false) }
  var retry by remember(document.fileId) { mutableIntStateOf(0) }
  LaunchedEffect(document.fileId, retry) {
    failed = false
    bitmap = load(document)
    failed = bitmap == null
  }
  GalleryImageContent(document, bitmap, failed) { retry++ }
}

@Composable
internal fun GalleryImageContent(document: ChatDocument, bitmap: ImageBitmap?, failed: Boolean, retry: () -> Unit) {
  var scale by remember(document.fileId) { mutableFloatStateOf(1f) }
  var offset by remember(document.fileId) { mutableStateOf(Offset.Zero) }
  var viewport by remember { mutableStateOf(IntSize.Zero) }
  val transform = rememberTransformableState { zoom, pan, _ ->
    scale = (scale * zoom).coerceIn(1f, 4f)
    offset = if (scale == 1f) Offset.Zero else Offset(
      (offset.x + pan.x).coerceIn(-viewport.width * (scale - 1) / 2, viewport.width * (scale - 1) / 2),
      (offset.y + pan.y).coerceIn(-viewport.height * (scale - 1) / 2, viewport.height * (scale - 1) / 2),
    )
  }
  Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
    Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().onSizeChanged { viewport = it }, contentAlignment = Alignment.Center) {
      if (bitmap != null) {
        Image(bitmap, document.filename,
          Modifier.fillMaxSize().pointerInput(document.fileId) {
            detectTapGestures(onDoubleTap = { scale = if (scale > 1f) 1f else 2f; offset = Offset.Zero })
          }.transformable(transform, canPan = { scale > 1f })
            .graphicsLayer {
              scaleX = scale; scaleY = scale
              translationX = offset.x; translationY = offset.y
            }, contentScale = ContentScale.Fit)
      } else if (failed) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
          Text(stringResource(R.string.document_unavailable))
          TextButton(onClick = retry) { Text(stringResource(R.string.document_retry)) }
        }
      } else CircularProgressIndicator()
    }
    if (document.caption.isNotBlank()) Text(document.caption,
      Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
      style = MaterialTheme.typography.bodySmall, maxLines = 3, overflow = TextOverflow.Ellipsis)
  }
}

@Composable
internal fun DocumentCardContent(
  document: ChatDocument,
  thumbnail: ImageBitmap?,
  busy: Boolean,
  failed: Boolean,
) {
  val context = LocalContext.current
  val label = document.filename.ifEmpty { stringResource(R.string.document_file) }
  Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    if (document.image) SquareImageTile(thumbnail, label, 160.dp)
    Text(label, style = MaterialTheme.typography.bodyMedium, maxLines = 2)
    if (document.caption.isNotEmpty())
      Text(document.caption, style = MaterialTheme.typography.bodySmall)
    document.sizeBytes?.let {
      Text(
        android.text.format.Formatter.formatShortFileSize(context, it.toLong()),
        style = MaterialTheme.typography.labelSmall,
      )
    }
    if (busy) CircularProgressIndicator(Modifier.size(20.dp))
    if (document.unavailable)
      Text(stringResource(R.string.document_deleted), style = MaterialTheme.typography.bodySmall)
    else if (document.fileId.isEmpty())
      Text(stringResource(R.string.document_preparing), style = MaterialTheme.typography.bodySmall)
    else if (failed)
      Text(
        stringResource(R.string.document_unavailable),
        style = MaterialTheme.typography.bodySmall,
      )
    else
      Text(
        stringResource(if (document.image) R.string.open_gallery else R.string.open_file),
        style = MaterialTheme.typography.labelSmall,
      )
  }
}

@Composable
internal fun SquareImageTile(thumbnail: ImageBitmap?, label: String, side: Dp) {
  Box(
    Modifier.size(side).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant).semantics { contentDescription = label },
    contentAlignment = Alignment.Center,
  ) {
    if (thumbnail != null) Image(thumbnail, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    else {
      val color = MaterialTheme.colorScheme.onSurfaceVariant
      Canvas(Modifier.size(24.dp)) {
        drawRoundRect(color, cornerRadius = androidx.compose.ui.geometry.CornerRadius(3.dp.toPx()), style = Stroke(1.5.dp.toPx()))
        drawCircle(color, 2.dp.toPx(), Offset(size.width * .7f, size.height * .3f))
        drawLine(color, Offset(0f, size.height * .8f), Offset(size.width * .35f, size.height * .45f), 1.5.dp.toPx())
        drawLine(color, Offset(size.width * .35f, size.height * .45f), Offset(size.width * .9f, size.height), 1.5.dp.toPx())
      }
    }
  }
}
