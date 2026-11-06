package me.jxl.kiosk_satellite

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The Doorbell click: an accessibility service that taps the camera card
 * of the doorbell app you saved, or learns that card's label from the one
 * you tap yourself.
 *
 * Dart drives it through [DoorbellBridge]: a ring asks the bridge to
 * launch the doorbell app fresh and start a click job here; the job waits
 * out the launch, then walks the app's window for the node whose text
 * matches the saved label and clicks it (or its nearest clickable
 * ancestor). The teach step is a capture window: the next card you tap in
 * the doorbell app is reported as the label to save.
 *
 * Privacy: window content is read only while a click job or a capture is
 * running, and only from the saved doorbell packages, plus the one
 * package a teach capture is open for (teach runs before save).
 * [applyScope] keeps Android's event filter at exactly those packages,
 * and [onAccessibilityEvent] drops every other event on its first line.
 * The only text this service ever logs is the saved label, with the
 * job's result. The names of the clickable things a failed test
 * reports to the owner are never logged either.
 */
class DoorbellClickService : AccessibilityService() {
    companion object {
        private const val TAG = "DoorbellClick"

        /** Bound and live. The system binds enabled accessibility services
         *  for as long as the process runs, so this doubles as "the owner
         *  has enabled the Doorbell click in Accessibility settings". */
        @Volatile
        var running = false
            private set

        /** The connected service, the host of the click jobs and captures. */
        @Volatile
        var instance: DoorbellClickService? = null
            private set

        /** The saved doorbell packages Dart last configured. */
        @Volatile
        var packages: Set<String> = emptySet()
            private set

        /** Save the doorbell packages the service may read, and widen its
         *  event filter to them. */
        fun configure(list: Collection<String>) {
            packages = list.filter { it.isNotBlank() }.toSet()
            instance?.applyScope()
        }
    }

    private val main = Handler(Looper.getMainLooper())

    // Main thread only: the open capture window. [captureToken] changes on
    // every start and every end of a window, so a timeout left over from an
    // earlier window cannot end a later one.
    private var captureToken = 0
    private var captureOpen = false
    private var capturePkg: String? = null
    private var captureOnCaptured: ((String) -> Unit)? = null
    private var captureOnEnded: ((String) -> Unit)? = null

    // Main thread only: the running click job, invalidated the same way as
    // the capture token.
    private var jobToken = 0

    // Main thread only: the running job's result callback, so a service
    // that dies mid-job still reports "service_off". Cleared when the
    // job reports; a job replaced by a new startClick reports nothing.
    private var jobOnResult: ((String, List<String>) -> Unit)? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        running = true
        instance = this
        applyScope()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        disconnected()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        disconnected()
        super.onDestroy()
    }

    /** The service is gone: forget the statics, cancel the job and the
     *  capture, and report the running job's "service_off" and the
     *  capture's end to Dart. */
    private fun disconnected() {
        if (instance === this) {
            running = false
            instance = null
        }
        val onResult = jobOnResult
        if (onResult != null) {
            jobOnResult = null
            Log.i(TAG, "click: service_off")
            onResult("service_off", emptyList())
        }
        cancelClick()
        if (captureOpen) {
            val onEnded = captureOnEnded
            closeCapture()
            onEnded?.invoke("service_off")
        }
    }

    /** Keep Android's event filter at the saved doorbell packages, or at
     *  only this app's own package while there are none, so no other app's
     *  content is ever delivered here. While a capture is open, the package
     *  it is taught in is in the filter too, saved or not: teach runs
     *  before save. */
    fun applyScope() {
        val info = serviceInfo ?: return
        val openPkg = if (captureOpen) capturePkg else null
        val scope =
            if (openPkg != null) {
                packages + openPkg
            } else if (packages.isEmpty()) {
                setOf(packageName)
            } else {
                packages
            }
        info.packageNames = scope.toTypedArray()
        serviceInfo = info
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        // Window content is read only while a capture is open, and only
        // from the package that capture is for; every other event dies on
        // this first line.
        if (!captureOpen) return
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_CLICKED) return
        val pkg = capturePkg ?: return
        if (event.packageName?.toString() != pkg) return
        try {
            val source = event.source ?: return
            val label = LabelMatcher.bestLabel(NodeWalker.capturedTexts(NodeAdapter(source)))
            // No label on this click: keep waiting, the user may tap again.
            if (label == null) return
            val onCaptured = captureOnCaptured
            val onEnded = captureOnEnded
            closeCapture()
            onCaptured?.invoke(label)
            onEnded?.invoke("caught")
        } catch (_: Exception) {
            // A malformed or dead node: drop this click, the user may tap again.
        }
    }

    override fun onInterrupt() {}

    /** Open the teach window for [seconds] (clamped to 10..180): the next
     *  card you tap in [pkg] is reported through [onCaptured], and the
     *  window's end through [onEnded] ("caught", "timeout", "stopped" or
     *  "service_off"). A second call replaces the first window, which ends
     *  silently: a "stopped" report here would read in Dart as the new
     *  window's end. The event filter widens to [pkg] for the window,
     *  saved or not. Main thread only. */
    fun startCapture(
        pkg: String,
        seconds: Int,
        onCaptured: (String) -> Unit,
        onEnded: (String) -> Unit,
    ) {
        if (captureOpen) closeCapture()
        captureToken++
        captureOpen = true
        capturePkg = pkg
        captureOnCaptured = onCaptured
        captureOnEnded = onEnded
        val token = captureToken
        main.postDelayed(
            {
                if (captureToken == token) {
                    val ended = captureOnEnded
                    closeCapture()
                    ended?.invoke("timeout")
                }
            },
            seconds.coerceIn(10, 180) * 1000L,
        )
        applyScope()
    }

    /** End the open capture window, if any, with "stopped". Main thread
     *  only. */
    fun stopCapture() {
        if (captureOpen) {
            val onEnded = captureOnEnded
            closeCapture()
            onEnded?.invoke("stopped")
        }
    }

    /** Main thread only. Close the window; the caller reports the reason. */
    private fun closeCapture() {
        captureToken++
        captureOpen = false
        capturePkg = null
        captureOnCaptured = null
        captureOnEnded = null
        applyScope()
    }

    /** Start a click job: after [delayMs] (the launch settling), poll
     *  [pkg]'s window every 250 ms for [windowMs] for the card whose label
     *  is [label], and click it. [pkg] must be one of the saved
     *  [packages]: one that is not is refused at once with "not_found"
     *  and nothing is scheduled. One job at a time; a new job cancels the
     *  old one, which reports nothing: the new ring supersedes it. When
     *  [reportCards] is true, a "not_found" report also carries the
     *  names of the clickable things the doorbell's window showed, at
     *  most 12, for the owner who started the test; every other report
     *  carries an empty list, and the names are never logged. Main
     *  thread only. */
    fun startClick(
        pkg: String,
        label: String,
        delayMs: Long,
        windowMs: Long,
        reportCards: Boolean = false,
        onResult: (String, List<String>) -> Unit,
    ) {
        if (pkg !in packages) {
            Log.w(TAG, "click: package not saved")
            onResult("not_found", emptyList())
            return
        }
        cancelClick()
        jobOnResult = onResult
        val token = jobToken
        main.postDelayed({ pollClick(token, pkg, label, windowMs, reportCards, onResult) }, delayMs)
    }

    /** Cancel the running job, if any. It reports nothing. Main thread
     *  only. */
    fun cancelClick() {
        jobToken++
    }

    /** Main thread only. The job's poll loop: one [NodeWalker] search per
     *  250 ms tick until the card is clicked or the window runs out.
     *  When [reportCards] is true, the tick that searches the doorbell's
     *  window also collects its clickable names, and a "not_found"
     *  report that collected none walks once more. A tick that throws is
     *  treated as not clicked. Only the root is recycled, once per
     *  tick, after the tick is done with it; the nodes the walk read
     *  through getChild and getParent are left to the garbage
     *  collector. */
    @Suppress("DEPRECATION")
    private fun pollClick(
        token: Int,
        pkg: String,
        label: String,
        windowMs: Long,
        reportCards: Boolean,
        onResult: (String, List<String>) -> Unit,
    ) {
        if (jobToken != token) return
        var sawOtherApp = false
        var sawRightApp = false
        // The clickable names of the doorbell's window, from the tick
        // that last searched it; null until a tick collected them.
        var lastCards: List<String>? = null
        val until = SystemClock.uptimeMillis() + windowMs
        val tick = object : Runnable {
            override fun run() {
                if (jobToken != token) return
                if (SystemClock.uptimeMillis() >= until) {
                    val result = if (sawOtherApp && !sawRightApp) "wrong_app" else "not_found"
                    // The names come from the tick that last searched the
                    // doorbell's window; when no tick ever collected them,
                    // one more walk now is a "not_found" report's only
                    // chance to name what the window could show.
                    val cards =
                        if (reportCards && result == "not_found" && lastCards == null) {
                            readCards(pkg)
                        } else {
                            lastCards ?: emptyList()
                        }
                    reportClick(label, result, cards, onResult)
                    return
                }
                var clicked = false
                try {
                    val root = rootInActiveWindow
                    if (root == null || root.packageName?.toString() != pkg) {
                        // The doorbell app does not have the screen yet.
                        sawOtherApp = true
                    } else {
                        sawRightApp = true
                        val target =
                            NodeWalker.findClickTarget(NodeAdapter(root), label) as? NodeAdapter
                        if (target != null &&
                            target.info.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        ) {
                            clicked = true
                        }
                        if (reportCards && !clicked) {
                            // The names this window shows, for the report
                            // if the card never appears; collected in the
                            // same tick as the search, never logged.
                            lastCards = NodeWalker.clickableLabels(NodeAdapter(root))
                        }
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) root?.recycle()
                } catch (e: Exception) {
                    Log.w(TAG, "click poll failed: ${e.javaClass.simpleName}")
                }
                if (clicked) {
                    reportClick(label, "clicked", emptyList(), onResult)
                    return
                }
                main.postDelayed(this, 250)
            }
        }
        tick.run()
    }

    /** Main thread only. The clickable names in [pkg]'s window right
     *  now: the single extra walk a "not_found" report makes when no
     *  search tick ever collected names, because the doorbell's window
     *  never came up or the tick that saw it threw first. Empty when
     *  the window is not [pkg]'s. The names are never logged. */
    @Suppress("DEPRECATION")
    private fun readCards(pkg: String): List<String> {
        return try {
            val root = rootInActiveWindow
            val cards =
                if (root != null && root.packageName?.toString() == pkg) {
                    NodeWalker.clickableLabels(NodeAdapter(root))
                } else {
                    emptyList<String>()
                }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) root?.recycle()
            cards
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** Main thread only. Report [result] with [cards] for the job labelled
     *  [label] and end the job: its callback is forgotten first, so it
     *  never reports twice. The label is the only screen text this
     *  service ever logs; the card names never reach a log. */
    private fun reportClick(
        label: String,
        result: String,
        cards: List<String>,
        onResult: (String, List<String>) -> Unit,
    ) {
        jobOnResult = null
        Log.i(TAG, "click '$label': $result")
        onResult(result, cards)
    }

    /** The [ClickNode] over a real accessibility node, so [NodeWalker]
     *  stays free of Android types. Children and parent are read lazily:
     *  the walk may never ask for them. */
    private class NodeAdapter(val info: AccessibilityNodeInfo) : ClickNode {
        override val text = info.text?.toString()
        override val description = info.contentDescription?.toString()
        override val clickable = info.isClickable
        override val children: List<ClickNode> by lazy {
            (0 until info.childCount).mapNotNull { i ->
                info.getChild(i)?.let { NodeAdapter(it) }
            }
        }
        override val parent: ClickNode? by lazy { info.parent?.let { NodeAdapter(it) } }
    }
}
