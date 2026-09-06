library;

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';

Future<String?> showVoiceToolInputSheet(
  BuildContext context, {
  required VoiceToolDef tool,
  required Map<String, dynamic> args,
}) {
  return showModalBottomSheet<String?>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withAlpha(140),
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _InputSheet(tool: tool, args: args),
    ),
  );
}

class _InputSheet extends StatefulWidget {
  const _InputSheet({required this.tool, required this.args});
  final VoiceToolDef tool;
  final Map<String, dynamic> args;

  @override
  State<_InputSheet> createState() => _InputSheetState();
}

class _InputSheetState extends State<_InputSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: (widget.args['initial'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    Navigator.of(context).pop(text.isEmpty ? null : text);
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
    final placeholder = (widget.args['placeholder'] as String?) ?? '';
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
                    Icons.edit_rounded,
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
              const SizedBox(height: 14),
              TextField(
                controller: _ctrl,
                autofocus: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: placeholder,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: cs.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.actionCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(t.actionDone),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
