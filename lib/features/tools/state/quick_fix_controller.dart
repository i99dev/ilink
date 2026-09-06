import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/quick_fix_action.dart';

/// Centralized run-state for the Doctor sheet: `actionId → QuickFixRunState`.
///
/// One place owns the idle→running→ok/failed transitions so the sheet
/// rows stay dumb and the behavior is unit-testable. A finished result
/// auto-clears back to idle after [_resultLinger] so a stale ✓/✗ doesn't
/// linger if the sheet is reopened. Re-entrancy is guarded — tapping a
/// running action is a no-op.
class QuickFixController extends Notifier<Map<String, QuickFixRunState>> {
  static const Duration _resultLinger = Duration(seconds: 4);

  @override
  Map<String, QuickFixRunState> build() => const {};

  QuickFixRunState stateFor(String id) => state[id] ?? QuickFixRunState.idle;

  Future<void> run(QuickFixAction action) async {
    if (stateFor(action.id).status == QuickFixStatus.running) return;
    _set(action.id, const QuickFixRunState(status: QuickFixStatus.running));

    QuickFixResult result;
    try {
      result = await action.run(ref);
    } catch (_) {
      result = const QuickFixResult.failed();
    }
    _set(
      action.id,
      QuickFixRunState(
        status: result.ok ? QuickFixStatus.ok : QuickFixStatus.failed,
        count: result.count,
      ),
    );

    Future.delayed(_resultLinger, () {
      // Don't wipe a re-run that started during the linger window.
      if (state[action.id]?.status != QuickFixStatus.running) {
        _set(action.id, QuickFixRunState.idle);
      }
    });
  }

  void _set(String id, QuickFixRunState s) {
    state = {...state, id: s};
  }
}

final quickFixControllerProvider =
    NotifierProvider<QuickFixController, Map<String, QuickFixRunState>>(
      QuickFixController.new,
    );
