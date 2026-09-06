/// translate panel — source phrase → translated text in the side panel.
library;

import 'package:flutter/material.dart';

import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'voice_result_models.dart';
import 'voice_side_panel.dart';

Future<void> showVoiceTranslatePanel(
  BuildContext context,
  VoiceToolDef tool,
  Map<String, dynamic> args,
) async {
  await showVoiceSidePanel<void>(
    context,
    autoDismiss: const Duration(seconds: 12),
    child: _TranslatePanel(result: TranslateResult.fromArgs(args)),
  );
}

class _TranslatePanel extends StatelessWidget {
  const _TranslatePanel({required this.result});
  final TranslateResult result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(
          icon: Icons.translate_rounded,
          title: 'Translation',
          subtitle: result.languagePair,
        ),
        VoicePanelBody(
          children: [
            if (result.status.degraded)
              VoicePanelMessage(
                result.status.message ?? "Couldn't translate that.",
              )
            else ...[
              if (result.sourceText != null)
                Text(
                  result.sourceText!,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                ),
              const SizedBox(height: 14),
              if (result.translatedText != null)
                Text(
                  result.translatedText!,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }
}
