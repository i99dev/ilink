import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/responsive/breakpoints.dart';
import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/settings/app_settings.dart';
import '../../registry/settings_section.dart';
import '../widgets/sections/models_section.dart';
import '../widgets/settings_section_rail.dart';

/// Master-detail Settings shell. Left rail of sections on expanded/
/// ultrawide, top tabs on compact. Parent owns the edit controllers
/// (text fields) and the draft for non-text state so every section is
/// a dumb renderer.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.isFirstRun = false,
    this.initialSectionId,
  });

  final bool isFirstRun;

  /// Open directly on this section (e.g. 'appearance' for the voice settings)
  /// instead of the first one. Ignored if it isn't a known section id.
  final String? initialSectionId;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late ModelsDraft _modelsDraft;
  late AppSettings _baseline;

  late String _currentId =
      (widget.initialSectionId != null &&
          settingsSectionRegistry.containsKey(widget.initialSectionId))
      ? widget.initialSectionId!
      : settingsSectionRegistry.keys.first;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final current = ref.read(settingsProvider).value ?? AppSettings.empty;
    _modelsDraft = ModelsDraft(
      voiceAssistantEnabled: current.voiceAssistantEnabled,
    );
    _baseline = current;
  }

  /// Apply the local voice edit to live settings so other sections keep their changes.
  AppSettings _buildDraft() {
    final live = ref.read(settingsProvider).value ?? _baseline;
    return live.copyWith(
      voiceAssistantEnabled: _modelsDraft.voiceAssistantEnabled,
    );
  }

  void _markDirty() {
    final dirty =
        _modelsDraft.voiceAssistantEnabled != _baseline.voiceAssistantEnabled;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    final next = _buildDraft();
    setState(() => _saving = true);
    await ref.read(settingsProvider.notifier).save(next);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _baseline = next;
      _dirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(settingsProvider).value;
    if (current != null && !_dirty) {
      _baseline = current;
      _modelsDraft = ModelsDraft(
        voiceAssistantEnabled: current.voiceAssistantEnabled,
      );
    }
    final t = S.of(context);
    // BreakpointProvider lives above DashShell's Scaffold; a pushed
    // MaterialPageRoute lands in a sibling Overlay that doesn't inherit
    // it, so this pushed top-level page self-wraps.
    return BreakpointProvider(
      child: Builder(
        builder: (context) {
          final isCompact = context.bp == Breakpoint.compact;
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.isFirstRun ? t.welcome : t.settingsTitle),
              automaticallyImplyLeading: !widget.isFirstRun,
            ),
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: isCompact
                        ? Column(
                            children: [
                              SettingsSectionTabs(
                                currentId: _currentId,
                                onSelect: (id) =>
                                    setState(() => _currentId = id),
                              ),
                              Expanded(child: _detailPane()),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SettingsSectionRail(
                                currentId: _currentId,
                                onSelect: (id) =>
                                    setState(() => _currentId = id),
                              ),
                              Expanded(child: _detailPane()),
                            ],
                          ),
                  ),
                  _SaveBar(
                    dirty: _dirty,
                    saving: _saving,
                    onSave: _save,
                    firstRunHint: widget.isFirstRun ? t.welcomeHint : null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _detailPane() {
    final spec =
        settingsSectionRegistry[_currentId] ??
        settingsSectionRegistry.values.first;
    final ctx = SettingsSectionContext(
      modelsDraft: _modelsDraft,
      onChanged: _markDirty,
      onDraftChange: (d) {
        setState(() => _modelsDraft = d);
        _markDirty();
      },
    );
    return Builder(builder: (bc) => spec.builder(bc, ctx));
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.dirty,
    required this.saving,
    required this.onSave,
    this.firstRunHint,
  });

  final bool dirty;
  final bool saving;
  final VoidCallback onSave;
  final String? firstRunHint;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              firstRunHint ?? (dirty ? t.saveBarUnsaved : t.saveBarSaved),
              style: TextStyle(
                color: dirty ? AppColors.warning : cs.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: (!dirty || saving) ? null : onSave,
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.save),
          ),
        ],
      ),
    );
  }
}
