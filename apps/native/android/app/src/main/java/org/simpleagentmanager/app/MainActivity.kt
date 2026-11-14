package org.simpleagentmanager.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri

class MainActivity : ComponentActivity() {
    private val session: SessionModel by viewModels()
    private val projects: ProjectListModel by viewModels()
    private val project: ProjectModel by viewModels()
    private val chat: ChatModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SamTheme {
                Root(session, projects, project, chat, openUrl = ::openUrl)
            }
        }
    }

    /** Sign-in approval pages and pull requests open in a Custom Tab. */
    private fun openUrl(url: String) {
        CustomTabsIntent.Builder().build().launchUrl(this, url.toUri())
    }
}
