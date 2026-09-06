import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home/state/installed_apps_provider.dart' show pkgBridgeProvider;
import '../state/cluster_touchpad_controller.dart';
import '../state/cluster_trackpad_controller.dart';
import '../state/relative_trackpad.dart';

// Why this sheet is a RELATIVE trackpad (not a 1:1 absolute pad):
//
// The cluster has no touch digitiser, so the IVI hosts the input surface. A
// laptop-style trackpad — finger drag moves a cursor relatively, tap clicks at
// the cursor — beats absolute mapping on a far, differently-shaped screen: the
// driver isn't blindly poking at a mirrored rectangle, they steer a visible dot.
//
// This is viable because input now rides the centralized `ilink/gesture`
// seam, whose daemon FAST tier injects MotionEvent streams via
// InputManager.injectInputEvent (no per-event `input -d N` shell fork). The
// cursor follows for free; a drag streams real ptr frames.
//
// Text / arbitrary keyevents stay off this sheet: every app window the XDJA
// container projects to the cluster's input layer is NOT_FOCUSABLE, so a key
// event dispatches to the IVI's focused window instead — touch is the reliable
// channel. (BACK is sent as a deliberate two-finger affordance and tolerates
// that imprecision.)

/// Single entry-point for the global cluster touchpad. Resolves the
/// cluster target lazily (one bridge call → `display.list`) and
/// either opens the touchpad sheet or surfaces a "no cluster on
/// this trim" snackbar — callers don't have to special-case the
/// single-display trim.
Future<void> showClusterTouchpadSheet(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final targetAsync = await container.read(
    clusterTouchpadTargetProvider.future,
  );
  if (!context.mounted) return;
  if (targetAsync == null) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('No driver cluster on this car — nothing to control.'),
        duration: Duration(seconds: 3),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // CRITICAL: a modal sheet is drag-to-dismiss by default and its vertical-
    // drag recognizer would win the gesture arena over the pad's raw
    // [Listener], so a downward swipe would drag the sheet instead of moving
    // the cursor. Disable drag-to-dismiss; the sheet still closes via Close,
    // the scrim tap, or back.
    enableDrag: false,
    builder: (_) => _ClusterTouchpadSheet(target: targetAsync),
  );
}

class _ClusterTouchpadSheet extends ConsumerStatefulWidget {
  const _ClusterTouchpadSheet({required this.target});

  final ClusterTouchpadTarget target;

  @override
  ConsumerState<_ClusterTouchpadSheet> createState() =>
      _ClusterTouchpadSheetState();
}

class _ClusterTouchpadSheetState extends ConsumerState<_ClusterTouchpadSheet> {
  late final ClusterTouchpadForwarder _fw;
  late final ClusterTrackpadController _ctl;

  /// Cursor position as a 0…1 fraction of the cluster, for the on-pad dot.
  final ValueNotifier<Offset> _cursorFrac = ValueNotifier(
    const Offset(0.5, 0.5),
  );

  /// Which injection tier last handled a gesture — `daemon` (FAST), `a11y`, or
  /// `adb`. Drives the header chip so on-car triage can confirm the FAST path
  /// without logcat. Null until the first gesture lands.
  final ValueNotifier<String?> _activeTier = ValueNotifier(null);

  Size _padSize = Size.zero;
  bool _busy = false;
  String? _statusText;
  bool _statusIsError = false;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    final gesture = ref.read(clusterGestureBridgeProvider);
    final pkg = ref.read(pkgBridgeProvider);
    _fw = ClusterTouchpadForwarder(gesture, pkg, widget.target);
    _ctl = ClusterTrackpadController(
      forwarder: _fw,
      trackpad: RelativeTrackpad(
        width: widget.target.width,
        height: widget.target.height,
      ),
    );
    // Paint the cluster cursor as soon as the sheet mounts — the driver glances
    // at the cluster the moment it opens; the dot needs to already be there.
    // ignore: unawaited_futures
    _ctl.begin();
  }

  @override
  void dispose() {
    // ignore: unawaited_futures
    _ctl.end();
    _cursorFrac.dispose();
    _activeTier.dispose();
    super.dispose();
  }

  void _publishCursor() {
    final t = widget.target;
    if (t.width <= 0 || t.height <= 0) return;
    _cursorFrac.value = Offset(
      _ctl.cursor.dx / t.width,
      _ctl.cursor.dy / t.height,
    );
  }

  void _onPointerDown(PointerDownEvent e) {
    if (_busy) return;
    HapticFeedback.selectionClick();
    // ignore: unawaited_futures
    _ctl.pointerDown(e.pointer, e.localPosition, _nowMs);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_busy) return;
    // ignore: unawaited_futures
    _ctl.pointerMove(e.pointer, e.localPosition, _padSize, _nowMs).then((_) {
      _publishCursor();
    });
  }

  Future<void> _onPointerUp(PointerUpEvent e) async {
    final action = await _ctl.pointerUp(e.pointer, _nowMs);
    _publishCursor();
    if (!mounted) return;
    if (_fw.lastPath != null) _activeTier.value = _fw.lastPath;
    final base = switch (action) {
      TrackpadAction.tap => 'Click',
      TrackpadAction.back => 'Back',
      TrackpadAction.dragEnd => _fw.streamingAvailable ? 'Scroll' : 'Swipe',
      TrackpadAction.none => null,
    };
    if (base != null) {
      final tier = _fw.lastPath;
      setState(() {
        _statusText = tier != null ? '$base · via $tier' : base;
        _statusIsError = false;
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    // ignore: unawaited_futures
    _ctl.pointerCancel(e.pointer);
  }

  Future<void> _clearCluster() async {
    setState(() {
      _busy = true;
      _statusText = null;
    });
    try {
      final ok = await _fw.clearCluster();
      if (!mounted) return;
      // clusterClear repaints a blank ClusterActivity on every cluster display,
      // which can wipe the cursor overlay — re-establish it.
      // ignore: unawaited_futures
      _fw.showCursor();
      // ignore: unawaited_futures
      _fw.moveCursor(_ctl.cursor.dx.round(), _ctl.cursor.dy.round());
      setState(() {
        _busy = false;
        _statusText = ok ? 'Cluster cleared' : 'Could not clear cluster';
        _statusIsError = !ok;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusText = e.toString();
        _statusIsError = true;
      });
    }
  }

  /// Open the "how to use the touchpad" guide as a sheet over this one.
  void _showTouchpadHelp(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _TouchpadHelpSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final maxPadWidth = media.size.width - 48;
    final maxPadHeight = media.size.height * 0.55;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.ads_click, color: cs.tertiary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${widget.target.label} trackpad',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.target.width}×${widget.target.height} · '
                        'move = cursor · tap = click · 2-finger = scroll / back',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<String?>(
                  valueListenable: _activeTier,
                  builder: (_, tier, _) =>
                      tier == null ? const SizedBox.shrink() : _TierChip(tier),
                ),
                IconButton(
                  icon: const Icon(Icons.help_outline),
                  tooltip: 'How to use the touchpad',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showTouchpadHelp(context),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Close'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxPadWidth,
                  maxHeight: maxPadHeight,
                ),
                child: AspectRatio(
                  aspectRatio: widget.target.aspectRatio,
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      _padSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return _TouchpadSurface(
                        busy: _busy,
                        cursorFrac: _cursorFrac,
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        onPointerCancel: _onPointerCancel,
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Clear cluster',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    onPressed: _busy ? null : _clearCluster,
                  ),
                ),
              ],
            ),
            if (_statusText != null) ...[
              const SizedBox(height: 10),
              Text(
                _statusText!,
                style: TextStyle(
                  color: _statusIsError ? cs.error : cs.onSurfaceVariant,
                  fontSize: 12,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Header badge naming the active injection tier so on-car triage can confirm
/// the FAST path at a glance: green = `daemon` (injectInputEvent), amber =
/// `a11y` (dispatchGesture fallback), orange = `adb` (`input -d N`).
class _TierChip extends StatelessWidget {
  const _TierChip(this.tier);

  final String tier;

  @override
  Widget build(BuildContext context) {
    final (MaterialColor bg, String label) = switch (tier) {
      'daemon' => (Colors.green, 'FAST'),
      'a11y' => (Colors.amber, 'a11y'),
      'adb' => (Colors.orange, 'adb'),
      _ => (Colors.grey, tier),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bg.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: bg.shade700,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "How to use the touchpad" guide, opened from the sheet's `?` button.
/// One row per gesture — the same model the controller implements
/// (1 finger = move/click, 2 fingers = scroll/back) plus the recovery action.
class _TouchpadHelpSheet extends StatelessWidget {
  const _TouchpadHelpSheet();

  static const _gestures = <(IconData, String, String)>[
    (
      Icons.touch_app_outlined,
      'Move the cursor',
      'Drag one finger — the cursor on the cluster follows, laptop-trackpad style.',
    ),
    (
      Icons.ads_click,
      'Click',
      'Tap once with one finger to click wherever the cursor is.',
    ),
    (
      Icons.swipe_vertical,
      'Scroll',
      'Put two fingers down and drag to scroll the cluster content. '
          'Drag up to scroll down, down to scroll up.',
    ),
    (
      Icons.arrow_back,
      'Back',
      'Tap with two fingers (no movement) to send the Back key.',
    ),
    (
      Icons.cleaning_services_outlined,
      'Clear cluster',
      'If the cluster freezes on an old frame, tap "Clear cluster" to repaint it.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, color: cs.tertiary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Using the touchpad',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Got it'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final (icon, title, desc) in _gestures)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: cs.tertiary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            desc,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Raw-pointer touchpad surface. Wraps the gesture area in [Listener] — NOT
/// [GestureDetector] — because we need raw multi-pointer down/move/up with no
/// recognizer claiming the arena (a pure tap never reaches `onPanStart`, and we
/// classify tap-vs-drag-vs-two-finger ourselves). The live dot mirrors the
/// cluster cursor so the driver gets feedback on the IVI too.
class _TouchpadSurface extends StatelessWidget {
  const _TouchpadSurface({
    required this.busy,
    required this.cursorFrac,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  final bool busy;
  final ValueListenable<Offset> cursorFrac;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerMoveEvent) onPointerMove;
  final Future<void> Function(PointerUpEvent) onPointerUp;
  final void Function(PointerCancelEvent) onPointerCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.45),
          width: 1.5,
        ),
      ),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onPointerDown,
        onPointerMove: onPointerMove,
        onPointerUp: onPointerUp,
        onPointerCancel: onPointerCancel,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _CrosshairPainter(
                  color: cs.outlineVariant.withValues(alpha: 0.25),
                ),
              ),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _CursorDotPainter(
                    cursorFrac: cursorFrac,
                    color: cs.primary,
                  ),
                ),
              ),
            ),
            if (busy)
              Positioned(
                top: 8,
                right: 8,
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  _CrosshairPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      p,
    );
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      p,
    );
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.color != color;
}

/// Live dot mirroring the cluster cursor. Repaints off the [cursorFrac]
/// listenable (no setState churn on the whole sheet per move frame).
class _CursorDotPainter extends CustomPainter {
  _CursorDotPainter({required this.cursorFrac, required this.color})
    : super(repaint: cursorFrac);

  final ValueListenable<Offset> cursorFrac;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final f = cursorFrac.value;
    final c = Offset(f.dx * size.width, f.dy * size.height);
    canvas.drawCircle(c, 9, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(c, 5, Paint()..color = color);
    canvas.drawCircle(
      c,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_CursorDotPainter old) => old.color != color;
}
