import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../state/local_profile_provider.dart';
import '../state/profile_guard.dart';
import 'widgets/avatar_circle.dart';
import 'widgets/numeric_keypad.dart';
import 'widgets/pin_dots.dart';

/// Stands between the avatar tap and Profile when PIN is enabled. Pops
/// `true` on a correct PIN; the caller pushes Profile in response.
class PinLockScreen extends ConsumerStatefulWidget {
  const PinLockScreen({super.key});

  @override
  ConsumerState<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends ConsumerState<PinLockScreen>
    with SingleTickerProviderStateMixin {
  static const _length = 4;
  String _entered = '';
  bool _wrong = false;
  late final AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_entered.length >= _length) return;
    setState(() {
      _entered += d;
      _wrong = false;
    });
    if (_entered.length == _length) _verify();
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _wrong = false;
    });
  }

  Future<void> _verify() async {
    final ok = ref.read(profileGuardProvider.notifier).verify(_entered);
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    // ignore: unawaited_futures
    HapticFeedback.heavyImpact();
    // ignore: unawaited_futures
    _shake.forward(from: 0);
    setState(() {
      _wrong = true;
      _entered = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final initials = ref.watch(
      localProfileProvider.select((a) => a.value?.initials ?? ''),
    );
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AvatarCircle(initials: initials, size: 72),
                const SizedBox(height: 18),
                Text(
                  t.pinLockTitle,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t.pinLockSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
                if (_wrong) ...[
                  const SizedBox(height: 12),
                  Text(
                    t.pinLockWrong,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    final dx = _shake.value == 0
                        ? 0.0
                        : 8 *
                              (1 - _shake.value) *
                              (_shake.value * 8 % 2 < 1 ? 1 : -1);
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: child,
                    );
                  },
                  child: PinDots(
                    length: _length,
                    filled: _entered.length,
                    errorState: _wrong,
                  ),
                ),
                const SizedBox(height: 28),
                NumericKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
                const SizedBox(height: 18),
                TextButton(
                  onPressed: () => _showForgotSheet(context, t),
                  child: Text(
                    t.pinLockForgotCta,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showForgotSheet(BuildContext context, S t) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.pinLockForgotTitle,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t.pinLockForgotBody,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t.actionGotIt),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
