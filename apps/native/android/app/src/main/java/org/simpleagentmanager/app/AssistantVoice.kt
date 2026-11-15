package org.simpleagentmanager.app

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.Icons
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.AssistantViewModel
import java.io.File

/** Voice input is a draft, never an implicit send. Cancel removes the temporary recording. */
@Composable
fun AssistantVoiceButton(vm: AssistantViewModel, enabled: Boolean, onText: (String) -> Unit, onBusy: (Boolean) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    val latestText by rememberUpdatedState(onText)
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var audio by remember { mutableStateOf<File?>(null) }
    var error by remember { mutableStateOf(false) }
    fun cancel() {
        runCatching { recorder?.stop() }; recorder?.release(); recorder = null
        audio?.delete(); audio = null; onBusy(false)
    }
    fun start() {
        error = false
        try {
            val file = File.createTempFile("sam-voice-", ".m4a", context.cacheDir)
            audio = file
            @Suppress("DEPRECATION")
            val next = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
            recorder = next
            next.setAudioSource(MediaRecorder.AudioSource.MIC)
            next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            next.setAudioSamplingRate(16000); next.setAudioEncodingBitRate(64000)
            next.setOutputFile(file.absolutePath); next.setMaxDuration(120_000)
            next.prepare(); next.start(); onBusy(true)
        } catch (_: Exception) { cancel(); error = true }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if (allowed && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && enabled) start() else error = true
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) cancel() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); cancel() }
    }
    IconButton(onClick = {
        val file = audio
        if (file != null) {
            runCatching { recorder?.stop() }; recorder?.release(); recorder = null; audio = null
            scope.launch {
                try {
                    val bytes = file.readBytes()
                    vm.transcribe(bytes)?.takeIf { it.isNotBlank() }?.let(latestText)
                } finally { file.delete(); onBusy(false) }
            }
        } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start()
        else permission.launch(Manifest.permission.RECORD_AUDIO)
    }, enabled = enabled || audio != null) {
        Icon(if (audio != null) AssistantIcons.Stop else AssistantIcons.Microphone,
            stringResource(if (audio != null) R.string.transcribe_recording else R.string.record_voice))
    }
    if (audio != null) TextButton(onClick = ::cancel) { Text(stringResource(R.string.cancel)) }
    if (error) AlertDialog(onDismissRequest = { error = false }, title = { Text(stringResource(R.string.record_voice)) },
        text = { Text(stringResource(R.string.voice_permission_error)) },
        confirmButton = { TextButton(onClick = { error = false }) { Text(stringResource(android.R.string.ok)) } })
}
