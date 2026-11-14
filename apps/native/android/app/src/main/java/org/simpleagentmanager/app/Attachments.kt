package org.simpleagentmanager.app

// Files for the next message: picked with the composer's attach button (files,
// photos) or dropped onto the composer (split screen, desktop windows). The
// shell only turns each content URI into a name, a type, a size and an
// AttachmentSource; the core checks the limits, reads the file on its own
// thread, uploads it and reports progress in its state.

import android.app.Activity
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import android.provider.OpenableColumns
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.simpleagentmanager.core.Attachment
import org.simpleagentmanager.core.AttachmentSource
import org.simpleagentmanager.core.AttachmentStatus

/** A picked or dropped file, read once by the core. */
class UriSource(private val resolver: ContentResolver, private val uri: Uri) : AttachmentSource {
    override fun read(): ByteArray? = runCatching { resolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
}

/** What the core needs to know before it reads `uri`. Call off the main thread. */
data class PickedFile(val name: String, val contentType: String, val size: Long, val source: AttachmentSource)

fun ContentResolver.describe(uri: Uri): PickedFile {
    var name: String? = null
    var size = -1L
    runCatching {
        query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !c.isNull(it) }?.let { name = c.getString(it) }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
            }
        }
    }
    // Unknown size: the core checks what it reads.
    if (size < 0) size = runCatching { openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull()?.takeIf { it >= 0 } ?: 1L
    return PickedFile(
        name = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file",
        contentType = getType(uri) ?: "",
        size = size,
        source = UriSource(this, uri),
    )
}

/** The attach button: a menu with files and the photo picker. */
@Composable
fun AttachButton(onAttach: (List<Uri>) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { if (it.isNotEmpty()) onAttach(it) }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { if (it.isNotEmpty()) onAttach(it) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.attach_files))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.choose_files)) }, onClick = {
                open = false
                files.launch(arrayOf("*/*"))
            })
            DropdownMenuItem(text = { Text(stringResource(R.string.photos)) }, onClick = {
                open = false
                photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
            })
        }
    }
}

/** The attached files, above the text field. */
@Composable
fun AttachmentStrip(attachments: List<Attachment>, onRemove: (String) -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        attachments.forEach { AttachmentChip(it) { onRemove(it.id) } }
    }
}

@Composable
private fun AttachmentChip(attachment: Attachment, onRemove: () -> Unit) {
    val context = LocalContext.current
    Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        Row(Modifier.padding(start = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            when (val status = attachment.status) {
                AttachmentStatus.Uploading -> CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                AttachmentStatus.Ready -> {}
                is AttachmentStatus.Failed -> Icon(Icons.Default.Warning, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
            }
            Column(Modifier.padding(start = 6.dp).widthIn(max = 180.dp)) {
                Text(attachment.filename, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val status = attachment.status
                if (status is AttachmentStatus.Failed) {
                    Text(status.error.message(), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error, maxLines = 2)
                } else {
                    Text(
                        Formatter.formatShortFileSize(context, attachment.size.toLong()),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            IconButton(onClick = onRemove, modifier = Modifier.size(36.dp)) {
                Icon(Icons.Default.Close, contentDescription = stringResource(R.string.remove_file, attachment.filename), Modifier.size(16.dp))
            }
        }
    }
}

/**
 * Files dropped on this element (from another app in split screen or a
 * desktop window) are attached. Plain text drags are left to the text field.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.fileDropTarget(onHover: (Boolean) -> Unit, onDrop: (List<Uri>) -> Unit): Modifier {
    val activity = LocalContext.current.findActivity()
    val hover by rememberUpdatedState(onHover)
    val drop by rememberUpdatedState(onDrop)
    val target = remember(activity) {
        object : DragAndDropTarget {
            override fun onEntered(event: DragAndDropEvent) = hover(true)
            override fun onExited(event: DragAndDropEvent) = hover(false)
            override fun onEnded(event: DragAndDropEvent) = hover(false)
            override fun onDrop(event: DragAndDropEvent): Boolean {
                hover(false)
                val dragEvent = event.toAndroidDragEvent()
                // Read access to another app's content URIs lasts while the activity lives.
                activity?.requestDragAndDropPermissions(dragEvent)
                val clip = dragEvent.clipData ?: return false
                val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
                if (uris.isEmpty()) return false
                drop(uris)
                return true
            }
        }
    }
    return dragAndDropTarget(shouldStartDragAndDrop = { event -> event.mimeTypes().any { it !in TEXT_DRAGS } }, target = target)
}

/** What a text selection drag carries. */
private val TEXT_DRAGS = setOf(ClipDescription.MIMETYPE_TEXT_PLAIN, ClipDescription.MIMETYPE_TEXT_HTML, ClipDescription.MIMETYPE_TEXT_INTENT)

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
