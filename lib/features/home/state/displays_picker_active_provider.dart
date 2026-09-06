import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the user has flipped the assistant panel into "Show
/// Displays" mode (the [DisplayDropPicker]). Lifted out of the
/// AssistantPanel's local state so siblings on the right pane (the
/// installed-apps strip, mini-apps strip) can branch their gesture
/// model on it without prop-drilling:
///
///   * `true`  — picker is up; apps respond to **long-press-drag**
///     onto a display card. Tap-launch is unchanged.
///   * `false` — picker is hidden (default); long-press opens the
///     [showAppActionsSheet] (Open-on / Enable / Disable / Uninstall
///     / Move / Force-stop / Clear / Whitelist).
///
/// One bit, one notifier, no setter ceremony — call sites flip via
/// `ref.read(displaysPickerActiveProvider.notifier).toggle()` or
/// `.set(bool)`. Drag-in-flight forces this to true regardless of
/// the user's last toggle (the picker has to be visible as a drop
/// target); that override is handled at the AssistantPanel render
/// site, not here, because this notifier represents the *user's*
/// intent rather than the live UI state.
class DisplaysPickerActive extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void set(bool value) {
    if (state != value) state = value;
  }
}

final displaysPickerActiveProvider =
    NotifierProvider<DisplaysPickerActive, bool>(DisplaysPickerActive.new);
