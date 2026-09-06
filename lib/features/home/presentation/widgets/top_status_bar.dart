import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/_car_domain/ui/vehicle_support_header_icon.dart';
import '../../../profile/presentation/widgets/user_avatar_button.dart';
import '../../../radio/domain/radio_state.dart';
import '../../../radio/providers.dart';
import 'connection_chip.dart';

/// Top status bar. Split into sub-widgets so the 1 Hz clock is the ONLY thing
/// rebuilding each tick — the daemon pill and gear are static between
/// state transitions.
class TopStatusBar extends ConsumerWidget {
  const TopStatusBar({super.key, required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          // BubbleToggleButton moved to the bottom shell, beside the
          // floating mic. Putting "minimize to bubble" next to the
          // primary always-visible control (mic) is more reachable
          // for the driver than the far-left of the header was.
          const _Clock(),
          const SizedBox(width: 18),
          const _RadioStopButton(),
          const SizedBox(width: 12),
          // Daemon liveness chip — only renders when not connected, so
          // happy-path stays invisible. SDK provides the stream; the
          // chip subscribes once and renders amber/red on degrade.
          const ConnectionChip(),
          const Spacer(),
          // Vehicle-support tier — icon-only badge that doubles as the
          // shortcut into Diagnostics. Green check = full integration,
          // orange info = stock APIs only, red block = unsupported.
          // Tap opens DiagnosticsPage where any pending action (grant
          // perms, set default home, enable a11y) can be addressed
          // without going through Settings → About first.
          const VehicleSupportHeaderIcon(),
          const SizedBox(width: 12),
          // Device privacy settings.
          const UserAvatarButton(),
          const SizedBox(width: 20),
          _IconBtn(icon: Icons.settings_outlined, onTap: onSettings),
        ],
      ),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _scheduleNextMinute();
  }

  // Schedule a single one-shot timer aligned to the next wall-clock
  // minute boundary instead of waking every second. The displayed
  // minute only changes 60 times per hour anyway, so we used to do
  // 59 wasted wake-ups + setState skips per minute. On the head unit
  // that's measurable battery + CPU, and it keeps the UI isolate
  // quieter for everything else animating.
  void _scheduleNextMinute() {
    final now = DateTime.now();
    final delay = Duration(
      // +50 ms slack so we land just past the boundary, not before.
      milliseconds: ((60 - now.second) * 1000) - now.millisecond + 50,
    );
    _tick = Timer(delay, () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _scheduleNextMinute();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Locale-aware formatting — picks Arabic month/weekday names
    // automatically when the app locale is `ar`. Falls back to the
    // base language if symbol data for the full tag isn't loaded yet
    // (common on web where google_fonts + intl init can race).
    final languageCode = Localizations.localeOf(context).languageCode;
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    String day;
    String date;
    try {
      day = DateFormat('EEE', languageCode).format(_now);
      date = DateFormat('d MMM', languageCode).format(_now);
    } catch (_) {
      day = DateFormat('EEE').format(_now);
      date = DateFormat('d MMM').format(_now);
    }
    return Row(
      children: [
        Text(
          '$hh:$mm',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w300,
            letterSpacing: 1,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(width: 14),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(day.toUpperCase(), style: _labelStyle(cs)),
            Text(date, style: TextStyle(fontSize: 12, color: cs.outline)),
          ],
        ),
      ],
    );
  }
}

class _RadioStopButton extends ConsumerWidget {
  const _RadioStopButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      radioControllerProvider.select(
        (s) => s is RadioPlaying || s is RadioLoading || s is RadioPaused,
      ),
    );
    if (!active) return const SizedBox.shrink();
    return InkWell(
      onTap: () => ref.read(radioControllerProvider.notifier).stop(),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.error.withAlpha(40),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.error),
        ),
        child: const Icon(Icons.stop_rounded, color: AppColors.error, size: 22),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: cs.onSurfaceVariant, size: 22),
      ),
    );
  }
}

TextStyle _labelStyle(ColorScheme cs) => TextStyle(
  fontSize: 12,
  color: cs.onSurfaceVariant,
  letterSpacing: 2,
  fontWeight: FontWeight.w600,
);
