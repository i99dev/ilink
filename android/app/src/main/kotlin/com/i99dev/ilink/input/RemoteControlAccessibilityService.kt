package com.i99dev.ilink.input

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display.DEFAULT_DISPLAY
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.i99dev.ilink.connectivity.ConnectivityService
import com.i99dev.ilink.nav.NavHudOptions
import com.i99dev.ilink.nav.ingest.NavA11yDispatcher
import com.i99dev.ilink.nav.ingest.NavA11yReadPolicy
import com.i99dev.ilink.nav.ingest.WazeArrowBounds
import com.i99dev.ilink.nav.ingest.WazeCaptureGate
import com.i99dev.ilink.nav.ingest.WazeLaneBounds
import com.i99dev.ilink.voice.WheelVoiceController

/**
 * Bound `AccessibilityService` that exposes
 * `AccessibilityService.dispatchGesture(displayId)` to the Dart side
 * via the [InputPlatformPlugin] MethodChannel.
 *
 * Why an AccessibilityService instead of a regular service: only
 * AccessibilityService has access to `dispatchGesture`, which is the
 * only path for non-system apps to inject synthetic touch events on
 * a target display. Same mechanism i99dev's
 * `RemoteControlAccessibilityService` uses (per their decompiled
 * Companion singleton + `dispatchSwipe`/`dispatchTap` strings).
 *
 * Companion singleton: when Android creates the service instance it
 * calls [onServiceConnected] which stores the live instance in
 * [Companion.instance]. The MethodChannel handler reads that field
 * to reach the live service. If the user disabled accessibility (or
 * BYD's a11y panel forgot us), [Companion.instance] is null and the
 * MethodChannel handler returns `dispatched=false` with reason
 * `accessibility_disabled`.
 *
 * Display targeting: `GestureDescription` on API 30+ supports a
 * `displayId` via the builder. Pre-30 we fall back to the default
 * display (and the SDK side surfaces a typed
 * `displayId_unsupported` error — but minSdk on this app is API
 * 25 so this is a real fallback path).
 */
class RemoteControlAccessibilityService : AccessibilityService() {
    companion object {
        private const val TAG = "RemoteCtrlA11y"

        @Volatile
        var instance: RemoteControlAccessibilityService? = null
            private set

        /**
         * One-shot heartbeat the watchdog reads to detect that this
         * service has been alive recently. Updated on every gesture
         * dispatch and on `onServiceConnected`.
         */
        @Volatile
        var lastHeartbeatMs: Long = 0L
            private set

        /** Nav a11y re-read cadence (ms) — keeps distance/maneuver flowing when the
         *  nav app stops firing accessibility events. */
        private const val NAV_POLL_MS = 600L

        /**
         * The exact flag set declared in `res/xml/a11y_remote_control.xml`
         * (`flagRetrieveInteractiveWindows|flagReportViewIds|flagRequestMultiFingerGestures|flagRequestFilterKeyEvents`).
         *
         * Kept here purely so `onServiceConnected` can report which declared flags the
         * ROM did NOT hand back, rather than us guessing one bit at a time on-car.
         * Values confirmed against `android.jar` with `javap -constants`:
         * RETRIEVE_INTERACTIVE_WINDOWS 0x40, REPORT_VIEW_IDS 0x10,
         * REQUEST_FILTER_KEY_EVENTS 0x20, REQUEST_MULTI_FINGER_GESTURES 0x1000.
         * Sum = 0x1070 (4208) — that is what a ROM which preserved everything looks like.
         *
         * NOTE: `canRetrieveWindowContent` / `canPerformGestures` / `canRequestFilterKeyEvents`
         * are CAPABILITIES, not flags — they never appear in this word, so a correct
         * flags word does not on its own prove content retrieval is granted.
         *
         * If this ever diverges from the XML the log becomes misleading, so keep them
         * in step; the XML is the source of truth for what is actually requested.
         */
        private const val XML_DECLARED_FLAGS =
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS or
                AccessibilityServiceInfo.FLAG_REQUEST_MULTI_FINGER_GESTURES
    }

    // Nav-HUD a11y POLL: accessibility events stop when a nav app's content settles
    // (between turns, stopped at a light), which would freeze the HUD on the last
    // frame. While a registered nav app is foreground, re-read the active window on a
    // fixed cadence — independent of events — so distance/maneuver keep updating.
    // Cheap-gated: with no nav source armed (activePackages empty) the tick just
    // reschedules without touching the node tree.
    private val pollHandler = Handler(Looper.getMainLooper())

    /** Cost gate in FRONT of the all-displays window enumeration, shared by the event
     *  ladder's rung 2 and this poll so the two can never double-scan. */
    private val navScanGate = NavA11yReadPolicy.ScanGate()

    private val navPoll = object : Runnable {
        override fun run() {
            try {
                val active = NavA11yDispatcher.activePackages
                val root = if (active.isNotEmpty()) rootInActiveWindow else null
                val pkg = root?.packageName?.toString()
                if (pkg != null && root != null && pkg in active) {
                    // Waze draws its arrow as a graphic — a11y can only publish the
                    // arrow node bounds; the pixels come from MediaProjection in
                    // WazeArrowCaptureService (gated on consent + armed). This is the
                    // authoritative Waze-foreground signal: rootInActiveWindow really is
                    // the focused window. Other nav apps in the foreground release any
                    // held capture.
                    dispatchNavWindow(pkg, root, isForeground = true)
                    if (pkg != "com.waze") {
                        WazeCaptureGate.onWazeGone(this@RemoteControlAccessibilityService)
                    }
                }
                // Background-rich, DAEMON-FREE: when the foreground is NOT a nav app,
                // any driving map is backgrounded — but many ROMs drop the map into a
                // PiP (or park it on a secondary display) where it KEEPS rendering and
                // keeps a live a11y tree. rootInActiveWindow misses it (it's no longer
                // the active window), so scan every display and read the map's window
                // directly. No VirtualDisplay, no privileged daemon. Apps that keep no
                // window when backgrounded (e.g. Waze) can't be driven in background —
                // the notification path covers GMaps/Yandex; Waze has neither a usable
                // notification nor a background window, so it's foreground-only.
                // Shares the event path's cost gate so the two can never double-scan
                // (600 ms poll vs 200 ms gate: the poll passes it in the normal case).
                if (active.isNotEmpty() && (pkg == null || pkg !in active) &&
                    navScanGate.allow(SystemClock.elapsedRealtime())
                ) {
                    readBackgroundNavWindows(active)
                }
            } catch (_: Throwable) {
                // a transient a11y read failure must never kill the poll loop
            }
            pollHandler.postDelayed(this, NAV_POLL_MS)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        lastHeartbeatMs = System.currentTimeMillis()
        // FLAG_REQUEST_MULTI_FINGER_GESTURES (0x1000, API 30+) is
        // required for multi-finger synthetic gestures dispatched via
        // dispatchGesture() to actually be delivered as multi-touch
        // through the input pipeline. Without it, BYD's DiShare
        // GestureDispatcher rejects the synthesised 2-finger swipe
        // even though pointerCount=2 in the MotionEvent — verified
        // empirically on Leopard 5 (logcat: onShareTouchPreStart →
        // onShareTouchCancel after the flag was missing). Mirrors
        // what the L5GestureService reference implementation does on
        // its own service instance.
        //
        // FLAG_REQUEST_FILTER_KEY_EVENTS routes hardware key presses through
        // onKeyEvent() below, where WheelVoiceController swallows the
        // dynamically-resolved steering-wheel voice key and fires our AI
        // voice instead of BYD's autovoice. Declared in a11y_remote_control.xml
        // too; OR-ing it here mirrors the multi-finger flag and survives a
        // ROM that drops the XML flag on rebind.
        //
        // FLAG_RETRIEVE_INTERACTIVE_WINDOWS (0x40) is what makes
        // getWindowsOnAllDisplays() / AccessibilityNodeInfo.getWindow() return
        // anything at all — the whole background nav read (readBackgroundNavWindows,
        // rung 2 of the event ladder) is dead without it, and the on-car symptom of
        // that is EXACTLY a frozen cluster: the pipeline stays armed and keeps
        // re-pushing its last frame while receiving nothing. We declare it in
        // a11y_remote_control.xml, but a ROM that rebuilds serviceInfo on rebind can
        // drop it; the reference implementation re-asserts it unconditionally on
        // every connect for this reason (its own `flags |= 96` =
        // FILTER_KEY_EVENTS | RETRIEVE_INTERACTIVE_WINDOWS). Re-asserting a flag we
        // already declare costs nothing and is a no-op when the ROM behaved.
        //
        // FLAG_REPORT_VIEW_IDS (0x10) is the symmetric case, added for the same
        // reason: it is equally XML-only and it is what makes
        // findAccessibilityNodeInfosByViewId() report resource names at all — i.e.
        // the ENTIRE nav scrape (A11yNavSource.node/text/desc). Without it the
        // background ladder can succeed, hand us the correct map-owned tree, and the
        // scrape still returns nothing — producing a frozen cluster indistinguishable
        // from the flag we re-assert above. Re-asserting both means one on-car session
        // can't half-confirm the hypothesis.
        //
        // HONESTY NOTE — this one is DEFENSIVE, and the evidence argues it is a no-op:
        // the reference does NOT re-assert FLAG_REPORT_VIEW_IDS (only `|= 96`) while
        // depending on view-id lookups in 124 places, and its HUD demonstrably works on
        // these ROMs. That is positive evidence the BYD ROM PRESERVES the XML-declared
        // flagReportViewIds. Note the asymmetry: no such inference is available for
        // RETRIEVE_INTERACTIVE_WINDOWS, because the reference defends that one, so its
        // working says nothing about whether the ROM preserves it. Neither flag has
        // been observed being dropped; the full-flags probe (see the diagnosis doc §5-P3)
        // is what would actually settle it.
        try {
            val info = serviceInfo
            // Capture the flags word the ROM handed us BEFORE we OR anything in.
            // This is the only value that can answer "does this ROM drop XML-declared
            // a11y flags on rebind" — the post-OR word always shows the bits we just
            // set, so the previous post-OR-only log could never detect a drop.
            // Logged at W because release strips Log.v/d/i (proguard-rules.pro:247-252),
            // so an I-level diagnostic is invisible on exactly the prod build that goes
            // in the car. Two ints, once per service connect — negligible.
            val romFlags = info.flags
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_REQUEST_MULTI_FINGER_GESTURES or
                AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            serviceInfo = info
            val dropped = XML_DECLARED_FLAGS and romFlags.inv()
            Log.w(
                TAG,
                "a11y flags: rom=0x${Integer.toHexString(romFlags)} " +
                    "after=0x${Integer.toHexString(info.flags)} " +
                    "xmlDeclared=0x${Integer.toHexString(XML_DECLARED_FLAGS)} " +
                    "droppedByRom=0x${Integer.toHexString(dropped)}" +
                    if (dropped == 0) " (ROM preserved all XML flags)" else " ** ROM DROPPED XML FLAGS **",
            )
        } catch (t: Throwable) {
            Log.w(TAG, "couldn't set a11y flags: ${t.message}")
        }
        // Secondary car-start revive vector. Cluster-pad / wheel-voice cars
        // already have THIS service enabled, so they get auto-revive on
        // car-start for free; whichever a11y service the ROM rebinds first
        // revives, the other no-ops via the isRunning() gate. Strictly
        // additive + failure-isolated in its own try/catch — a revive throw
        // cannot regress dispatchGesture / onKeyEvent / WheelVoiceController.
        try {
            ConnectivityService.coldReviveIfNeeded(applicationContext, source = "a11y-remote")
        } catch (t: Throwable) {
            Log.w(TAG, "a11y revive failed: ${t.message}")
        }
        // Start the nav a11y poll (idle-cheap until a nav source arms).
        pollHandler.removeCallbacks(navPoll)
        pollHandler.postDelayed(navPoll, NAV_POLL_MS)
    }

    /**
     * Hardware-key filter. Delegates to [WheelVoiceController], which
     * consumes (returns true) only the ROM-declared wheel-voice key when the
     * override is enabled — every other key passes straight through. Runs on
     * the main thread, so the controller can post the voice trigger directly.
     */
    override fun onKeyEvent(event: KeyEvent): Boolean =
        try {
            WheelVoiceController.handleKeyEvent(event, this)
        } catch (t: Throwable) {
            Log.w(TAG, "onKeyEvent threw: ${t.message}")
            false
        }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        Log.i(TAG, "onUnbind — clearing instance")
        instance = null
        pollHandler.removeCallbacks(navPoll)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        pollHandler.removeCallbacks(navPoll)
        super.onDestroy()
    }

    // Gesture dispatch is the primary use; the Nav-HUD bolts on here to scrape
    // the nav app. CHEAP-GATE FIRST: only when the event comes from a registered
    // nav app (Maps/Waze/Yandex…) do we touch the node tree — every other app's
    // content-change events cost just a set lookup (perf review fix). That guard
    // is preserved verbatim; it is also what the reference does (it routes an
    // event to a handler only when the event's package IS the selected nav app,
    // and never runs its ladder for a foreign package).
    //
    // WHAT CHANGED (background ingest): a backgrounded map that still holds a live
    // window (PiP / secondary display) keeps firing content-change events, so we
    // DO get here — but `rootInActiveWindow` is then the FOREGROUND app's tree,
    // not the map's. We used to dispatch it anyway under the map's package name:
    // the view-id lookups (prefixed with the map's package) found nothing, no
    // frame was emitted, and the read still consumed A11yNavSource's 200 ms
    // self-throttle — which could throttle out the 600 ms poll's *correct*
    // background read. Armed pipeline, no frames = the reported freeze.
    //
    // So walk the reference's three-rung ladder instead of taking rung 3 alone:
    //   1. the event's OWN tree (free — no window IPC),
    //   2. every window on every display (expensive → cost-gated in FRONT of the
    //      read; our source-level throttle sits behind the read and cannot bound
    //      an IPC that has already happened),
    //   3. the active window.
    // Every rung is package-checked (in NavA11yDispatcher) before it is accepted.
    // No display relocation, no VirtualDisplay: rungs 2 and 3 only read windows
    // that already exist.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        val active = NavA11yDispatcher.activePackages
        if (!NavA11yReadPolicy.isNavEvent(pkg, active)) return

        // Rung 1 — the event's own tree. Correct even when its app is not focused.
        if (dispatchNavWindow(pkg, rootFromEvent(event, pkg), isForeground = false)) return
        // Rung 2 — all displays. Dispatches internally for whatever it finds.
        if (navScanGate.allow(SystemClock.elapsedRealtime()) &&
            readBackgroundNavWindows(active)
        ) {
            return
        }
        // Rung 3 — active window (the original path; still the hot one in foreground).
        dispatchNavWindow(pkg, rootInActiveWindow, isForeground = true)
    }

    /** Hand [root] to its source. Returns true when a source consumed the tree (i.e. the
     *  tree really belongs to [pkg]).
     *
     *  [isForeground] must be true ONLY when [root] came from the active window. Publishing
     *  Waze's arrow bounds is harmless either way, but [WazeCaptureGate.onWazeForeground]
     *  can launch the MediaProjection consent Activity and start the capture FGS — firing
     *  that off a backgrounded Waze window would pop a dialog with Waze off-screen. Waze
     *  stays foreground-only (see `e9835e25`); this keeps that true. */
    private fun dispatchNavWindow(
        pkg: String,
        root: AccessibilityNodeInfo?,
        isForeground: Boolean,
    ): Boolean {
        if (root == null) return false
        if (!NavA11yDispatcher.onWindow(pkg, root)) return false
        // Waze arrow is a graphic — publish its node bounds for the capture service.
        if (pkg == "com.waze") {
            publishWazeArrowBounds(root)
            if (isForeground) WazeCaptureGate.onWazeForeground(this)
        }
        return true
    }

    /** Rung 1: the root of the tree the EVENT came from, when it belongs to [pkg].
     *  Walks the source node's parents (bounded), then falls back to the source's own
     *  window root. Costs no window enumeration, so it needs no cost gate. The window
     *  fallback requires FLAG_RETRIEVE_INTERACTIVE_WINDOWS (re-asserted in
     *  [onServiceConnected]); it degrades to null without it. Fully guarded. */
    private fun rootFromEvent(event: AccessibilityEvent, pkg: String): AccessibilityNodeInfo? =
        runCatching {
            val src = event.source ?: return@runCatching null
            var node: AccessibilityNodeInfo = src
            var hops = 0
            while (hops++ < NavA11yReadPolicy.MAX_PARENT_WALK) {
                node = node.parent ?: break
            }
            if (NavA11yReadPolicy.rootMatches(node.packageName?.toString(), pkg)) {
                return@runCatching node
            }
            src.window?.root?.takeIf {
                NavA11yReadPolicy.rootMatches(it.packageName?.toString(), pkg)
            }
        }.getOrNull()

    override fun onInterrupt() {}

    /** Publish the live on-screen bounds of Waze's arrow node so the capture service
     *  can crop it. Waze draws the arrow as a graphic (no text), so the bounds are all
     *  the a11y side can contribute; the pixels come from MediaProjection in
     *  [com.i99dev.ilink.nav.ingest.WazeArrowCaptureService]. The raw node rect is
     *  published untransformed (no padding) so it matches the hash registry's crop.
     *  Fully guarded. */
    private fun publishWazeArrowBounds(root: AccessibilityNodeInfo) {
        runCatching {
            val node = root.findAccessibilityNodeInfosByViewId("com.waze:id/navBarDirection")
                ?.firstOrNull() ?: return
            val r = Rect().also { node.getBoundsInScreen(it) }
            WazeArrowBounds.update(r.left, r.top, r.width(), r.height())
        }
        // Lane-guidance row (P2): its bounds drive the lane capture. Absent when Waze
        // shows no lanes → WazeLaneBounds ages out → no lane (degrade-safe).
        runCatching {
            val lane = root.findAccessibilityNodeInfosByViewId("com.waze:id/laneGuidanceView")
                ?.firstOrNull() ?: return
            val r = Rect().also { lane.getBoundsInScreen(it) }
            WazeLaneBounds.update(r.left, r.top, r.width(), r.height())
        }
    }

    /** Read every DRIVING nav app that has a live window ANYWHERE (any display,
     *  including a PiP / non-focused window) and dispatch its tree. The daemon-free
     *  background path: a map PiP'd or backgrounded on the IVI keeps its a11y tree,
     *  so distance/road/arrow can be pulled straight from it — no keepalive VD, no
     *  privileged daemon.
     *
     *  EXPENSIVE: [getWindowsOnAllDisplays] is a window-enumeration IPC and every `w.root`
     *  is another. Callers must pass [NavA11yReadPolicy.ScanGate] first — the source-level
     *  200 ms throttle sits behind the read and cannot bound this.
     *
     *  API-30 GUARD, not dead code: [getWindowsOnAllDisplays] is API 30 and our resolved
     *  `minSdk` is 24 (`flutter.minSdkVersion`), so sub-30 devices must fall through. Every
     *  car this fix targets is well above it (L8 UI7 = Android 13 / API 33).
     *
     *  Returns true when at least one nav window was found and consumed. */
    private fun readBackgroundNavWindows(active: Set<String>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        var hit = false
        runCatching {
            val all = windowsOnAllDisplays
            for (i in 0 until all.size()) {
                val list = all.valueAt(i) ?: continue
                for (w in list) {
                    val r = runCatching { w?.root }.getOrNull() ?: continue
                    val p = r.packageName?.toString() ?: continue
                    if (p in active && dispatchNavWindow(p, r, isForeground = false)) hit = true
                }
            }
        }
        return hit
    }

    /**
     * Dispatch a tap on [displayId] at ([x], [y]). Returns true when
     * the dispatch reached the platform without throwing; false if
     * the underlying API rejected (e.g. negative durations, malformed
     * path). The actual *delivery* to a target window is async —
     * [GestureResultCallback.onCompleted] / `onCancelled` fire later
     * but we don't block the caller on them; the Dart side treats
     * "dispatched" as the contract.
     */
    fun dispatchTap(displayId: Int, x: Float, y: Float): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, 50L)
        return dispatchWithBuilder(displayId, listOf(stroke))
    }

    fun dispatchSwipe(
        displayId: Int,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
    ): Boolean {
        val path = Path().apply {
            moveTo(fromX, fromY)
            lineTo(toX, toY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
        return dispatchWithBuilder(displayId, listOf(stroke))
    }

    /**
     * Two simultaneous parallel swipes — used by [DishareTransport] to
     * synthesise the 2-finger "share" gesture BYD's DiShare service
     * looks for (`ACTION_POINTER_DOWN` with `pointerCount == 2`).
     *
     * Both strokes start at `t=0` and last [durationMs]; the duration
     * isn't load-bearing on DiShare's detector but a too-short value
     * (<200 ms) can race the system gesture recogniser. 800 ms is the
     * empirically-validated default the L5 build guide ships with.
     *
     * Lands on the default display — DiShare reads the IVI's input
     * stream regardless of where the gesture is dispatched.
     */
    fun dispatchTwoFingerSwipeRight(
        fromX: Float,
        toX: Float,
        upperY: Float,
        lowerY: Float,
        durationMs: Long,
    ): Boolean {
        val pathA = Path().apply { moveTo(fromX, upperY); lineTo(toX, upperY) }
        val pathB = Path().apply { moveTo(fromX, lowerY); lineTo(toX, lowerY) }
        return dispatchWithBuilder(
            DEFAULT_DISPLAY,
            listOf(
                GestureDescription.StrokeDescription(pathA, 0L, durationMs),
                GestureDescription.StrokeDescription(pathB, 0L, durationMs),
            ),
        )
    }

    fun dispatchLongPress(
        displayId: Int,
        x: Float,
        y: Float,
        durationMs: Long,
    ): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
        return dispatchWithBuilder(displayId, listOf(stroke))
    }

    private fun dispatchWithBuilder(
        displayId: Int,
        strokes: List<GestureDescription.StrokeDescription>,
    ): Boolean {
        val builder = GestureDescription.Builder()
        for (s in strokes) builder.addStroke(s)
        // setDisplayId was added in API 30. Below that the gesture
        // lands on the default display only — surface the limitation
        // in the result rather than silently mis-targeting.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                builder.setDisplayId(displayId)
            } catch (t: Throwable) {
                Log.w(TAG, "setDisplayId($displayId) threw: ${t.message}")
                // Continue — falling through to default-display
                // dispatch is preferable to a hard fail.
            }
        }
        val gd = builder.build()
        return try {
            val ok = dispatchGesture(gd, null, Handler(Looper.getMainLooper()))
            if (ok) lastHeartbeatMs = System.currentTimeMillis()
            ok
        } catch (t: Throwable) {
            Log.w(TAG, "dispatchGesture threw: ${t.message}")
            false
        }
    }

    /**
     * Append [text] to whatever EditText currently has input focus,
     * across any visible window the service can see.
     *
     * Why not `input -d N text`: that path synthesizes KeyEvents which
     * Android's InputDispatcher routes via per-display window focus.
     * On XDJA-virtualized clusters, displayId 3 has zero focused
     * windows in WindowManager (mCurrentFocus=null) even though the
     * launched activity's surface is composited there — so KeyEvents
     * land nowhere. AccessibilityService bypasses key-event routing:
     * it walks the accessibility tree, finds the focused EditText
     * directly, and mutates it via ACTION_SET_TEXT. Works on any
     * display, native or webview, regardless of WindowManager's
     * per-display focus state.
     *
     * Append-only: we read the node's current text + concat. A future
     * caller-cap could opt for replace if needed.
     *
     * Returns false when no input focus exists ANYWHERE — the caller
     * should toast a "tap a text field first" hint. [displayId] is
     * informational only today (the focused-input lookup is global);
     * a future change can scope to one display by walking
     * `getWindows()` and filtering on `getDisplayId()`.
     */
    fun dispatchSetText(displayId: Int, text: String): Boolean {
        Log.i(TAG, "dispatchSetText displayId=$displayId len=${text.length}")
        val node = findFocusedInputAcrossWindows(displayId)
        if (node == null) {
            Log.w(TAG, "dispatchSetText: no focused input found")
            return false
        }
        Log.i(TAG, "dispatchSetText: found node class=${node.className} pkg=${node.packageName} editable=${node.isEditable}")
        return try {
            val current = node.text?.toString() ?: ""
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    current + text,
                )
            }
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            Log.i(TAG, "dispatchSetText: performAction ACTION_SET_TEXT ok=$ok")
            if (ok) lastHeartbeatMs = System.currentTimeMillis()
            ok
        } catch (t: Throwable) {
            Log.w(TAG, "dispatchSetText threw: ${t.message}")
            false
        }
    }

    /**
     * Delete the last character from the focused EditText. Same
     * accessibility-tree path as [dispatchSetText]. Used for
     * KEYCODE_DEL backspace; we manipulate text directly rather
     * than pumping a key event through a routing path that doesn't
     * reach the cluster window.
     */
    fun dispatchDeleteLastChar(displayId: Int): Boolean {
        val node = findFocusedInputAcrossWindows(displayId) ?: return false
        return try {
            val current = node.text?.toString() ?: ""
            if (current.isEmpty()) return true
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    current.substring(0, current.length - 1),
                )
            }
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (ok) lastHeartbeatMs = System.currentTimeMillis()
            ok
        } catch (t: Throwable) {
            Log.w(TAG, "dispatchDeleteLastChar threw: ${t.message}")
            false
        }
    }

    /**
     * Walk every visible window the accessibility service can see;
     * return the first node with INPUT focus. Preferring matches on
     * [displayId] when present; falling back to any focused input on
     * any display so a user who hasn't tapped to focus on the cluster
     * yet still gets a usable error path (the caller can surface
     * "tap a text field first").
     */
    private fun findFocusedInputAcrossWindows(displayId: Int): AccessibilityNodeInfo? {
        val windows = try { windows } catch (t: Throwable) {
            Log.w(TAG, "getWindows() threw: ${t.message}"); null
        }
        Log.i(TAG, "findFocusedInput: targetDisplayId=$displayId windows=${windows?.size ?: 0}")
        if (windows != null) {
            for (w in windows) {
                val wDisplayId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) w.displayId else 0
                val root = w.root
                Log.i(TAG, "  window id=${w.id} displayId=$wDisplayId active=${w.isActive} focused=${w.isFocused} root=${root != null} title='${w.title}'")
            }
            // Prefer the requested display first.
            for (w in windows) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    w.displayId != displayId
                ) {
                    continue
                }
                val n = w.root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (n != null) {
                    Log.i(TAG, "findFocusedInput: matched on requested displayId=$displayId")
                    return n
                }
            }
            // Fallback: any display.
            for (w in windows) {
                val n = w.root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (n != null) {
                    val wDisplayId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) w.displayId else 0
                    Log.i(TAG, "findFocusedInput: fell back to displayId=$wDisplayId")
                    return n
                }
            }
        }
        // Last resort: rootInActiveWindow.
        val r = rootInActiveWindow
        Log.i(TAG, "findFocusedInput: last-resort rootInActiveWindow=${r != null}")
        return r?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
    }
}
