package nl.imdigital.nook

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONObject

/**
 * Nook op Android. Bovenop Tauri twee dingen voor de interface (src/lib/mobile.ts):
 * - veilige marges (statusbalk, notch, gebarenbalk) en de hoogte van het toetsenbord, als CSS-pixels;
 * - "Delen met Nook": tekst die een andere app deelt, wordt een nieuwe vraag.
 * Beide via `window.NookAndroid` en de events `nook-insets` en `nook-share`.
 * Zolang de app voor staat mag hij multicast ontvangen, zodat de companion een Mac of pc als `naam.local` (mDNS) vindt.
 */
class MainActivity : TauriActivity() {
  private var webView: WebView? = null
  @Volatile private var insetsJson = "{\"top\":0,\"bottom\":0,\"left\":0,\"right\":0,\"keyboard\":0}"
  @Volatile private var shared: String? = null
  private var multicast: WifiManager.MulticastLock? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    takeShare(intent)
  }

  override fun onResume() {
    super.onResume()
    val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    multicast = multicast ?: wifi?.createMulticastLock("nook-companion")?.apply { setReferenceCounted(false) }
    multicast?.acquire()
  }

  override fun onPause() {
    multicast?.release()
    super.onPause()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    if (takeShare(intent)) {
      webView?.post { webView?.evaluateJavascript("window.dispatchEvent(new CustomEvent('nook-share'))", null) }
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
    fun takeShared(): String? {
      val text = shared
      shared = null
      return text
    }
  }
}
