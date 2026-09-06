// GENERATED FILE — do not edit by hand.
// Source: tool/mini_app_op_index.txt
// Regenerate: dart run tool/generate_op_tokens.dart

package com.i99dev.ilink.miniapps

/**
 * Stable 16-hex tokens for every mini-app native-capability op.
 * Used by [MiniAppShellCommands] to look up op routes via
 * [MiniAppDispatcher.resolveByToken] instead of the plaintext
 * (familyId, opId) pair — keeps op names out of classes.dex.
 */
object MiniAppOpToken {
    /** display.amap_slot_marker */
    const val DISPLAY_AMAP_SLOT_MARKER = "e6e68695d687ac7a"
    /** display.cluster_name_marker */
    const val DISPLAY_CLUSTER_NAME_MARKER = "0398326b04a090ce"
    /** gesture.input_swipe */
    const val GESTURE_INPUT_SWIPE = "b425c9821693e0e7"
    /** gesture.input_tap */
    const val GESTURE_INPUT_TAP = "050883fd55a266ac"
    /** pkg.cluster_placeholder_component */
    const val PKG_CLUSTER_PLACEHOLDER_COMPONENT = "ababd346995ec412"
    /** pkg.launch_on_display */
    const val PKG_LAUNCH_ON_DISPLAY = "dea75bdb7740be54"
    /** pkg.stack_list */
    const val PKG_STACK_LIST = "32d1fb949b60ac5c"
    /** pkg.stack_move_task */
    const val PKG_STACK_MOVE_TASK = "9f1caa65a5487473"
    /** surface.am_start_cluster */
    const val SURFACE_AM_START_CLUSTER = "8019535f3c5a486f"
    /** surface.amap_force_stop */
    const val SURFACE_AMAP_FORCE_STOP = "1774bb3e78e104a4"
}
