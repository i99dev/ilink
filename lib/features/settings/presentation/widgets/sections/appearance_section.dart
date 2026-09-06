import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/access/bubble_overlay.dart';
import '../../../../../kernel/ui/theme/colors.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../../kernel/settings/app_settings.dart';
import '../../../../voice/ondevice/command_phrases.dart';
import '../../../../voice/ondevice/moonshine_engine_manager.dart';
import '../../../../voice/ondevice/ondevice_voice_controller.dart';
import '../../../../voice/ondevice/voice_model_catalog.dart';
import '../section_scaffold.dart';

/// Lets the user pick System / Light / Dark plus the driver side
/// (which anchors the floating mic). Persists via
/// `settingsProvider.notifier.save(...)`; `MaterialApp.themeMode` in
/// `main.dart` and the [DashShell]'s mic Positioned both react
/// immediately — no restart / reroute.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final settings = ref.watch(settingsProvider).value;
    final currentTheme = settings?.themeMode ?? AppSettings.defaultThemeMode;
    final currentSide = settings?.driverSide ?? AppSettings.defaultDriverSide;
    final bubbleEnabled =
        settings?.bubbleEnabled ?? AppSettings.defaultBubbleEnabled;
    final voiceEnabled =
        settings?.voiceAssistantEnabled ??
        AppSettings.defaultVoiceAssistantEnabled;
    final wakeWordEnabled = settings?.wakeWordEnabled ?? false;

    final voiceState = ref.watch(onDeviceVoiceControllerProvider);
    final themeRows = <_ThemeRowSpec>[
      _ThemeRowSpec(
        mode: ThemeMode.system,
        icon: Icons.brightness_auto_outlined,
        label: t.appearanceSystem,
        help: t.appearanceSystemHelp,
      ),
      _ThemeRowSpec(
        mode: ThemeMode.light,
        icon: Icons.light_mode_outlined,
        label: t.appearanceLight,
        help: t.appearanceLightHelp,
      ),
      _ThemeRowSpec(
        mode: ThemeMode.dark,
        icon: Icons.dark_mode_outlined,
        label: t.appearanceDark,
        help: t.appearanceDarkHelp,
      ),
    ];
    final sideRows = <_DriverSideRowSpec>[
      _DriverSideRowSpec(
        side: DriverSide.left,
        icon: Icons.format_align_left_rounded,
        label: t.appearanceDriverSideLeft,
        help: t.appearanceDriverSideLeftHelp,
      ),
      _DriverSideRowSpec(
        side: DriverSide.right,
        icon: Icons.format_align_right_rounded,
        label: t.appearanceDriverSideRight,
        help: t.appearanceDriverSideRightHelp,
      ),
    ];
    return SectionScaffold(
      title: t.sectionAppearanceTitle,
      subtitle: t.sectionAppearanceSubtitleShort,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final spec in themeRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _ThemeRow(
                spec: spec,
                active: spec.mode == currentTheme,
                onTap: () => _pickTheme(ref, spec.mode, currentTheme),
              ),
            ),
          const SizedBox(height: 16),
          _SubsectionLabel(label: t.appearanceDriverSideTitle),
          const SizedBox(height: 6),
          for (final spec in sideRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _DriverSideRow(
                spec: spec,
                active: spec.side == currentSide,
                onTap: () => _pickSide(ref, spec.side, currentSide),
              ),
            ),
          const SizedBox(height: 16),
          const _SubsectionLabel(label: 'Floating button'),
          const SizedBox(height: 6),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              bubbleEnabled
                  ? Icons.bubble_chart_rounded
                  : Icons.bubble_chart_outlined,
            ),
            title: const Text('Show floating button'),
            subtitle: const Text(
              'Shows a draggable iLINK button over other apps when the app is '
              'minimized — tap it to jump back. Turn off to hide it.',
            ),
            value: bubbleEnabled,
            onChanged: (next) => _pickBubble(ref, next),
          ),
          const SizedBox(height: 16),
          _SubsectionLabel(label: t.appearanceVoiceSectionTitle),
          const SizedBox(height: 6),
          _VoiceEnabledRow(
            enabled: voiceEnabled,
            onChanged: (next) => _pickVoiceEnabled(ref, next),
          ),
          // Sub-options: only meaningful while voice is on.
          if (voiceEnabled) ...[
            // Hands-free wake word (on-device). Off by default; inert until
            // a Vosk model is provisioned (see VoskModelStore) — the row
            // surfaces the control but the detector only arms with a model.
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hands-free "Hey BYD"'),
              subtitle: const Text(
                'Always-listening wake word, fully on-device. Say "Hey BYD" '
                'then a command. Requires the on-device voice model.',
              ),
              value: wakeWordEnabled,
              onChanged: (next) => _pickWakeWord(ref, next),
            ),
            // Language picker — selects which on-device Vosk model to use;
            // the car downloads it on first use / on switch. Relevant whenever
            // the offline model is used: hands-free wake word OR on-device-only
            // mode (where it's the only engine + we provision it on toggle, so
            // the download progress must be visible here).

            _VoiceLanguageTile(
              lang: settings?.voiceModelLang ?? kDefaultVoiceLang,
              state: voiceState,
              onTap: () => _showLanguagePicker(
                context,
                ref,
                settings?.voiceModelLang ?? kDefaultVoiceLang,
              ),
            ),
            // Optional Arabic dialect engine (Moonshine). The ~31 MB sherpa /
            // ONNX runtime is stripped from the APK and rides in this on-demand
            // bundle; the card lets the driver download it ahead of time or
            // delete it to reclaim disk. Only shown when a fallback exists in
            // the catalog and voice is in use.
            if (MoonshineEngineManager.fallback != null)
              const _MoonshineEngineTile(),
            // Wake-phrase customization — pick a preset or type your own
            // (e.g. an Arabic driver who'd rather say "مرحبا بايدي"). Additive
            // to the built-in "Hey BYD", so the default never stops working.
            if (wakeWordEnabled)
              _WakeWordCustomizer(
                lang: settings?.voiceModelLang ?? kDefaultVoiceLang,
                phrases: settings?.customWakePhrases ?? const [],
              ),
          ],
        ],
      ),
    );
  }

  void _pickTheme(WidgetRef ref, ThemeMode next, ThemeMode current) {
    if (next == current) return;
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    ref.read(settingsProvider.notifier).save(s.copyWith(themeMode: next));
  }

  void _pickSide(WidgetRef ref, DriverSide next, DriverSide current) {
    if (next == current) return;
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    ref.read(settingsProvider.notifier).save(s.copyWith(driverSide: next));
  }

  void _pickBubble(WidgetRef ref, bool next) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    if (s.bubbleEnabled == next) return;
    ref.read(settingsProvider.notifier).save(s.copyWith(bubbleEnabled: next));
    // Native owns the spawn decision (and tears down a live bubble when off).
    unawaited(ref.read(bubbleOverlayChannelProvider).setEnabled(next));
  }

  void _pickVoiceEnabled(WidgetRef ref, bool next) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    if (s.voiceAssistantEnabled == next) return;
    ref
        .read(settingsProvider.notifier)
        .save(s.copyWith(voiceAssistantEnabled: next));
  }

  void _pickWakeWord(WidgetRef ref, bool next) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    if (s.wakeWordEnabled == next) return;
    // The auto-arm provider (watched at the app root) reacts to this and
    // arms/disarms the on-device detector — no direct controller call here.
    ref.read(settingsProvider.notifier).save(s.copyWith(wakeWordEnabled: next));
  }

  Future<void> _showLanguagePicker(
    BuildContext context,
    WidgetRef ref,
    String active,
  ) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Voice language'),
        children: [
          for (final e in voiceModelCatalog)
            ListTile(
              leading: Icon(
                e.langCode == active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text('${e.label} · ${e.nativeLabel}'),
              subtitle: Text(
                '~${e.sizeMb} MB'
                '${isCommandLocalized(e.langCode) ? " · local commands" : " · custom local phrases"}',
              ),
              onTap: () => Navigator.of(ctx).pop(e.langCode),
            ),
        ],
      ),
    );
    if (picked == null || picked == active) return;
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    // Saving voiceModelLang triggers the auto-arm provider to re-provision
    // (download) the new language's model and rebuild the grammar.
    await ref
        .read(settingsProvider.notifier)
        .save(s.copyWith(voiceModelLang: picked));
  }
}

/// "Voice language (on-device)" row — shows the selected language and live
/// download/ready state so the user always knows what's happening:
///   - downloading → a progress bar + "Downloading NN%"
///   - ready/listening → green check
///   - failed → "Download failed — tap to retry"
class _VoiceLanguageTile extends StatelessWidget {
  const _VoiceLanguageTile({
    required this.lang,
    required this.state,
    required this.onTap,
  });

  final String lang;
  final OnDeviceVoiceState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final entry = voiceModelFor(lang);
    // Only reflect status when it's about THIS selected language.
    final forThis = state.lang == lang;
    final downloading =
        forThis && state.status == OnDeviceVoiceStatus.downloading;
    final ready =
        forThis &&
        (state.status == OnDeviceVoiceStatus.armed ||
            state.status == OnDeviceVoiceStatus.listening);
    final failed = forThis && state.status == OnDeviceVoiceStatus.error;
    final pct = state.downloadProgress;

    final base = entry == null
        ? lang
        : '${entry.label} · ${entry.nativeLabel} · ~${entry.sizeMb} MB'
              '${isCommandLocalized(entry.langCode) ? "" : " · custom local phrases"}';

    final String statusLine;
    if (downloading) {
      statusLine = pct == null
          ? 'Downloading model…'
          : 'Downloading model — ${(pct * 100).round()}%';
    } else if (ready) {
      statusLine = 'Ready · listening';
    } else if (failed) {
      statusLine = 'Download failed — tap to retry';
    } else {
      statusLine = 'Tap to change · downloads on first use';
    }

    final Widget trailing;
    if (downloading) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      );
    } else if (ready) {
      trailing = const Icon(Icons.check_circle, color: AppColors.accent);
    } else if (failed) {
      trailing = const Icon(Icons.refresh, color: AppColors.warning);
    } else {
      trailing = const Icon(Icons.chevron_right);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.translate),
          title: const Text('Voice language (on-device)'),
          subtitle: Text('$base\n$statusLine'),
          isThreeLine: true,
          trailing: trailing,
          onTap: onTap,
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(value: pct),
          ),
      ],
    );
  }
}

/// "Arabic Speech Recognition Engine (Moonshine)" card — manages the optional
/// on-demand sherpa-onnx bundle (ONNX model + the ~31 MB `.so` runtime stripped
/// from the APK). States mirror [MoonshineEngineStatus]:
///   - absent      → "Not installed · ~NN MB", Download button
///   - downloading → progress bar + "Downloading NN%"
///   - present     → "Active", Delete button (confirm → frees the disk)
///   - error       → "failed — tap Download to retry"
class _MoonshineEngineTile extends ConsumerWidget {
  const _MoonshineEngineTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fb = MoonshineEngineManager.fallback;
    if (fb == null) return const SizedBox.shrink();
    final state = ref.watch(moonshineEngineManagerProvider);
    final manager = ref.read(moonshineEngineManagerProvider.notifier);
    final downloading = state.status == MoonshineEngineStatus.downloading;
    final present = state.status == MoonshineEngineStatus.present;
    final failed = state.status == MoonshineEngineStatus.error;
    final pct = state.progress;

    final String statusLine;
    if (downloading) {
      statusLine = pct == null
          ? 'Downloading… (~${fb.sizeMb} MB)'
          : 'Downloading — ${(pct * 100).round()}%';
    } else if (present) {
      statusLine = 'Active · enhances dialectal Arabic recognition';
    } else if (failed) {
      statusLine = 'Download failed — tap Download to retry';
    } else {
      statusLine = 'Not installed · ~${fb.sizeMb} MB · optional';
    }

    final Widget trailing;
    if (downloading) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      );
    } else if (present) {
      trailing = TextButton.icon(
        icon: const Icon(Icons.delete_outline, color: AppColors.warning),
        label: const Text('Delete'),
        onPressed: () => _confirmDelete(context, manager, fb.sizeMb),
      );
    } else {
      trailing = TextButton.icon(
        icon: const Icon(Icons.download_outlined),
        label: const Text('Download'),
        onPressed: () => unawaited(manager.download()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            present
                ? Icons.record_voice_over
                : Icons.record_voice_over_outlined,
            color: present ? AppColors.accent : null,
          ),
          title: const Text('Arabic dialect engine (Moonshine)'),
          subtitle: Text(statusLine),
          trailing: trailing,
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(value: pct),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    MoonshineEngineManager manager,
    int sizeMb,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Arabic engine?'),
        content: Text(
          'Frees ~$sizeMb MB. Dialectal Arabic falls back to the standard '
          'engine until you download it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await manager.delete();
  }
}

/// Switch row for the master voice kill-switch. Off → mic surfaces
/// vanish (FloatingMic, home VoiceCard); hardware-key + voice intent
/// no-op. Independent of [voiceVadMode] (PTT vs always-listen) — that
/// sub-mode picks the trigger style WHEN voice is on.
class _VoiceEnabledRow extends StatelessWidget {
  const _VoiceEnabledRow({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final accentColor = enabled ? AppColors.accent : cs.onSurfaceVariant;
    return InkWell(
      onTap: () => onChanged(!enabled),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Icon(
              enabled ? Icons.mic_rounded : Icons.mic_off_rounded,
              size: 22,
              color: accentColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.appearanceVoiceEnabledLabel,
                    style: TextStyle(
                      color: enabled ? AppColors.accent : cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.appearanceVoiceEnabledHelp,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            Switch(value: enabled, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _SubsectionLabel extends StatelessWidget {
  const _SubsectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.outline,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Wake-phrase customizer — lets the driver add their own wake phrases
/// (picked presets + free-text), ADDITIVE to the built-in default. Each
/// phrase must match what the ACTIVE Vosk model emits (its own script, real
/// words in its lexicon), so we surface a guidance line and per-language
/// presets to steer the driver away from the out-of-vocabulary silent-fail
/// trap. Writes [AppSettings.customWakePhrases] (BYD) or
/// [AppSettings.customWakePhrases] (AI); the on-device controller rebuilds
/// its grammar on the next arm.
class _WakeWordCustomizer extends ConsumerWidget {
  const _WakeWordCustomizer({required this.lang, required this.phrases});

  /// Active on-device model language — presets + script guidance key off it.
  final String lang;

  final List<String> phrases;

  /// The built-in wake name shown to the driver ("Hey BYD" / "Hey AI").
  String get _builtIn => 'Hey BYD';

  /// Per-language preset suggestions. BYD uses the curated picker list; AI
  /// reuses the AI wake defaults (already clean, human-readable per language).
  List<String> get _presets =>
      (wakePresetsByLang[lang] ?? wakePresetsByLang['en-us']!);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final presets = _presets;
    // Case-insensitive membership so a preset already added doesn't re-show.
    final added = phrases.map((p) => p.trim().toLowerCase()).toSet();
    final suggestions = [
      for (final p in presets)
        if (!added.contains(p.trim().toLowerCase())) p,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubsectionLabel(label: 'Wake phrase'),
          const SizedBox(height: 6),
          Text(
            'Built-in "$_builtIn" always works. Add your own below — write it '
            'the way you say it, in your voice language\'s script. Made-up '
            'words the model doesn\'t know won\'t trigger.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          if (phrases.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in phrases)
                  InputChip(
                    label: Text(p),
                    onDeleted: () => _remove(ref, p),
                    deleteIcon: const Icon(Icons.close_rounded, size: 16),
                  ),
              ],
            ),
          ],
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'SUGGESTIONS',
              style: TextStyle(
                color: cs.outline,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in suggestions)
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: Text(p),
                    onPressed: () => _add(ref, p),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _showAddDialog(context, ref),
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Add your own'),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _currentOf(AppSettings s) => s.customWakePhrases;

  AppSettings _withList(AppSettings s, List<String> next) =>
      s.copyWith(customWakePhrases: next);

  void _add(WidgetRef ref, String phrase) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return;
    final current = _currentOf(s);
    final exists = current.any(
      (p) => p.trim().toLowerCase() == trimmed.toLowerCase(),
    );
    if (exists) return;
    ref
        .read(settingsProvider.notifier)
        .save(_withList(s, [...current, trimmed]));
  }

  void _remove(WidgetRef ref, String phrase) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    ref
        .read(settingsProvider.notifier)
        .save(_withList(s, _currentOf(s).where((p) => p != phrase).toList()));
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final phrase = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Add a wake phrase'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'e.g. مرحبا بايدي',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
              const SizedBox(height: 10),
              Text(
                'Write it in your voice language\'s script, using real words. '
                'After turning the wake word on, say it to check it triggers.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (phrase != null && phrase.trim().isNotEmpty) _add(ref, phrase);
  }
}

class _ThemeRowSpec {
  const _ThemeRowSpec({
    required this.mode,
    required this.icon,
    required this.label,
    required this.help,
  });
  final ThemeMode mode;
  final IconData icon;
  final String label;
  final String help;
}

class _DriverSideRowSpec {
  const _DriverSideRowSpec({
    required this.side,
    required this.icon,
    required this.label,
    required this.help,
  });
  final DriverSide side;
  final IconData icon;
  final String label;
  final String help;
}

class _DriverSideRow extends StatelessWidget {
  const _DriverSideRow({
    required this.spec,
    required this.active,
    required this.onTap,
  });

  final _DriverSideRowSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelColor = active ? AppColors.accent : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Icon(
              spec.icon,
              size: 22,
              color: active ? AppColors.accent : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.label,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    spec.help,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (active)
              const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.spec,
    required this.active,
    required this.onTap,
  });

  final _ThemeRowSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelColor = active ? AppColors.accent : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Icon(
              spec.icon,
              size: 22,
              color: active ? AppColors.accent : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.label,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    spec.help,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (active)
              const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
