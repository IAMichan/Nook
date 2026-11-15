package nl.imdigital.nook

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.activity.enableEdgeToEdge
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONObject
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging

/**
 * Nook op Android. Bovenop Tauri twee dingen voor de interface (src/lib/mobile.ts):
 * - veilige marges (statusbalk, notch, gebarenbalk) en de hoogte van het toetsenbord, als CSS-pixels;
 * - "Delen met Nook": tekst die een andere app deelt, wordt een nieuwe vraag.
 * Beide via `window.NookAndroid` en de events `nook-insets` en `nook-share`.
 * Zolang de app voor staat mag hij multicast ontvangen, zodat de companion een Mac of pc als `naam.local` (mDNS) vindt.
 * Dictation for the companion's composers (as the iPhone's `Dictation`): Android's speech recognizer, on the device
 * itself where it can, with the words as event `nook-dictation`; no audio ever leaves for the computer.
 */
class MainActivity : TauriActivity() {
  private var webView: WebView? = null
  @Volatile private var insetsJson = "{\"top\":0,\"bottom\":0,\"left\":0,\"right\":0,\"keyboard\":0}"
  @Volatile private var shared: String? = null
  @Volatile private var link: String? = null
  @Volatile private var notification: String? = null
  private var multicast: WifiManager.MulticastLock? = null
  private var recognizer: SpeechRecognizer? = null
  private var pendingLanguage: String? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    current = this
    takeShare(intent)
    takeLink(intent)
    notification = NookPush.actionJson(intent)
    NookPush.ensureChannel(this)
    fetchPushToken()
  }

  override fun onResume() {
    super.onResume()
    val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    multicast = multicast ?: wifi?.createMulticastLock("nook-companion")?.apply { setReferenceCounted(false) }
    multicast?.acquire()
  }

  override fun onPause() {
    multicast?.release()
    stopDictation()
    super.onPause()
  }

  private fun dictationEvent(state: String, text: String = "", onDevice: Boolean = false) {
    val json = JSONObject().put("state", state).put("text", text).put("onDevice", onDevice).toString()
    webView?.post {
      webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-dictation', { detail: ${JSONObject.quote(json)} }))", null)
    }
  }

  /** Starts listening in `language` (a BCP 47 tag, empty for the phone's own). Asks for the microphone first. */
  private fun startDictation(language: String) {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      pendingLanguage = language
      ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), DICTATION_PERMISSION)
      return
    }
    if (!SpeechRecognizer.isRecognitionAvailable(this)) {
      dictationEvent("error", "unavailable")
      return
    }
    stopDictation()
    val onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
    val made = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(this) else SpeechRecognizer.createSpeechRecognizer(this)
    recognizer = made
    made.setRecognitionListener(object : RecognitionListener {
      override fun onReadyForSpeech(params: Bundle?) { dictationEvent("listening", "", onDevice) }
      override fun onBeginningOfSpeech() {}
      override fun onRmsChanged(rmsdB: Float) {}
      override fun onBufferReceived(buffer: ByteArray?) {}
      override fun onEndOfSpeech() {}
      override fun onError(error: Int) {
        dictationEvent(if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) "end" else "error", error.toString())
        recognizer?.destroy()
        recognizer = null
      }
      override fun onResults(results: Bundle?) {
        val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        dictationEvent("final", text, onDevice)
        dictationEvent("end")
        recognizer?.destroy()
        recognizer = null
      }
      override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        if (text.isNotEmpty()) dictationEvent("partial", text, onDevice)
      }
      override fun onEvent(eventType: Int, params: Bundle?) {}
    })
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
      if (language.isNotEmpty()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
    }
    made.startListening(intent)
  }

  private fun stopDictation() {
    recognizer?.stopListening()
    recognizer?.destroy()
    recognizer = null
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode != DICTATION_PERMISSION) return
    val language = pendingLanguage
    pendingLanguage = null
    if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && language != null) startDictation(language)
    else dictationEvent("error", "permission")
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    if (takeShare(intent)) {
      webView?.post { webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-share'))", null) }
    }
    if (takeLink(intent)) {
      webView?.post { webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-link'))", null) }
    }
    NookPush.actionJson(intent)?.let { json ->
      notification = json
      webView?.post { webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-notification'))", null) }
    }
  }

  override fun onWebViewCreate(webView: WebView) {
    super.onWebViewCreate(webView)
    this.webView = webView
    webView.addJavascriptInterface(Bridge(), "NookAndroid")
    ViewCompat.setOnApplyWindowInsetsListener(webView) { view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
      val density = view.resources.displayMetrics.density
      // Vanaf de onderkant van het scherm: met het toetsenbord open verbergt de interface de navigatie onderaan.
      val keyboard = if (insets.isVisible(WindowInsetsCompat.Type.ime())) ime.bottom else 0
      val json = JSONObject()
        .put("top", (bars.top / density).toDouble())
        .put("bottom", (bars.bottom / density).toDouble())
        .put("left", (bars.left / density).toDouble())
        .put("right", (bars.right / density).toDouble())
        .put("keyboard", (keyboard / density).toDouble())
        .toString()
      if (json != insetsJson) {
        insetsJson = json
        view.post {
          (view as WebView).evaluateJavascript(
            "window.dispatchEvent(new CustomEvent('nook-insets', { detail: ${JSONObject.quote(json)} }))", null)
        }
      }
      insets
    }
    ViewCompat.requestApplyInsets(webView)
  }

  override fun onDestroy() {
    if (current === this) current = null
    super.onDestroy()
  }

  /** Asks Firebase for this phone's token, when the app carries a Firebase configuration (google-services.json). */
  private fun fetchPushToken() {
    if (FirebaseApp.getApps(this).isEmpty()) return
    try {
      FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
        if (token != null && token != NookPush.token(this)) {
          NookPush.setToken(this, token)
          pushTokenChanged()
        }
      }
    } catch (e: Exception) {
      // Without Google Play services there is no token: notifications only while the app runs.
    }
  }

  /** Tells the interface there is a (new) token to give the paired computers. */
  fun pushTokenChanged() {
    webView?.post { webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-push-token'))", null) }
  }

  /** Keeps a nook:// link the app was opened with (a pairing code, a prompt link); true when there was one. */
  private fun takeLink(intent: Intent?): Boolean {
    if (intent?.action != Intent.ACTION_VIEW) return false
    val data = intent.dataString ?: return false
    if (!data.startsWith("nook://", ignoreCase = true) || data.length > 20000) return false
    link = data
    intent.action = null
    return true
  }

  /** Bewaart gedeelde tekst (ACTION_SEND, text/plain); waar als er iets was. */
  private fun takeShare(intent: Intent?): Boolean {
    if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return false
    val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
    val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
    val combined = listOf(subject, text).filter { it.isNotEmpty() }.distinct().joinToString("\n")
    if (combined.isEmpty()) return false
    // Begrensd zoals een concept; de rest van de tekst blijft in de andere app.
    shared = combined.take(8000)
    intent.action = null
    return true
  }

  private inner class Bridge {
    @JavascriptInterface
    fun insets(): String = insetsJson

    @JavascriptInterface
    fun dictate(language: String) {
      runOnUiThread { startDictation(language) }
    }

    @JavascriptInterface
    fun stopDictating() {
      runOnUiThread { stopDictation() }
    }

    @JavascriptInterface
    fun pushToken(): String? = NookPush.token(this@MainActivity)

    @JavascriptInterface
    fun setPushKeys(json: String) {
      NookPush.setKeys(this@MainActivity, json)
    }

    @JavascriptInterface
    fun takeNotification(): String? {
      val text = notification
      notification = null
      return text
    }

    @JavascriptInterface
    fun takeLink(): String? {
      val text = link
      link = null
      return text
    }

    @JavascriptInterface
    fun takeShared(): String? {
      val text = shared
      shared = null
      return text
    }
  }

  companion object {
    private const val DICTATION_PERMISSION = 4711
    /** The activity that runs now, for the messaging service to reach the interface. */
    @Volatile var current: MainActivity? = null
  }
}
