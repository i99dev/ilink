package com.i99dev.ilink.miniapps

/**
 * Resolves shell-command templates and intent constants for the mini-app
 * family handlers. When the encrypted table is loaded, every value comes
 * from there; otherwise the migrated handler falls back to the legacy
 * hardcoded constant.
 *
 * Each method returns the rendered string the caller passes verbatim to
 * [com.i99dev.ilink.adb.AdbShellBridge.shell] / `Intent.setAction(...)`
 * etc — callers don't see the underlying [OpRoute] / [IntentAction]
 * structure.
 *
 * Why a helper layer rather than per-call site lookups: the migration
 * goal is "no plaintext shell command shape in classes.dex." Centralising
 * the lookup means the legacy fallback strings live in exactly ONE class.
 * A future hardening PR can elide that class in release builds via R8 +
 * BuildConfig (one entry point to gate, not N).
 *
 * Tokens used in templates follow the CarTable arg-template convention:
 *   * `{key}` — required arg; rendering throws if absent.
 *   * `{key:default}` — optional arg; falls back to `default` if absent.
 */
object MiniAppShellCommands {

    /**
     * `am start-activity --activity-multiple-task --display N -n COMP`.
     * Used by `pkg.launch` non-default-display path. The multi-task flag
     * is load-bearing on Leopard 8 (without it the AM reuses the
     * existing task and ignores `--display`).
     */
    fun amStartOnDisplay(displayId: Int, component: String): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.PKG_LAUNCH_ON_DISPLAY)
        if (tpl != null && tpl.argTemplate.isNotEmpty()) {
            return renderTemplate(
                tpl.argTemplate,
                mapOf("displayId" to displayId, "component" to component),
            )
        }
        // Legacy fallback — exists only when the encrypted table hasn't
        // populated this op yet. Stripped from release builds once
        // Phase 2 + the textproto seed both ship.
        return "am start-activity --activity-multiple-task --display $displayId -n $component"
    }

    /** `am stack list` — used to find a package's current task and to
     *  enumerate root tasks per display. Same shape on every Android
     *  version we run on; encoded in the table for consistency. */
    fun amStackList(): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.PKG_STACK_LIST)
        return tpl?.argTemplate?.firstOrNull() ?: "am stack list"
    }

    /**
     * `wm density <dpi> -d <displayId>` — override the logical
     * density (in DPI) for a specific display. Used to zoom mini-app
     * surfaces on the cluster (legibility varies a lot between 5"
     * and 9" cluster panels). Per-display flag `-d N` means we don't
     * disturb the IVI's density when zooming the cluster.
     *
     * No encrypted-table token yet — the literal is the same on every
     * Android version we target. A future hardening pass can add a
     * `WM_DENSITY_SET` token and rotate this through the table; the
     * literal fallback is already in shape for the existing
     * resolveByToken pattern.
     */
    fun wmDensitySet(displayId: Int, densityDpi: Int): String {
        return "wm density $densityDpi -d $displayId"
    }

    /** `wm density reset -d <displayId>` — restore stock density for
     *  a display. Symmetric to [wmDensitySet]. */
    fun wmDensityReset(displayId: Int): String {
        return "wm density reset -d $displayId"
    }

    /** `am stack move-task TASK ROOT true` — used by `pkg.move` to
     *  reparent a running task onto a different display's root stack. */
    fun amStackMoveTask(taskId: Int, targetRootTaskId: Int): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.PKG_STACK_MOVE_TASK)
        if (tpl != null && tpl.argTemplate.isNotEmpty()) {
            return renderTemplate(
                tpl.argTemplate,
                mapOf("taskId" to taskId, "rootTaskId" to targetRootTaskId),
            )
        }
        return "am stack move-task $taskId $targetRootTaskId true"
    }

    /**
     * `am display move-stack <ROOT_TASK_ID> <DISPLAY_ID>` — move a
     * whole root task to another display, **keeping the same pid**
     * (no relaunch). Unlike [amStackMoveTask] this needs NO
     * pre-existing target stack on the destination, so it is the
     * only primitive that lands a running app on the L8 FSE /
     * cluster displays (which only ever host a u999/`home` stack —
     * `am stack move-task` cannot reparent there). Proven on
     * 192.168.4.72: IVI↔FSE↔cluster, bidirectional, same pid.
     *
     * No encrypted-table token yet — same literal on every Android
     * version we target; mirrors the [wmDensitySet] no-token shape.
     */
    fun amDisplayMoveStack(rootTaskId: Int, displayId: Int): String {
        return "am display move-stack $rootTaskId $displayId"
    }

    /**
     * Repaint a just-vacated projected display by launching
     * [clusterActivityComponent] in **blank tour mode** — an opaque
     * black fill, no marker text. `am display move-stack` leaves the
     * source secondary display (cluster / FSE) with no fallback
     * layer, so SurfaceFlinger keeps the previous app's last frame
     * frozen; this paints over it. Extra keys mirror
     * `ClusterActivity` companion constants (kept as literals — this
     * is a CLI string, same no-token shape as [amDisplayMoveStack]).
     * Black = 0xFF000000 = -16777216.
     */
    fun amStartClusterBlank(displayId: Int): String {
        return "am start --display $displayId -n ${clusterActivityComponent()}" +
            " --es ilink.tour 1 --es ilink.tour.blank 1" +
            " --ei ilink.tour.colorArgb -16777216" +
            " --ei ilink.tour.displayId $displayId"
    }

    /** Component string for the placeholder ClusterActivity that
     *  `pkg.move` spawns to seed a target display with a stack to move
     *  into. Encrypted-table value lets us rename / relocate the
     *  placeholder without leaving the literal in classes.dex. */
    fun clusterActivityComponent(): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.PKG_CLUSTER_PLACEHOLDER_COMPONENT)
        return tpl?.argTemplate?.firstOrNull() ?: "com.i99dev.ilink/.display.ClusterActivity"
    }

    /**
     * `am start-activity` template the surface family uses to put a
     * [com.i99dev.ilink.display.ClusterActivity] on a non-default
     * display. Carries four `--es` extras (bundleUri / route /
     * surfaceId / appId) the receiving activity reads in onCreate.
     *
     * `--activity-multiple-task` is load-bearing — without it AM
     * reuses the existing task and ignores `--display`.
     * `--activity-reorder-to-front` hoists us above amap, which wins
     * z-order on the cluster slot otherwise.
     *
     * Each extra value is single-quoted so the shell doesn't expand
     * `~`/`$`/glob chars. Quoting happens here rather than in the
     * template tokens because the renderer's `{key}` substitution
     * doesn't strip wrapper characters — keeping the template values
     * bare lets the existing renderTemplate handle the lookup
     * unchanged.
     */
    fun amStartClusterActivity(
        displayId: Int,
        component: String,
        bundleUri: String,
        route: String,
        surfaceId: String,
        appId: String,
    ): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.SURFACE_AM_START_CLUSTER)
        if (tpl != null && tpl.argTemplate.isNotEmpty()) {
            return renderTemplate(
                tpl.argTemplate,
                mapOf(
                    "displayId" to displayId,
                    "component" to component,
                    "bundleUri" to "'$bundleUri'",
                    "route" to "'$route'",
                    "surfaceId" to "'$surfaceId'",
                    "appId" to "'$appId'",
                ),
            )
        }
        return "am start-activity --activity-multiple-task --activity-reorder-to-front " +
            "--display $displayId -n $component " +
            "--es bundleUri '$bundleUri' --es route '$route' " +
            "--es surfaceId '$surfaceId' --es appId '$appId'"
    }

    /**
     * `am force-stop com.example.amapservice` — evicts amap from the
     * cluster slot so our priority-100 alias resolves on the next
     * projection-service handshake. amap auto-respawns (it's
     * persistent="true") within ~1s; we don't restore on tearDown.
     *
     * The package name is the most distinctive IP in this command:
     * `com.example.amapservice` is BYD's bundled ADAS map, and
     * naming it specifically is the "we know how their cluster slot
     * is wired" signal. Encrypting strips the literal from
     * classes.dex.
     */
    fun amForceStopAmap(): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.SURFACE_AMAP_FORCE_STOP)
        return tpl?.argTemplate?.firstOrNull() ?: "am force-stop com.example.amapservice"
    }

    /**
     * `input -d N tap X Y` — gesture family's ADB fallback for
     * synthetic taps when the AccessibilityService dispatch path
     * isn't available (a11y disabled, or BYD's a11y panel forgot us).
     *
     * The `-d` flag targeting a non-default display is the
     * load-bearing detail: Leopard 8's input shim accepts `-d` from
     * shell uid but rejects it from app uid, so this path only works
     * via loopback ADB. Encrypting strips the multi-display injection
     * shape from classes.dex.
     *
     * Coordinates are floored to ints — `input` rejects floats.
     */
    fun inputTap(displayId: Int, x: Int, y: Int): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.GESTURE_INPUT_TAP)
        if (tpl != null && tpl.argTemplate.isNotEmpty()) {
            return renderTemplate(
                tpl.argTemplate,
                mapOf("displayId" to displayId, "x" to x, "y" to y),
            )
        }
        return "input -d $displayId tap $x $y"
    }

    /**
     * `input -d N swipe X1 Y1 X2 Y2 DUR` — gesture family's ADB
     * fallback for synthetic swipes (and emulated long-press, with
     * from==to and the press duration). Same `-d` shell-only
     * targeting as [inputTap].
     */
    fun inputSwipe(
        displayId: Int,
        fromX: Int, fromY: Int,
        toX: Int, toY: Int,
        durationMs: Int,
    ): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.GESTURE_INPUT_SWIPE)
        if (tpl != null && tpl.argTemplate.isNotEmpty()) {
            return renderTemplate(
                tpl.argTemplate,
                mapOf(
                    "displayId" to displayId,
                    "fromX" to fromX, "fromY" to fromY,
                    "toX" to toX, "toY" to toY,
                    "durationMs" to durationMs,
                ),
            )
        }
        return "input -d $displayId swipe $fromX $fromY $toX $toY $durationMs"
    }

    /**
     * Substring marker the display family uses to identify BYD's
     * cluster slots from `Display.name`. Leopard 8's cluster surfaces
     * are named `fission_bg_XDJAScreenProjection_*` /
     * `shared_fission_bg_XDJAScreenProjection_*` — `"fission"` is the
     * shortest reliable common prefix.
     *
     * Encrypting this strips the BYD naming convention from
     * classes.dex; the runtime gets the marker via the table lookup
     * and does the `contains()` check on the resolved string.
     */
    fun clusterNameMarker(): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.DISPLAY_CLUSTER_NAME_MARKER)
        return tpl?.argTemplate?.firstOrNull() ?: "fission"
    }

    /**
     * Substring marker the watchdog uses to decide whether THIS
     * cluster activity is on amap's primary MAP_VIEW slot
     * (`shared_fission_bg_XDJAScreenProjection_0`) — only that slot
     * needs the periodic eviction watchdog. The `_0` suffix is what
     * separates amap's slot from the secondary overlay slot (`_1`).
     */
    fun amapSlotMarker(): String {
        val tpl = MiniAppDispatcher.resolveByToken(MiniAppOpToken.DISPLAY_AMAP_SLOT_MARKER)
        return tpl?.argTemplate?.firstOrNull() ?: "XDJAScreenProjection_0"
    }

    /**
     * Render an argv template list against a positional arg map. Mirrors
     * [com.i99dev.ilink.car.EncryptedCarTableSource]'s `renderTemplate`
     * — supports `{key}` (required) and `{key:default}` (optional)
     * tokens, joined by single spaces.
     */
    private fun renderTemplate(template: List<String>, args: Map<String, Any?>): String {
        return template.joinToString(separator = " ") { token -> renderToken(token, args) }
    }

    private fun renderToken(token: String, args: Map<String, Any?>): String {
        if (!token.startsWith('{') || !token.endsWith('}')) return token
        val body = token.substring(1, token.length - 1)
        val colon = body.indexOf(':')
        val (key, default) = if (colon >= 0) {
            body.substring(0, colon) to body.substring(colon + 1)
        } else {
            body to ""
        }
        return when (val raw = args[key]) {
            null -> default
            is Int -> raw.toString()
            is Boolean -> if (raw) "1" else "0"
            else -> raw.toString()
        }
    }
}
