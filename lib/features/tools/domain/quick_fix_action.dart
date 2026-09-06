import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Outcome of a quick-fix run. [count] carries an action-specific tally
/// (e.g. number of apps closed) that the sheet renders into a localized
/// result line — the action stays context-free (so it's unit-testable)
/// and the widget owns all localization.
@immutable
class QuickFixResult {
  const QuickFixResult.ok([this.count]) : ok = true;
  const QuickFixResult.failed() : ok = false, count = null;

  final bool ok;
  final int? count;
}

/// Lifecycle of one action inside the Doctor sheet.
enum QuickFixStatus { idle, running, ok, failed }

@immutable
class QuickFixRunState {
  const QuickFixRunState({this.status = QuickFixStatus.idle, this.count});

  final QuickFixStatus status;
  final int? count;

  static const QuickFixRunState idle = QuickFixRunState();

  @override
  bool operator ==(Object other) =>
      other is QuickFixRunState &&
      other.status == status &&
      other.count == count;

  @override
  int get hashCode => Object.hash(status, count);
}

/// A single one-tap maintenance action in the Doctor sheet.
///
/// Registry-driven (see `quick_fix_registry.dart`) so adding a 4th tool
/// is one row: id + icon + l10n keys + a context-free [run]. [run] takes
/// the [Ref] (not a `BuildContext`) so it can read providers / call
/// native bridges while staying unit-testable; the sheet renders all
/// localization + busy/result UI from the [QuickFixRunState] the
/// controller derives.
@immutable
class QuickFixAction {
  const QuickFixAction({
    required this.id,
    required this.icon,
    required this.labelKey,
    required this.whyKey,
    required this.run,
  });

  /// Stable id — the controller keys run-state by this, and tests assert
  /// on it. Never reuse/rename post-ship.
  final String id;

  final IconData icon;

  /// l10n key for the short button label (resolved in the sheet).
  final String labelKey;

  /// l10n key for the one-line "why this button" explanation (shown as a
  /// visible subtitle AND a long-press tooltip).
  final String whyKey;

  /// Context-free worker. Reads providers / calls bridges via [ref].
  final Future<QuickFixResult> Function(Ref ref) run;
}
