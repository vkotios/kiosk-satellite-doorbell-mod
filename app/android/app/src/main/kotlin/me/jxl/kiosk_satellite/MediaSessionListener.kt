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
 * Other notifications are looked at only by package, channel and flags;
 * their title and extras are read only for a saved doorbell's ring, or
 * during the capture window the user starts, and are never stored or logged. A
 * matched ring's tap action goes to [DoorbellBridge], so the right
 * doorbell's live view can open over the kiosk.
 */
class MediaSessionListener : NotificationListenerService() {
    companion object {
        private const val TAG = "Doorbell"
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
        try {
            handlePosted(sbn)
        } catch (e: Exception) {
            // Only the class name: the message could carry notification text.
            Log.w(TAG, "notification skipped: ${e.javaClass.simpleName}")
        }
    }

    private fun handlePosted(sbn: StatusBarNotification) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notification = sbn.notification
        val channel = notification.channelId
        if (DoorbellBridge.capturing()) {
            // The window reports the next notification from another app,
            // once, and never also treats it as a ring.
            if (sbn.packageName == applicationContext.packageName) return
            if (channel == null) return
            if (notification.flags and Notification.FLAG_ONGOING_EVENT != 0) return
            if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
            val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            DoorbellBridge.capture(sbn.packageName, channel, title, appLabel(sbn.packageName))
            return
        }
        val signature = DoorbellBridge.match(sbn.packageName, channel)
        if (signature == null) return

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
        if (DoorbellBridge.ring(sbn.packageName, sbn.key, title, signature.id, tap)) {
            Log.i(TAG, "ring '$title': handed to the app, key ${sbn.key}")
        } else {
            Log.w(TAG, "ring '$title' dropped: the app is not up yet")
        }
    }

    /** The other app's label, or its package name when it has none. */
    private fun appLabel(pkg: String): String {
        return try {
            val info = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(info)?.toString() ?: pkg
        } catch (e: Exception) {
            pkg
        }
    }
}
