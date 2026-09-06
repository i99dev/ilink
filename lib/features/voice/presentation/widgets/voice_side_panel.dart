/// Shared end-anchored side panel for voice-tool results.
///
/// Replaces the bottom-sheet presentation: results now slide in from
/// the screen's END edge (right in LTR, left in RTL — automatic via
/// [Directionality]), which reads better on the wide landscape head
/// unit than a sheet covering the bottom. One frame, many contents:
/// every tool renders its own widget *inside* this frame via
/// [showVoiceSidePanel], so the chrome (slide animation, scrim,
/// drag-to-dismiss, close button, optional auto-dismiss, safe area) is
/// defined once and stays consistent.
///
/// Stacking gives master→detail for free: a list panel's row taps
/// ``showVoiceSidePanel(... PlaceDetail …)`` which stacks over the list;
/// closing the detail returns to the list.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';

/// Default panel width on the head unit. Wide enough for a readable
/// list card + actions, narrow enough to leave the map/home visible.
const double kVoiceSidePanelWidth = 400;

/// Show [child] as an end-anchored side panel. Returns when dismissed
/// (scrim tap, drag-to-end, close button, auto-dismiss, or the child
/// calling ``Navigator.of(context).pop()``).
///
/// [autoDismiss] closes the panel after the duration (for glanceable
/// results like a weather card); omit for interactive content (a list
/// the driver scans) so it stays until dismissed.
Future<T?> showVoiceSidePanel<T>(
  BuildContext context, {
  required Widget child,
  double width = kVoiceSidePanelWidth,
  Duration? autoDismiss,
}) {
  final isRtl = Directionality.of(context) == TextDirection.rtl;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, _) => Align(
      alignment: isRtl ? Alignment.centerLeft : Alignment.centerRight,
      child: _VoiceSidePanelFrame(
        width: width,
        autoDismiss: autoDismiss,
        toEnd: isRtl ? -1 : 1,
        child: child,
      ),
    ),
    transitionBuilder: (ctx, anim, _, c) {
      final begin = Offset(isRtl ? -1 : 1, 0);
      return SlideTransition(
        position: Tween<Offset>(
          begin: begin,
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: c,
      );
    },
  );
}

class _VoiceSidePanelFrame extends StatefulWidget {
  const _VoiceSidePanelFrame({
    required this.child,
    required this.width,
    required this.toEnd,
    this.autoDismiss,
  });

  final Widget child;
  final double width;

  /// +1 when the end edge is the right (LTR), -1 when left (RTL). Used
  /// so a drag *toward the end* dismisses regardless of direction.
  final int toEnd;
  final Duration? autoDismiss;

  @override
  State<_VoiceSidePanelFrame> createState() => _VoiceSidePanelFrameState();
}

class _VoiceSidePanelFrameState extends State<_VoiceSidePanelFrame> {
  Timer? _timer;
  double _dragDx = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.autoDismiss;
    if (d != null) {
      _timer = Timer(d, () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onDragEnd(DragEndDetails details) {
    // Dismiss when dragged a third of the way toward the end edge, or
    // flung that way fast.
    final v = details.primaryVelocity ?? 0;
    final draggedToEnd = _dragDx * widget.toEnd;
    final fastToEnd = v * widget.toEnd;
    if (draggedToEnd > widget.width / 3 || fastToEnd > 700) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _dragDx = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: GestureDetector(
          onHorizontalDragUpdate: (d) {
            // Only track drags toward the end edge.
            final next = _dragDx + d.delta.dx;
            setState(
              () => _dragDx = widget.toEnd > 0
                  ? next.clamp(0, widget.width)
                  : next.clamp(-widget.width, 0),
            );
          },
          onHorizontalDragEnd: _onDragEnd,
          child: Transform.translate(
            offset: Offset(_dragDx, 0),
            child: Material(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(22),
              clipBehavior: Clip.antiAlias,
              elevation: 8,
              child: SizedBox(
                width: widget.width,
                height: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Handle(onClose: () => Navigator.of(context).maybePop()),
                    Expanded(child: widget.child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withAlpha(60),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
            icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Small reusable section header used inside panel contents.
class VoicePanelHeader extends StatelessWidget {
  const VoicePanelHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
      child: Row(
        children: [
          Icon(icon, color: AppColors.accent, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Standard scrollable body for a panel's content — one place that owns
/// the content padding so every tool aligns identically. Use under a
/// [VoicePanelHeader] inside the panel's [Column].
class VoicePanelBody extends StatelessWidget {
  const VoicePanelBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: children,
      ),
    );
  }
}

/// The soft-failure / empty message shown when a tool degrades or finds
/// nothing — italic, muted, one consistent treatment across panels.
class VoicePanelMessage extends StatelessWidget {
  const VoicePanelMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        color: cs.onSurfaceVariant,
        fontSize: 14,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}
