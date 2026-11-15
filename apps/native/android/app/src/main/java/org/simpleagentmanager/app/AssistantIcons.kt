package org.simpleagentmanager.app

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/** Small native vectors avoid shipping the entire extended Material icon set. */
internal object AssistantIcons {
    private fun vector(name: String, path: String) = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
        .addPath(PathParser().parsePathString(path).toNodes(), fill = SolidColor(Color.Black)).build()
    val Sparkles = vector("SAM", "M12,2 L14.6,9.4 L22,12 L14.6,14.6 L12,22 L9.4,14.6 L2,12 L9.4,9.4 Z M20,1 L20.8,3.2 L23,4 L20.8,4.8 L20,7 L19.2,4.8 L17,4 L19.2,3.2 Z")
    val Microphone = vector("Microphone", "M12,14 C13.66,14 15,12.66 15,11 L15,5 C15,3.34 13.66,2 12,2 C10.34,2 9,3.34 9,5 L9,11 C9,12.66 10.34,14 12,14 Z M17,11 C17,13.76 14.76,16 12,16 C9.24,16 7,13.76 7,11 L5,11 C5,14.53 7.61,17.43 11,17.92 L11,21 L13,21 L13,17.92 C16.39,17.43 19,14.53 19,11 Z")
    val Stop = vector("Stop", "M6,6 L18,6 L18,18 L6,18 Z")
    val Down = vector("Latest", "M11,3 L13,3 L13,17.17 L18.59,11.59 L20,13 L12,21 L4,13 L5.41,11.59 L11,17.17 Z")
}
