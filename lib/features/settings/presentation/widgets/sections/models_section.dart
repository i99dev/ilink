import 'package:flutter/material.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../section_scaffold.dart';

/// Pending change to the local voice master switch.
class ModelsDraft {
  const ModelsDraft({required this.voiceAssistantEnabled});
  final bool voiceAssistantEnabled;
  ModelsDraft copyWith({bool? voiceAssistantEnabled}) => ModelsDraft(
    voiceAssistantEnabled: voiceAssistantEnabled ?? this.voiceAssistantEnabled,
  );
}

class ModelsSection extends StatelessWidget {
  const ModelsSection({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onDraftChange,
  });
  final ModelsDraft draft;
  final VoidCallback onChanged;
  final ValueChanged<ModelsDraft> onDraftChange;
  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return SectionScaffold(
      title: t.sectionModelsTitle,
      subtitle: t.modelsSubtitle,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(t.appearanceVoiceEnabledLabel),
        subtitle: Text(t.appearanceVoiceEnabledHelp),
        value: draft.voiceAssistantEnabled,
        onChanged: (enabled) {
          onDraftChange(draft.copyWith(voiceAssistantEnabled: enabled));
          onChanged();
        },
      ),
    );
  }
}
