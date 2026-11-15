package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp

/** Reserves the label's footprint while an action runs. */
@Composable
internal fun LoadingLabel(text: String, loading: Boolean) {
    Box(contentAlignment = Alignment.Center) {
        Text(text, Modifier.alpha(if (loading) 0f else 1f))
        if (loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
    }
}

/** Only the first request gates a destination, even when the result is empty. */
@Composable
internal fun InitialLoading(loading: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    var started by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }
    SideEffect {
        if (loading) started = true
        else if (started) finished = true
    }
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (loading && !finished) CircularProgressIndicator()
        else content()
    }
}
