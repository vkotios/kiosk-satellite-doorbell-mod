package me.jxl.kiosk_satellite

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The doorbell hand-off between [MediaSessionListener] and Dart.
 *
 * The listener sees a ring notification and holds its tap action here. Dart
 * decides whether to act on it (the setting, the screen, the pin) and then
 * asks for the tap by the notification's key, so opening the other app goes
 * through the same steps every other launch over the kiosk takes. A tap
 * Dart does not ask for within [KEEP_MS] is dropped.
 */
class DoorbellBridge(
    context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val TAG = "DoorbellBridge"
        private const val KEEP_MS = 60_000L

        @Volatile
        private var instance: DoorbellBridge? = null

        /** A matched ring. False while Dart is not up to take it. */
        fun ring(pkg: String, key: String, title: String, tap: PendingIntent): Boolean {
            val bridge = instance ?: return false
            bridge.main.post { bridge.onRing(pkg, key, title, tap) }
            return true
        }
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "kiosk_satellite/doorbell")

    // Main thread only.
    private val taps = HashMap<String, Pair<PendingIntent, Long>>()

    init {
        instance = this
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "fire" -> result.success(fire(call.argument<String>("key") ?: ""))
                else -> result.notImplemented()
            }
        }
    }

    private fun onRing(pkg: String, key: String, title: String, tap: PendingIntent) {
        val now = SystemClock.elapsedRealtime()
        taps.values.removeAll { now - it.second > KEEP_MS }
        taps[key] = tap to now
        try {
            channel.invokeMethod("ring", mapOf("package" to pkg, "key" to key, "title" to title))
        } catch (e: Exception) {
            Log.w(TAG, "ring push failed: ${e.message}")
        }
    }

    /** Send the held tap action. False when there is none, or Android
     *  refuses it. */
    private fun fire(key: String): Boolean {
        val tap = taps.remove(key)?.first ?: return false
        return try {
            val options = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14 asks the sender to opt in to a background start.
                ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                ).toBundle()
            } else {
                null
            }
            tap.send(context, 0, null, null, null, null, options)
            true
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "tap action was cancelled: ${e.message}")
            false
        } catch (e: Exception) {
            Log.w(TAG, "tap action failed: $e")
            false
        }
    }
}
