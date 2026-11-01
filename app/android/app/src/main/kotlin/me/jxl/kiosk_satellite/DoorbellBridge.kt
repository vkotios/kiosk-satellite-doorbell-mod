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
 * Dart pushes the signatures the listener matches against, and the listener
 * holds a matched ring's tap action here. Dart decides whether to act on
 * the ring (the setting, the screen, the pin) and then asks for the tap by
 * the notification's key, so opening the other app goes through the same
 * steps every other launch over the kiosk takes. A tap Dart does not ask
 * for within [KEEP_MS] is dropped. Dart can also open a capture window,
 * during which the listener reports the next notification from another app
 * instead of matching a ring.
 */
class DoorbellBridge(
    context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val TAG = "DoorbellBridge"
        private const val KEEP_MS = 60_000L
        private const val CAPTURE_MIN_SECONDS = 5L
        private const val CAPTURE_MAX_SECONDS = 120L
        private const val CAPTURE_DEFAULT_SECONDS = 60L

        @Volatile
        private var instance: DoorbellBridge? = null

        /** A matched ring. False while Dart is not up to take it. */
        fun ring(
            pkg: String,
            key: String,
            title: String,
            signatureId: String,
            tap: PendingIntent,
        ): Boolean {
            val bridge = instance ?: return false
            bridge.main.post { bridge.onRing(pkg, key, title, signatureId, tap) }
            return true
        }

        /** The signature Dart would call a ring, over the list it last
         *  configured. Null while none matches, or while no bridge is up yet.
         *  The listener calls this on the main thread, where the list lives. */
        fun match(pkg: String, channelId: String?): DoorbellSignature? {
            val bridge = instance ?: return null
            return DoorbellMatcher.match(bridge.signatures, pkg, channelId)
        }

        /** True while a capture window Dart started is still open. The
         *  listener calls this on the main thread, where the window lives. */
        fun capturing(): Boolean {
            val bridge = instance ?: return false
            return bridge.isCaptureWindowOpen()
        }

        /** Report this notification as the one the window waited for, and
         *  close the window at once. Must be called on the main thread, where
         *  the listener callbacks arrive. False while no window is open. */
        fun capture(pkg: String, channelId: String, title: String, appLabel: String): Boolean {
            val bridge = instance ?: return false
            if (!bridge.isCaptureWindowOpen()) return false
            bridge.closeCapture()
            bridge.main.post { bridge.onCaptured(pkg, channelId, title, appLabel) }
            return true
        }
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "kiosk_satellite/doorbell")

    // Main thread only.
    private val taps = HashMap<String, Pair<PendingIntent, Long>>()

    // Main thread only: the signatures Dart last configured.
    private val signatures = ArrayList<DoorbellSignature>()

    // Main thread only: the open capture window. [captureToken] changes on
    // every start and every end of a window, so a timeout left over from an
    // earlier window cannot end a later one.
    private var captureToken = 0
    private var captureDeadline = 0L

    init {
        instance = this
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "fire" -> result.success(fire(call.argument<String>("key") ?: ""))
                    "configure" -> result.success(configure(call.argument<Any?>("signatures")))
                    "startCapture" -> result.success(
                        startCapture(call.argument<Number>("seconds")),
                    )
                    "stopCapture" -> result.success(stopCapture())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("bad_arguments", e.message, null)
            }
        }
    }

    private fun onRing(pkg: String, key: String, title: String, signatureId: String, tap: PendingIntent) {
        val now = SystemClock.elapsedRealtime()
        taps.values.removeAll { now - it.second > KEEP_MS }
        taps[key] = tap to now
        try {
            channel.invokeMethod(
                "ring",
                mapOf("package" to pkg, "key" to key, "title" to title, "signatureId" to signatureId),
            )
        } catch (e: Exception) {
            Log.w(TAG, "ring push failed: ${e.message}")
        }
    }

    /** Send [method] to Dart, which may not be up to take it. */
    private fun push(method: String, arguments: Map<String, String>) {
        try {
            channel.invokeMethod(method, arguments)
        } catch (e: Exception) {
            Log.w(TAG, "$method push failed: ${e.message}")
        }
    }

    /** Replace the saved signatures with the ones Dart pushes. A map without
     *  a usable id, package or channelPrefix is skipped. */
    private fun configure(raw: Any?): Boolean {
        signatures.clear()
        val list = raw as? List<*> ?: return true
        for (item in list) {
            val map = item as? Map<*, *> ?: continue
            var id: String? = null
            var label: String? = null
            var pkg: String? = null
            var channelPrefix: String? = null
            for ((key, value) in map) {
                when (key) {
                    "id" -> id = value as? String
                    "label" -> label = value as? String
                    "package" -> pkg = value as? String
                    "channelPrefix" -> channelPrefix = value as? String
                }
            }
            if (id.isNullOrBlank() || pkg.isNullOrBlank() || channelPrefix.isNullOrBlank()) continue
            signatures.add(DoorbellSignature(id, label ?: "", pkg, channelPrefix))
        }
        return true
    }

    /** Open the capture window for [seconds], clamped to
     *  [CAPTURE_MIN_SECONDS]..[CAPTURE_MAX_SECONDS]; a missing [seconds]
     *  means [CAPTURE_DEFAULT_SECONDS]. Starting again restarts the window. */
    private fun startCapture(seconds: Number?): Boolean {
        val windowMs = (seconds?.toLong() ?: CAPTURE_DEFAULT_SECONDS)
            .coerceIn(CAPTURE_MIN_SECONDS, CAPTURE_MAX_SECONDS) * 1000
        captureToken++
        captureDeadline = SystemClock.uptimeMillis() + windowMs
        val token = captureToken
        main.postDelayed({
            if (captureToken == token) {
                closeCapture()
                push("captureEnded", mapOf("reason" to "timeout"))
            }
        }, windowMs)
        return true
    }

    /** End the capture window. The end is reported only when one was open. */
    private fun stopCapture(): Boolean {
        if (isCaptureWindowOpen()) {
            closeCapture()
            push("captureEnded", mapOf("reason" to "stopped"))
        }
        return true
    }

    /** Main thread only. Report the notification that ended the window the
     *  caller already closed. */
    private fun onCaptured(pkg: String, channelId: String, title: String, appLabel: String) {
        push(
            "captured",
            mapOf(
                "package" to pkg,
                "channelId" to channelId,
                "channelPrefix" to DoorbellMatcher.channelPrefixOf(channelId),
                "title" to title,
                "appLabel" to appLabel,
            ),
        )
        push("captureEnded", mapOf("reason" to "caught"))
    }

    /** Main thread only. Close the window; the caller reports the reason. */
    private fun closeCapture() {
        captureToken++
        captureDeadline = 0L
    }

    /** Main thread only. False once the window's deadline has passed. */
    private fun isCaptureWindowOpen(): Boolean = SystemClock.uptimeMillis() < captureDeadline

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
