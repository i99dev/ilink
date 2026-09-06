library;

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'package:ilink/features/voice/state/voice_interactive_gate.dart';

Future<SelectResult?> showVoiceToolSelectSheet(
  BuildContext context, {
  required VoiceToolDef tool,
  required Map<String, dynamic> args,
}) async {
  final options = _parseOptions(args);
  // Defensive: an empty options list would render a blank sheet
  // and the user could only dismiss → cancelled. Better to fast-
  // path that case.
  if (options.isEmpty) return null;
  final title = (args['title'] as String?)?.trim().isNotEmpty == true
      ? args['title'] as String
      : (tool.description.trim().isNotEmpty
            ? tool.description.trim()
            : tool.name);

  return showModalBottomSheet<SelectResult>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withAlpha(140),
    isScrollControlled: true,
    builder: (ctx) => _SelectSheet(title: title, options: options),
  );
}

class _Option {
  const _Option({required this.id, required this.label, this.subtitle});
  final String id;
  final String label;
  final String? subtitle;
}

List<_Option> _parseOptions(Map<String, dynamic> args) {
  final raw = args['options'];
  if (raw is! List) return const [];
  final out = <_Option>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final id = (item['id'] as Object?)?.toString();
    final label = (item['label'] as Object?)?.toString();
    if (id == null || id.isEmpty || label == null || label.isEmpty) continue;
    final subtitle = (item['subtitle'] as Object?)?.toString();
    out.add(_Option(id: id, label: label, subtitle: subtitle));
  }
  return out;
}

class _SelectSheet extends StatelessWidget {
  const _SelectSheet({required this.title, required this.options});
  final String title;
  final List<_Option> options;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
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
                      Icons.touch_app_rounded,
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
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _OptionTile(option: options[i]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option});
  final _Option option;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(
          context,
        ).pop(SelectResult(id: option.id, label: option.label)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (option.subtitle != null &&
                        option.subtitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle!,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
