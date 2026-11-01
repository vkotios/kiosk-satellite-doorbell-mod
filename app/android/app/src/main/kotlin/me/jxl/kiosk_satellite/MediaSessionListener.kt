package me.jxl.kiosk_satellite

import android.app.Notification
import android.os.Build
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * The component Android's "Notification access" grant names. Android only
 * lists other apps' media sessions to an app whose listener is enabled
 * (MediaSessionManager.getActiveSessions), so the Media Session player
 * source follows other apps through [MediaSessionBridge].
 *
 * It also looks at notifications from one hard-coded package, the Eufy
 * Security app, and hands the tap action of a ring notification to
 * [DoorbellBridge], so the right doorbell's live view can open over the
 * kiosk. A notification from any other app is dropped on the first line,
 * never read, stored or reported.
 */
class MediaSessionListener : NotificationListenerService() {
    companion object {
        private const val TAG = "Doorbell"
        private const val PACKAGE = "com.oceanwing.battery.cam"
        private const val CHANNEL_PREFIX = "com.ocean.battery.cam.ring"
        // Android reposts a ring a few seconds after it first posts it.
        private const val DEDUPE_MS = 20_000L
    }

    // Main thread only: listener callbacks arrive there.
    private val handledAt = HashMap<String, Long>()

    // The system binds the listener once the grant lands, which is the
    // moment the sessions become readable.
    override fun onListenerConnected() {
        MediaSessionBridge.accessChanged()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName != PACKAGE) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notification = sbn.notification
        val channel = notification.channelId ?: return
        if (!channel.startsWith(CHANNEL_PREFIX)) return

        val now = SystemClock.elapsedRealtime()
        handledAt.values.removeAll { now - it > 60_000L }
        val last = handledAt[sbn.key]
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        if (last != null && now - last < DEDUPE_MS) {
            Log.i(TAG, "repost ignored: '$title' ${now - last} ms after the first post")
            return
        }
        handledAt[sbn.key] = now

        val tap = notification.contentIntent
        if (tap == null) {
            Log.w(TAG, "ring '$title' has no tap action")
            return
        }
        if (DoorbellBridge.ring(sbn.packageName, sbn.key, title, tap)) {
            Log.i(TAG, "ring '$title': handed to the app, key ${sbn.key}")
        } else {
            Log.w(TAG, "ring '$title' dropped: the app is not up yet")
        }
    }
}
