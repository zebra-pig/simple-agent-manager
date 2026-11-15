package org.simpleagentmanager.app

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.App
import org.simpleagentmanager.core.PushPlatform
import org.simpleagentmanager.core.PushToken

/**
 * Push notifications through Firebase Cloud Messaging. The token goes to the core,
 * which registers it with the server while signed in. The server sends data-only
 * messages (apps/api/src/durable-objects/notification-native-push.ts) and
 * [PushService] shows them, so a tap always opens the session.
 */
object Push {
    private const val CHANNEL = "agent-updates"
    private const val EXTRA_PROJECT = "sam.projectId"
    private const val EXTRA_SESSION = "sam.sessionId"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The build's Firebase project (BuildConfig, from the environment); none means no push. */
    private val enabled get() = BuildConfig.FIREBASE_APP_ID.isNotEmpty()

    fun start(context: Context, core: App) {
        if (!enabled) return
        FirebaseApp.initializeApp(
            context,
            FirebaseOptions.Builder()
                .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
                .setApplicationId(BuildConfig.FIREBASE_APP_ID)
                .setApiKey(BuildConfig.FIREBASE_API_KEY)
                .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID)
                .build(),
        )
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.notification_channel_name), NotificationManager.IMPORTANCE_HIGH),
        )
        FirebaseMessaging.getInstance().token.addOnSuccessListener { register(core, it) }
    }

    fun register(core: App, token: String) {
        scope.launch { core.setPushToken(PushToken(PushPlatform.FCM, token, false)) }
    }

    /** Android 13+ asks before showing notifications. */
    fun askPermission(activity: Activity) {
        if (!enabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        }
    }

    /** The session a tapped notification points at. */
    fun route(intent: Intent?): Route? {
        val projectId = intent?.getStringExtra(EXTRA_PROJECT) ?: return null
        val sessionId = intent.getStringExtra(EXTRA_SESSION) ?: return null
        return Route.Chat(projectId, sessionId)
    }

    fun show(context: Context, data: Map<String, String>) {
        val title = data["title"] ?: return
        val sessionId = data["sessionId"]
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_PROJECT, data["projectId"])
            .putExtra(EXTRA_SESSION, sessionId)
        val tap = PendingIntent.getActivity(
            context,
            (sessionId ?: title).hashCode(),
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = android.app.Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(data["body"])
            .setStyle(android.app.Notification.BigTextStyle().bigText(data["body"]))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        // One notification per session: a newer one replaces the older.
        context.getSystemService(NotificationManager::class.java).notify((sessionId ?: title).hashCode(), notification)
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) = Push.register((application as SamApplication).core, token)

    override fun onMessageReceived(message: RemoteMessage) = Push.show(this, message.data)
}
