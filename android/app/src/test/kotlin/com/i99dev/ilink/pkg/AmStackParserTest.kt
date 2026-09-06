package com.i99dev.ilink.pkg

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Unit tests for [AmStackParser].
 *
 * Scope: pure-String parse + the `am stack move-task` **target**
 * selection that [PackagePlatformPlugin.doMove] depends on. No
 * Android, no ADB.
 *
 * What this file LOCKS IN:
 *   * `RootTaskRow.activityType` / `userId` are parsed off the real
 *     Leopard 8 (Di5.1) `am stack list` shape — the
 *     `configuration={… mActivityType=… }` line that follows each
 *     header, and the header `userId=`.
 *   * [AmStackParser.findRootTaskOnDisplay] returns ONLY a movable
 *     (`standard`, `userId == 0`) stack. The regression this guards
 *     is the on-device-reproduced "Driver→FSE / IVI→FSE-when-running
 *     fails with `move-task hard failure: uncaught_exception`": the
 *     FSE display's only persistent stack is the multi-user launcher
 *     **home** (`com.android.launcher3.fse`, `mActivityType=home`)
 *     and ATMS rejects reparenting a standard task into it. Skipping
 *     it (→ null → doMove seeds its own ClusterActivity stack) is
 *     the fix.
 *   * The task-row `displayId` inheritance from the enclosing
 *     RootTask survives the pending/flush parse restructure.
 *
 * The primary fixture is the verbatim `am stack list` captured from
 * the L8 test car (192.168.4.72) during the FSE root-cause session,
 * trimmed to the load-bearing stacks.
 */
class AmStackParserTest {

    // Verbatim Leopard 8 shape: header + the `configuration={…}` line
    // (carrying mActivityType) + the indented child `taskId=` line
    // whose displayId is inherited from the RootTask.
    private val L8_FIXTURE = """
        RootTask id=121 bounds=[0,0][2560,1600] displayId=0 userId=0
         configuration={1.0 121000015byd_theme [en_US] land night mWindowingMode=fullscreen mActivityType=standard mAlwaysOnTop=undefined mRotation=ROTATION_0} s.374 fontWeightAdjustment=0}
          taskId=121: com.i99dev.ilink/com.i99dev.ilink.MainActivity bounds=[0,0][2560,1600] userId=0 visible=true topActivity=ComponentInfo{com.i99dev.ilink/com.i99dev.ilink.MainActivity}

        RootTask id=1 bounds=[0,0][2560,1600] displayId=0 userId=0
         configuration={1.0 121000015byd_theme [en_US] land night mWindowingMode=fullscreen mActivityType=home mAlwaysOnTop=undefined mRotation=ROTATION_0} s.374 fontWeightAdjustment=0}
          taskId=80: com.android.launcher3/com.android.launcher3.home.MainActivity bounds=[0,0][2560,1600] userId=0 visible=false topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.home.MainActivity}

        RootTask id=81 bounds=[0,0][1920,720] displayId=2 userId=0
         configuration={1.0 121000015byd_theme [en_US] land night mWindowingMode=fullscreen mActivityType=home mAlwaysOnTop=undefined mRotation=ROTATION_0} s.374 fontWeightAdjustment=0}
          taskId=99900004: com.android.launcher3.fse/com.android.launcher3.home.MainActivity bounds=[0,0][1920,720] userId=999 visible=true topActivity=ComponentInfo{com.android.launcher3.fse/com.android.launcher3.home.MainActivity}

        RootTask id=120 bounds=[0,0][1920,720] displayId=5 userId=0
         configuration={1.0 121000015byd_theme [en_US] land night mWindowingMode=fullscreen mActivityType=standard mAlwaysOnTop=undefined mRotation=ROTATION_0} s.374 fontWeightAdjustment=0}
          taskId=119: ru.yandex.yandexmaps/ru.yandex.yandexmaps.SplashScreen bounds=[0,0][1920,720] userId=0 visible=true topActivity=ComponentInfo{ru.yandex.yandexmaps/ru.yandex.yandexmaps.SplashScreen}
    """.trimIndent()

    // ── RootTaskRow field extraction ───────────────────────────────────────

    @Test fun `parses activityType and userId off the real L8 shape`() {
        val roots = AmStackParser.parse(L8_FIXTURE).rootTasks.associateBy { it.rootTaskId }

        assertEquals("standard", roots[121]?.activityType)
        assertEquals(0, roots[121]?.userId)

        assertEquals("home", roots[1]?.activityType)

        // The FSE home stack. Header reports userId=0 even though its
        // child task is u999 — which is exactly why activityType, not
        // userId, is the decisive movability signal.
        assertEquals("home", roots[81]?.activityType)
        assertEquals(0, roots[81]?.userId)
        assertEquals(2, roots[81]?.displayId)

        assertEquals("standard", roots[120]?.activityType)
        assertEquals(5, roots[120]?.displayId)
    }

    @Test fun `task displayId is inherited from its RootTask (parse restructure guard)`() {
        val tasks = AmStackParser.parseAll(L8_FIXTURE)
        // The u999 child line carries no displayId of its own — it
        // must inherit RootTask 81's displayId=2.
        val fse = tasks.first { it.packageName == "com.android.launcher3.fse" }
        assertEquals(2, fse.displayId)
        val maps = tasks.first { it.packageName == "ru.yandex.yandexmaps" }
        assertEquals(5, maps.displayId)
        assertEquals(120, maps.rootTaskId)
    }

    // ── findRootTaskOnDisplay: movable-target selection ────────────────────

    @Test fun `FSE display (only a home stack) yields NO movable target`() {
        // The regression: blindly returning RootTask 81 → `am stack
        // move-task <task> 81 true` → IllegalArgumentException. null
        // is correct: doMove then seeds its own standard u0 stack.
        val roots = AmStackParser.parse(L8_FIXTURE).rootTasks
        assertNull(AmStackParser.findRootTaskOnDisplay(roots, 2))
    }

    @Test fun `IVI display skips the home stack and picks the standard one`() {
        // Display 0 has BOTH a standard (121) and a home (1) stack.
        // The standard one is the only valid move-task target.
        val roots = AmStackParser.parse(L8_FIXTURE).rootTasks
        assertEquals(121, AmStackParser.findRootTaskOnDisplay(roots, 0))
    }

    @Test fun `cluster display returns its standard ClusterActivity stack`() {
        val roots = AmStackParser.parse(L8_FIXTURE).rootTasks
        assertEquals(120, AmStackParser.findRootTaskOnDisplay(roots, 5))
    }

    @Test fun `display with no stack at all yields null`() {
        val roots = AmStackParser.parse(L8_FIXTURE).rootTasks
        assertNull(AmStackParser.findRootTaskOnDisplay(roots, 4))
    }

    // ── fail-safe / defensive parsing ──────────────────────────────────────

    @Test fun `missing configuration line is not treated as a movable target`() {
        // A ROM that omits the `configuration={…}` line → unknown
        // activityType ("") → NOT a move-task target (fail-safe:
        // doMove seeds its own stack rather than risk a bad reparent).
        val noConfig = """
            RootTask id=200 bounds=[0,0][1920,720] displayId=7 userId=0
              taskId=201: com.example.app/.MainActivity bounds=[0,0][1920,720] userId=0 visible=true
        """.trimIndent()
        val snap = AmStackParser.parse(noConfig)
        val row = snap.rootTasks.first { it.rootTaskId == 200 }
        assertEquals("", row.activityType)
        assertNull(AmStackParser.findRootTaskOnDisplay(snap.rootTasks, 7))
        // The task itself still parses (displayId inherited).
        assertNotNull(
            AmStackParser.findOnDisplay(snap.tasks, "com.example.app", 7),
        )
    }

    @Test fun `cross-user standard stack is excluded as a move target`() {
        // Defense-in-depth: a genuinely u-non-zero rooted standard
        // stack is still not a valid current-user move target.
        val crossUser = """
            RootTask id=300 bounds=[0,0][1920,720] displayId=8 userId=10
             configuration={1.0 mActivityType=standard mRotation=ROTATION_0}
              taskId=301: com.example.work/.MainActivity bounds=[0,0][1920,720] userId=10 visible=true
        """.trimIndent()
        val snap = AmStackParser.parse(crossUser)
        assertEquals(10, snap.rootTasks.first().userId)
        assertEquals("standard", snap.rootTasks.first().activityType)
        assertNull(AmStackParser.findRootTaskOnDisplay(snap.rootTasks, 8))
    }

    @Test fun `empty input parses to empty snapshot`() {
        val snap = AmStackParser.parse("")
        assertEquals(0, snap.tasks.size)
        assertEquals(0, snap.rootTasks.size)
    }
}
