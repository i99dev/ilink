import 'package:flutter/material.dart';

import '../../kernel/registry/action_def.dart';

/// Themed bottom-sheet confirm for destructive actions.
///
/// Three variants driven by [ActionSeverity]:
///   * `safe` — never opens this sheet (call sites short-circuit).
///   * `confirm` — title + body + Cancel/Confirm; the destructive
///     button is enabled immediately.
///   * `typedConfirm` — adds an Input field above the buttons; the
///     destructive button is disabled until the typed value matches
///     the registered `typedToken` (case-insensitive, trimmed).
///
/// Returns `true` if the user confirmed, `false` (or null) if they
/// cancelled or dismissed. Designed so call sites can write
/// `if (await confirm(...) == true) doIt();` without juggling 3-state
/// ternaries.
Future<bool?> showConfirmSheet({
  required BuildContext context,
  required String title,
  required String body,
  required ActionSeverity severity,
  String? confirmLabel,
  String? cancelLabel,
  String? typedToken,
  String? typedTokenHint,
}) {
  if (severity == ActionSeverity.safe) {
    // Caller should short-circuit; we still render a yes/no in case
    // the call site flips severity at runtime, but mark with a hint
    // in debug mode.
    assert(() {
      debugPrint(
        'showConfirmSheet called with ActionSeverity.safe — call '
        'site should short-circuit instead.',
      );
      return true;
    }());
  }
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _ConfirmSheet(
      title: title,
      body: body,
      severity: severity,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      typedToken: typedToken,
      typedTokenHint: typedTokenHint,
    ),
  );
}

class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet({
    required this.title,
    required this.body,
    required this.severity,
    this.confirmLabel,
    this.cancelLabel,
    this.typedToken,
    this.typedTokenHint,
  });

  final String title;
  final String body;
  final ActionSeverity severity;
  final String? confirmLabel;
  final String? cancelLabel;
  final String? typedToken;
  final String? typedTokenHint;

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  final _controller = TextEditingController();
  String _typed = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _tokenSatisfied {
    if (widget.severity != ActionSeverity.typedConfirm) return true;
    final required = widget.typedToken;
    if (required == null) return true;
    return _typed.trim().toUpperCase() == required.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final destructive = widget.severity != ActionSeverity.safe;
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: destructive ? cs.error : cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.body,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (widget.severity == ActionSeverity.typedConfirm &&
              widget.typedToken != null) ...[
            const SizedBox(height: 18),
            if (widget.typedTokenHint != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  widget.typedTokenHint!,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            TextField(
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: widget.typedToken,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace'),
              onChanged: (v) => setState(() => _typed = v),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(widget.cancelLabel ?? 'Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _tokenSatisfied
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: destructive ? cs.error : null,
                    foregroundColor: destructive ? cs.onError : null,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(widget.confirmLabel ?? 'Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
