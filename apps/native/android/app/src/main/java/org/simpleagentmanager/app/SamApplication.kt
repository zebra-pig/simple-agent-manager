package org.simpleagentmanager.app

import android.app.Application
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import org.simpleagentmanager.core.App
import org.simpleagentmanager.core.CredentialStore
import org.simpleagentmanager.core.Credentials
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Holds the one Rust `App` (session) per process; the view models borrow it. */
class SamApplication : Application() {
    lateinit var core: App
        private set

    override fun onCreate() {
        super.onCreate()
        core = App(KeystoreCredentialStore(this), BuildConfig.BASE_DOMAIN)
        Push.start(this, core)
    }
}

/**
 * The server and session cookie as JSON, AES-GCM encrypted with a
 * non-exportable Android Keystore key, in private SharedPreferences. Anything
 * unreadable (key gone after a restore, corrupt blob) reads as signed out.
 */
class KeystoreCredentialStore(context: Context) : CredentialStore {
    private val prefs = context.getSharedPreferences("session", Context.MODE_PRIVATE)

    override fun load(): Credentials? = runCatching {
        val blob = Base64.decode(prefs.getString(PREF, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_SIZE))
        val json = JSONObject(String(cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE)))
        Credentials(json.getString("server_url"), json.getString("session_cookie"))
    }.getOrNull()

    override fun save(credentials: Credentials) {
        val json = JSONObject()
            .put("server_url", credentials.serverUrl)
            .put("session_cookie", credentials.sessionCookie)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val blob = cipher.iv + cipher.doFinal(json.toString().toByteArray())
        prefs.edit().putString(PREF, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    override fun clear() {
        prefs.edit().remove(PREF).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as SecretKey?)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply { init(spec) }.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "sam-session"
        const val PREF = "credentials"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}
