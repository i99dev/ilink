/// Bottom sheet that asks the driver to confirm a consent-required
/// voice tool dispatch (door.unlock, hood.*, sunroof.*, …) before
/// it executes.
///
/// Returns ``true`` when the user taps Allow, ``false`` on Deny or
/// scrim-dismiss. The sheet is **non-dismissable on back-button**
/// (``isDismissible: true`` only via tap-outside) so a stray back
/// press doesn't accidentally allow a destructive action; the
/// implicit answer if the sheet closes any other way is **deny**
/// — safer default for in-car UX.
///
/// Mounting: invoked from the consent gate's ``ConsentPrompter``
/// callback wired in ``broker_voice_controller_provider.dart``.
/// Lives under ``features/voice/presentation`` so the
/// ``core/voice/`` layer stays Flutter-Material-free (the gate
/// itself is pure Dart).
library;

import 'package:flutter/material.dart';

import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/voice/domain/voice_tool_def.dart';

Future<bool> showVoiceToolConsentSheet(
  BuildContext context, {
  required VoiceToolDef tool,
  required Map<String, dynamic> args,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withAlpha(140),
    isDismissible: true,
    builder: (ctx) => _VoiceConsentSheet(tool: tool, args: args),
  );
  return result ?? false;
}

class _VoiceConsentSheet extends StatelessWidget {
  const _VoiceConsentSheet({required this.tool, required this.args});

  final VoiceToolDef tool;
  final Map<String, dynamic> args;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);
    final action = tool.description.trim().isEmpty
        ? tool.name
        : tool.description.trim();
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
                    Icons.security_rounded,
                    color: AppColors.warning,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.voiceConsentTitle,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                t.voiceConsentBody(action),
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(t.voiceConsentDeny),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(t.voiceConsentAllow),
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
