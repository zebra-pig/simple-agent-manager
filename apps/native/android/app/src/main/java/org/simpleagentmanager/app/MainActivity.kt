package org.simpleagentmanager.app

import android.content.Intent
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
        openNotification(intent)
        Push.askPermission(this)
        setContent {
            SamTheme {
                Root(session, projects, project, chat, openUrl = ::openUrl)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openNotification(intent)
    }

    /** A tapped notification (Push.kt) opens its session. */
    private fun openNotification(intent: Intent?) {
        val route = Push.route(intent) ?: return
        intent?.replaceExtras(null) // not again on recreation
        session.push(route)
    }

    /** Sign-in approval pages and pull requests open in a Custom Tab. */
    private fun openUrl(url: String) {
        val uri = url.toUri()
        if (uri.scheme == "https" || uri.scheme == "http") {
            runCatching { CustomTabsIntent.Builder().build().launchUrl(this, uri) }
        }
    }
}
