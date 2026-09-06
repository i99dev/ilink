import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Snapshot of the app a user is currently long-press-dragging.
/// Two source surfaces produce these:
///
///   * **Apps tab tile** — `sourceDisplayId == null`. Drop fires
///     `pkg.launch(displayId:)` on the target card.
///   * **Running-apps chip** — `sourceDisplayId == <its display>`.
///     Drop fires `pkg.move(displayId:)` instead, so the same task
///     reparents onto the target display rather than spawning a twin.
///     This is the L8 path; on L5 we still go via DiShare since
///     "move" doesn't apply to a synthetic-swipe mirror — the
///     transport short-circuit handles the same-package case.
///
/// `iconBytes` is optional — the picker happily renders a tinted-
/// initial fallback if the host hasn't resolved the launcher PNG yet
/// by the time the gesture starts.
class DraggedApp {
  const DraggedApp({
    required this.packageName,
    required this.label,
    this.iconBytes,
    this.sourceDisplayId,
  });

  final String packageName;
  final String label;
  final Uint8List? iconBytes;
  final int? sourceDisplayId;
}

/// Holds the active drag, if any. Null means "no drag in progress" —
/// the home left pane reads this to decide whether to render the
/// idle voice-shortcuts tile or the per-display drop picker.
///
/// Using a [Notifier] (not a [StateProvider]) so the lifecycle hooks
/// stay explicit and so the home pane's `select` watch on `!= null`
/// rebuilds only at start / cancel boundaries — not on every icon-
/// bytes resolution that mutates the snapshot.
class AppDragController extends Notifier<DraggedApp?> {
  @override
  DraggedApp? build() => null;

  void start(DraggedApp app) => state = app;
  void clear() => state = null;
}

final appDragControllerProvider =
    NotifierProvider<AppDragController, DraggedApp?>(AppDragController.new);
