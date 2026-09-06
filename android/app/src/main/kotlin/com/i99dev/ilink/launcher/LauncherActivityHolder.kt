package com.i99dev.ilink.launcher

import android.app.Activity
import java.lang.ref.WeakReference

/**
 * Process-wide weak ref to the currently-resumed Activity.
 *
 * Plugins that need to launch a system UI (role-grant dialogs, settings
 * panels) want a foreground Activity reference — calling
 * `startActivity` from `applicationContext` + `FLAG_ACTIVITY_NEW_TASK`
 * picks an arbitrary display on multi-display HUs (the BYD HU has
 * cluster + IVI + passenger), so the new task can land on a display the
 * user isn't looking at.
 *
 * MainActivity registers itself in onResume + clears in onPause. The
 * weak ref means we don't pin the Activity past its lifetime if the
 * Pause callback ever fails to fire (process crash, etc.). Plugins
 * that read this fall back to applicationContext when the holder is
 * empty (test harness, brief window between activities).
 */
object LauncherActivityHolder {
    @Volatile
    private var ref: WeakReference<Activity>? = null

    fun setActivity(activity: Activity) {
        ref = WeakReference(activity)
    }

    fun clearActivity(activity: Activity) {
        // Only clear if we still hold the same Activity — avoids a
        // race where Pause(A) fires after Resume(B) on a quick
        // navigation and would otherwise wipe the new ref.
        if (ref?.get() === activity) ref = null
    }

    fun current(): Activity? = ref?.get()
}
