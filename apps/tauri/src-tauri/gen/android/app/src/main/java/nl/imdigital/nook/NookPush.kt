package nl.imdigital.nook

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONArray
import org.json.JSONObject
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Push notifications on Android, as the iPhone's Notification Service Extension: the Mac seals what a notification
 * says (`RelayPushContent`) with a push key derived from the pairing key, the relay passes it through Firebase Cloud
 * Messaging as data only, and this service opens it and shows the real title and text. Google and the relay see only
 * the sealed blob. The push keys (never the pairing keys) are kept in the app's private preferences.
 */
object NookPush {
  private const val PREFS = "nook-push"
  const val CHANNEL = "nook-agents"
  const val EXTRA_ACTION = "nook.action"
  const val EXTRA_MAC = "nook.mac"
  const val EXTRA_SESSION = "nook.session"
  const val EXTRA_ITEM = "nook.item"
  const val REPLY_KEY = "nook.reply"

  fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  /** The keys of every paired computer, as the app sets them: `[{"mac", "name", "key"}]` (key in base64). */
  fun setKeys(context: Context, json: String) {
    prefs(context).edit().putString("keys", json).apply()
  }

  fun token(context: Context): String? = prefs(context).getString("token", null)

  fun setToken(context: Context, token: String) {
    prefs(context).edit().putString("token", token).apply()
  }

  private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    return mac.doFinal(data)
  }

  /** `CompanionSeal.open` for the Mac → phone direction: HKDF-SHA256 (salt "nook-companion", info "v1") and ChaCha20-Poly1305. */
  fun open(device: String, sealed: String, pushKey: ByteArray): ByteArray? {
    return try {
      val prk = hmac("nook-companion".toByteArray(), pushKey)
      val key = hmac(prk, "v1".toByteArray() + byteArrayOf(1)).copyOf(32)
      val combined = Base64.decode(sealed, Base64.DEFAULT)
      if (combined.size <= 28) return null
      val cipher = Cipher.getInstance("ChaCha20-Poly1305")
      cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(combined.copyOfRange(0, 12)))
      cipher.updateAAD("$device|r".toByteArray())
      cipher.doFinal(combined.copyOfRange(12, combined.size))
    } catch (e: Exception) {
      null
    }
  }

  /** The notification for one sealed push, or nothing when no key opens it. */
  fun show(context: Context, device: String, sealed: String) {
    val keys = JSONArray(prefs(context).getString("keys", "[]"))
    var content: JSONObject? = null
    for (i in 0 until keys.length()) {
      val entry = keys.getJSONObject(i)
      val plain = open(device, sealed, Base64.decode(entry.getString("key"), Base64.DEFAULT)) ?: continue
      content = JSONObject(String(plain))
      if (!content.has("mac")) content.put("mac", entry.getString("mac"))
      break
    }
    val c = content ?: return
    ensureChannel(context)
    val session = c.optString("session")
    val item = c.optString("item").ifEmpty { null }
    val mac = c.optString("mac")
    val id = (c.optString("thread").ifEmpty { session }).hashCode()
    val builder = NotificationCompat.Builder(context, CHANNEL)
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentTitle(c.optString("title", "Nook"))
      .setContentText(c.optString("body"))
      .setStyle(NotificationCompat.BigTextStyle().bigText(c.optString("body")))
      .setAutoCancel(true)
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setGroup(c.optString("thread"))
      .setContentIntent(intent(context, id * 10, "open", mac, session, item))
    when (c.optString("category")) {
      "NOOK_APPROVAL_ALLOW" -> {
        builder.addAction(0, context.getString(R.string.push_deny), intent(context, id * 10 + 1, "deny", mac, session, item))
        builder.addAction(0, context.getString(R.string.push_allow), intent(context, id * 10 + 2, "allow", mac, session, item))
      }
      "NOOK_APPROVAL_DENY" ->
        builder.addAction(0, context.getString(R.string.push_deny), intent(context, id * 10 + 1, "deny", mac, session, item))
      "NOOK_INFO" -> {
        val input = RemoteInput.Builder(REPLY_KEY).setLabel(context.getString(R.string.push_reply_hint)).build()
        val action = NotificationCompat.Action.Builder(0, context.getString(R.string.push_reply), intent(context, id * 10 + 3, "reply", mac, session, item, mutable = true))
          .addRemoteInput(input)
          .build()
        builder.addAction(action)
      }
    }
    try {
      NotificationManagerCompat.from(context).notify(id, builder.build())
    } catch (e: SecurityException) {
      // Notifications are not allowed: nothing to show.
    }
  }

  /** What a tap or a button does: the app opens and does it (`nook-notification` in src/lib/mobile.ts). */
  private fun intent(context: Context, code: Int, action: String, mac: String, session: String, item: String?, mutable: Boolean = false): PendingIntent {
    val open = Intent(context, MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      putExtra(EXTRA_ACTION, action)
      putExtra(EXTRA_MAC, mac)
      putExtra(EXTRA_SESSION, session)
      putExtra(EXTRA_ITEM, item)
    }
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (mutable && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE)
    return PendingIntent.getActivity(context, code, open, flags)
  }

  fun ensureChannel(context: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    if (manager.getNotificationChannel(CHANNEL) != null) return
    manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.push_channel), NotificationManager.IMPORTANCE_HIGH))
  }

  /** What a notification asked the app to do, as JSON for the interface; null for an intent from elsewhere. */
  fun actionJson(intent: Intent?): String? {
    val action = intent?.getStringExtra(EXTRA_ACTION) ?: return null
    val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_KEY)?.toString()
    val json = JSONObject()
      .put("action", action)
      .put("mac", intent.getStringExtra(EXTRA_MAC) ?: "")
      .put("session", intent.getStringExtra(EXTRA_SESSION) ?: "")
      .put("item", intent.getStringExtra(EXTRA_ITEM) ?: JSONObject.NULL)
      .put("text", reply ?: JSONObject.NULL)
    intent.removeExtra(EXTRA_ACTION)
    return json.toString()
  }
}

/** Receives Firebase's messages and new tokens. */
class NookMessagingService : FirebaseMessagingService() {
  override fun onNewToken(token: String) {
    NookPush.setToken(this, token)
    MainActivity.current?.pushTokenChanged()
  }

  override fun onMessageReceived(message: RemoteMessage) {
    val device = message.data["nook-sealed-d"] ?: return
    val sealed = message.data["nook-sealed-s"] ?: return
    NookPush.show(this, device, sealed)
  }
}
