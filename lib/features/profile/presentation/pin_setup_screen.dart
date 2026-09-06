import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../state/profile_guard.dart';
import 'widgets/numeric_keypad.dart';
import 'widgets/pin_dots.dart';

/// Two-step setup: enter, then confirm. On match the controller persists
/// the salted hash and pops with `true`. On mismatch we reset to step 1
/// with a transient banner.
class PinSetupScreen extends ConsumerStatefulWidget {
  const PinSetupScreen({super.key});

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

enum _Step { enter, confirm }

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> {
  static const _length = 4;
  _Step _step = _Step.enter;
  String _first = '';
  String _entered = '';
  bool _mismatch = false;

  void _onDigit(String d) {
    if (_entered.length >= _length) return;
    setState(() {
      _entered += d;
      _mismatch = false;
    });
    if (_entered.length == _length) _commit();
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _mismatch = false;
    });
  }

  Future<void> _commit() async {
    if (_step == _Step.enter) {
      setState(() {
        _first = _entered;
        _entered = '';
        _step = _Step.confirm;
      });
      return;
    }
    if (_entered == _first) {
      await ref.read(profileGuardProvider.notifier).enableWithPin(_entered);
      if (!mounted) return;
      final t = S.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.pinSetupSavedSnack)));
      Navigator.of(context).pop(true);
    } else {
      // ignore: unawaited_futures
      HapticFeedback.heavyImpact();
      setState(() {
        _step = _Step.enter;
        _first = '';
        _entered = '';
        _mismatch = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final isEnter = _step == _Step.enter;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: Text(t.profilePinChangeLabel),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  isEnter ? t.pinSetupEnterTitle : t.pinSetupConfirmTitle,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isEnter ? t.pinSetupEnterSubtitle : t.pinSetupConfirmSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
                if (_mismatch) ...[
                  const SizedBox(height: 12),
                  Text(
                    t.pinSetupMismatch,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                PinDots(
                  length: _length,
                  filled: _entered.length,
                  errorState: _mismatch,
                ),
                const SizedBox(height: 28),
                NumericKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
