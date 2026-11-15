package nl.imdigital.nook

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home screen widgets, as the iPhone's (`AgentActivityWidget`, `UsageWidget`): the agents that work or wait on you
 * (waiting ones first, at most five), and each account's plan limits. The app writes what they show whenever it takes
 * in a new list from the Mac (`NookAndroid.setWidgetData`); unfinished work reads as out of date ten minutes after the
 * app last heard from the Mac, since a closed app hears nothing. A row opens its session.
 */
object NookWidgets {
  private const val PREFS = "nook-widgets"
  private const val STALE_MS = 10 * 60 * 1000L
  private val rows = intArrayOf(R.id.row0, R.id.row1, R.id.row2, R.id.row3, R.id.row4)

  fun save(context: Context, json: String) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("data", json).apply()
    refresh(context)
  }

  fun refresh(context: Context) {
    val manager = AppWidgetManager.getInstance(context)
    for ((cls, agents) in listOf(AgentsWidget::class.java to true, LimitsWidget::class.java to false)) {
      val ids = manager.getAppWidgetIds(ComponentName(context, cls))
      for (id in ids) manager.updateAppWidget(id, views(context, agents))
    }
  }

  private fun data(context: Context): JSONObject =
    try {
      JSONObject(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("data", "{}") ?: "{}")
    } catch (e: Exception) {
      JSONObject()
    }

  private fun open(context: Context, code: Int, url: String): PendingIntent {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url), context, MainActivity::class.java)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    return PendingIntent.getActivity(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
  }

  fun views(context: Context, agents: Boolean): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.nook_widget)
    val data = data(context)
    val updated = data.optLong("updatedAt", 0L)
    val stale = updated > 0 && System.currentTimeMillis() - updated > STALE_MS
    views.setTextViewText(R.id.title, context.getString(if (agents) R.string.widget_agents_title else R.string.widget_limits_title))
    for (row in rows) views.setViewVisibility(row, View.GONE)
    var shown = 0
    if (agents) {
      val list = data.optJSONArray("agents")
      val mac = data.optString("mac")
      for (i in 0 until minOf(list?.length() ?: 0, rows.size)) {
        val a = list!!.getJSONObject(i)
        val word = if (stale && !a.optBoolean("waiting")) context.getString(R.string.widget_stale) else a.optString("word")
        val dot = if (a.optBoolean("waiting")) "● " else "○ "
        views.setTextViewText(rows[i], dot + a.optString("title") + "  ·  " + word)
        views.setViewVisibility(rows[i], View.VISIBLE)
        val url = "nook://companion/session?id=" + Uri.encode(a.optString("id")) + (if (mac.isNotEmpty()) "&mac=" + Uri.encode(mac) else "")
        views.setOnClickPendingIntent(rows[i], open(context, 100 + i, url))
        shown++
      }
    } else {
      val list = data.optJSONArray("limits")
      for (i in 0 until minOf(list?.length() ?: 0, rows.size)) {
        val l = list!!.getJSONObject(i)
        val resets = l.optLong("resetsAt", 0L) * 1000
        val reset = if (resets > 0) "  ·  " + DateUtils.getRelativeTimeSpanString(resets, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS) else ""
        views.setTextViewText(rows[i], l.optString("name") + "  " + l.optInt("percent") + "%" + reset)
        views.setViewVisibility(rows[i], View.VISIBLE)
        shown++
      }
    }
    views.setTextViewText(R.id.empty, if (shown == 0) context.getString(if (agents) R.string.widget_agents_empty else R.string.widget_limits_empty) else "")
    views.setViewVisibility(R.id.empty, if (shown == 0) View.VISIBLE else View.GONE)
    views.setTextViewText(
      R.id.footer,
      if (updated == 0L) "" else context.getString(R.string.widget_updated, DateUtils.getRelativeTimeSpanString(updated, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)),
    )
    views.setOnClickPendingIntent(R.id.widget_root, open(context, if (agents) 98 else 99, "nook://companion/agents"))
    return views
  }
}

class AgentsWidget : AppWidgetProvider() {
  override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
    for (id in ids) manager.updateAppWidget(id, NookWidgets.views(context, true))
  }
}

class LimitsWidget : AppWidgetProvider() {
  override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
    for (id in ids) manager.updateAppWidget(id, NookWidgets.views(context, false))
  }
}
