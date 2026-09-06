library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';

const Duration _autoDismiss = Duration(seconds: 8);

Future<void> showVoiceToolDisplaySheet(
  BuildContext context, {
  required VoiceToolDef tool,
  required Map<String, dynamic> args,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withAlpha(120),
    isDismissible: true,
    builder: (ctx) => _DisplaySheet(tool: tool, args: args),
  );
}

class _DisplaySheet extends StatefulWidget {
  const _DisplaySheet({required this.tool, required this.args});
  final VoiceToolDef tool;
  final Map<String, dynamic> args;

  @override
  State<_DisplaySheet> createState() => _DisplaySheetState();
}

class _DisplaySheetState extends State<_DisplaySheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_autoDismiss, () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);
    final title = (widget.args['title'] as String?)?.trim().isNotEmpty == true
        ? widget.args['title'] as String
        : (widget.tool.description.trim().isNotEmpty
              ? widget.tool.description.trim()
              : widget.tool.name);
    final body = (widget.args['body'] as String?) ?? '';
    final footer = (widget.args['footer'] as String?) ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: AppColors.accent,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (body.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  body,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
              if (footer.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  footer,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.actionDone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
