import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/access/bubble_overlay.dart';

/// Top-bar icon button that minimizes ilink to a floating "chat
/// head" bubble. Captures the rendered button's screen-space
/// coordinates so the native overlay anchors the bubble where the
/// button used to be (unless the user has dragged it before, in which
/// case the native side restores the persisted position instead).
class BubbleToggleButton extends ConsumerStatefulWidget {
  const BubbleToggleButton({super.key});

  @override
  ConsumerState<BubbleToggleButton> createState() => _BubbleToggleButtonState();
}

class _BubbleToggleButtonState extends ConsumerState<BubbleToggleButton> {
  // Held in state (not as a const field) because GlobalKeys must be
  // unique per instance; constructing a fresh one in build() would
  // detach the old key on every rebuild.
  final GlobalKey _buttonKey = GlobalKey();

  Future<void> _onTap() async {
    // RenderBox lookup gives us the button's top-left in logical
    // pixels; multiply by devicePixelRatio for the WindowManager
    // native coordinate space.
    final ctx = _buttonKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final pos = box.localToGlobal(Offset.zero);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final px = (pos.dx * dpr).round();
    final py = (pos.dy * dpr).round();
    await ref.read(bubbleOverlayChannelProvider).showAndMinimize(x: px, y: py);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Circular touch target so it visually matches the floating bubble
    // it spawns. Width/height stay at 44dp (Material minimum touch
    // target); borderRadius = half-side makes the circle.
    return InkWell(
      key: _buttonKey,
      onTap: _onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.picture_in_picture_alt_outlined,
          color: cs.onSurfaceVariant,
          size: 22,
        ),
      ),
    );
  }
}
