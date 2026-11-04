package me.jxl.kiosk_satellite

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
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
 * The Doorbell click rides the same channel: Dart asks here to launch the
 * saved doorbell app and start DoorbellClickService's click job or teach
 * window, and the service's results are pushed back the same way.
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
        private const val CLICK_DELAY_DEFAULT_SECONDS = 8L
        private const val CLICK_DELAY_MAX_SECONDS = 120L
        private const val CLICK_WINDOW_DEFAULT_SECONDS = 15L
        private const val CLICK_WINDOW_MIN_SECONDS = 5L
        private const val CLICK_WINDOW_MAX_SECONDS = 60L
        private const val CLICK_CAPTURE_DEFAULT_SECONDS = 90

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
            bridge.onCaptured(pkg, channelId, title, appLabel)
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
    private var captureOpen = false

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
                    "clickServiceRunning" -> result.success(
                        DoorbellClickService.running,
                    )
                    "openClickSettings" -> result.success(openClickSettings())
                    "configureClick" -> result.success(
                        configureClick(call.argument<Any?>("packages")),
                    )
                    "launchAndClick" -> result.success(launchAndClick(call))
                    "startClickCapture" -> result.success(startClickCapture(call))
                    "stopClickCapture" -> {
                        DoorbellClickService.instance?.stopCapture()
                        result.success(true)
                    }
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
        captureOpen = true
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
        captureOpen = false
    }

    /** Main thread only. True from startCapture until the window is closed
     *  by its timeout, by stopCapture or by the notification it caught. The
     *  flag is the one truth, so no clock can disagree with the token. */
    private fun isCaptureWindowOpen(): Boolean = captureOpen

    /** Open Android's Accessibility settings, where the owner enables the
     *  Doorbell click once. False when Android refuses the start. */
    private fun openClickSettings(): Boolean {
        return try {
            context.startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Save the doorbell packages the click service may read, and widen its
     *  event filter to them. */
    private fun configureClick(raw: Any?): Boolean {
        DoorbellClickService.configure(
            (raw as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
        )
        return true
    }

    /** Launch the saved doorbell app fresh and start the click job for its
     *  camera card. True when the launch started; the job's result then
     *  arrives as a "clickResult" push, "service_off" at once when the
     *  click service is not enabled. False when there is no launch intent
     *  or Android refused it. */
    private fun launchAndClick(call: MethodCall): Boolean {
        val pkg = call.argument<String>("package")
            ?: throw IllegalArgumentException("package is required")
        val label = call.argument<String>("label")
            ?: throw IllegalArgumentException("label is required")
        val delaySeconds = (call.argument<Number>("delaySeconds")?.toLong()
            ?: CLICK_DELAY_DEFAULT_SECONDS).coerceIn(0L, CLICK_DELAY_MAX_SECONDS)
        val windowSeconds = (call.argument<Number>("windowSeconds")?.toLong()
            ?: CLICK_WINDOW_DEFAULT_SECONDS).coerceIn(
                CLICK_WINDOW_MIN_SECONDS,
                CLICK_WINDOW_MAX_SECONDS,
            )
        val started = launchFresh(pkg)
        if (started) {
            if (DoorbellClickService.running) {
                DoorbellClickService.instance?.startClick(
                    pkg,
                    label,
                    delaySeconds * 1000,
                    windowSeconds * 1000,
                ) { r ->
                    push(
                        "clickResult",
                        mapOf("package" to pkg, "label" to label, "result" to r),
                    )
                }
            } else {
                push(
                    "clickResult",
                    mapOf("package" to pkg, "label" to label, "result" to "service_off"),
                )
            }
        }
        return started
    }

    /** Launch the doorbell app and open the window that learns the saved
     *  card's label from the one you tap. False when the click service is
     *  not enabled or the launch failed; the label arrives as a
     *  "clickCaptured" push and the window's end as "clickCaptureEnded". */
    private fun startClickCapture(call: MethodCall): Boolean {
        val pkg = call.argument<String>("package")
            ?: throw IllegalArgumentException("package is required")
        val seconds =
            call.argument<Number>("seconds")?.toInt() ?: CLICK_CAPTURE_DEFAULT_SECONDS
        if (!DoorbellClickService.running) return false
        if (!launchFresh(pkg)) return false
        DoorbellClickService.instance?.startCapture(
            pkg,
            seconds,
            onCaptured = { label ->
                push("clickCaptured", mapOf("package" to pkg, "label" to label))
            },
            onEnded = { reason ->
                push("clickCaptureEnded", mapOf("reason" to reason))
            },
        )
        return true
    }

    /** Launch [pkg] at its home screen. False when there is no launch
     *  intent or Android refuses the start. */
    private fun launchFresh(pkg: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        // CLEAR_TASK restarts the app at its home screen, so the card is
        // where the saved label expects it.
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "launch failed: ${e.javaClass.simpleName}")
            false
        }
    }

    /** Send the held tap action. False when there is none, or Android
     *  refuses it. */
    private fun fire(key: String): Boolean {
        val held = taps.remove(key) ?: return false
        // A tap Dart asks for after the hold is over is refused, the same as
        // one that was purged.
        if (SystemClock.elapsedRealtime() - held.second > KEEP_MS) return false
        val tap = held.first
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
