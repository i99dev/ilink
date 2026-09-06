import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../ondevice/offline_commands.dart';
import '../ondevice/voice_model_catalog.dart';

Future<void> showVoiceCommandsSheet(BuildContext context, WidgetRef ref) {
  final lang =
      ref.read(settingsProvider).value?.voiceModelLang ?? kDefaultVoiceLang;
  final sections = offlineVoiceCommands(langCode: lang);
  // Right-to-left scripts render the whole sheet RTL so Arabic/Persian reads
  // naturally (titles, labels and example alignment all flip).
  final isRtl = lang == 'ar' || lang == 'fa';
  final strings = _stringsByLang[lang] ?? _stringsByLang[kDefaultVoiceLang]!;
  final aiCaps =
      _aiCapabilitiesByLang[lang] ?? _aiCapabilitiesByLang[kDefaultVoiceLang]!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: _VoiceCommandsSheet(
        sections: sections,
        strings: strings,
        aiCaps: aiCaps,
      ),
    ),
  );
}

/// The sheet's own UI copy (not the commands), localized per language. Other
/// languages fall back to English copy; the offline command list itself is
/// still fully localized from the language packs.
class _SheetStrings {
  const _SheetStrings({
    required this.title,
    required this.tabOffline,
    required this.tabAi,
    required this.offlineIntro,
    required this.aiIntro,
    required this.empty,
  });
  final String title;
  final String tabOffline;
  final String tabAi;
  final String offlineIntro;
  final String aiIntro;
  final String empty;
}

const Map<String, _SheetStrings> _stringsByLang = {
  'en-us': _SheetStrings(
    title: 'Voice commands',
    tabOffline: 'Offline',
    tabAi: 'AI Assistant',
    offlineIntro:
        'Say "Hey BYD" then a command — or tap the mic. These run instantly '
        'on the car: free, offline, no AI needed.',
    aiIntro:
        'Say "Hey AI" then talk — or tap the mic. The assistant understands '
        'full sentences and does much more than the fixed commands:',
    empty:
        'No offline commands are available for your voice language yet — '
        '"Hey AI" still works.',
  ),
  'ar': _SheetStrings(
    title: 'الأوامر الصوتية',
    tabOffline: 'بدون إنترنت',
    tabAi: 'المساعد الذكي',
    offlineIntro:
        'قل «يا بايدي» ثم الأمر — أو اضغط على المايك. تعمل فوراً على السيارة: '
        'مجاناً، بدون إنترنت وبدون ذكاء اصطناعي.',
    aiIntro:
        'قل «يا مساعد» ثم تحدّث — أو اضغط على المايك. المساعد يفهم الجمل الكاملة '
        'ويقدر يسوي أكثر بكثير من الأوامر الثابتة:',
    empty: 'لا توجد أوامر بدون إنترنت للغتك بعد — «يا مساعد» لا يزال يعمل.',
  ),
};

class _AiCapability {
  const _AiCapability(this.icon, this.title, this.examples);
  final IconData icon;
  final String title;
  final List<String> examples;
}

const Map<String, List<_AiCapability>> _aiCapabilitiesByLang = {
  'en-us': [
    _AiCapability(Icons.chat_bubble_outline_rounded, 'Just talk naturally', [
      "I'm a bit cold",
      'make it cozy in here',
    ]),
    _AiCapability(Icons.navigation_outlined, 'Navigate anywhere', [
      'take me home',
      'find the nearest charger',
    ]),
    _AiCapability(Icons.music_note_rounded, 'Play music & open apps', [
      'play some jazz on YouTube',
      'open Spotify',
    ]),
    _AiCapability(Icons.auto_awesome_rounded, 'Do several things at once', [
      'close the windows and turn on the ac',
    ]),
    _AiCapability(Icons.help_outline_rounded, 'Ask anything', [
      "what's the weather today",
      'how much range do I have left',
    ]),
  ],
  'ar': [
    _AiCapability(Icons.chat_bubble_outline_rounded, 'تحدث بشكل طبيعي', [
      'أشعر بالبرد',
      'خلي الجو دافئ',
    ]),
    _AiCapability(Icons.navigation_outlined, 'خذني إلى أي مكان', [
      'خذني إلى المنزل',
      'أقرب محطة شحن',
    ]),
    _AiCapability(Icons.music_note_rounded, 'شغّل الموسيقى وافتح التطبيقات', [
      'شغّل جاز على يوتيوب',
      'افتح سبوتيفاي',
    ]),
    _AiCapability(Icons.auto_awesome_rounded, 'نفّذ عدة أوامر دفعة واحدة', [
      'أغلق النوافذ وشغّل المكيف',
    ]),
    _AiCapability(Icons.help_outline_rounded, 'اسأل أي شيء', [
      'ما حالة الطقس اليوم',
      'كم بقي من المدى',
    ]),
  ],
};

class _VoiceCommandsSheet extends StatelessWidget {
  const _VoiceCommandsSheet({
    required this.sections,
    required this.strings,
    required this.aiCaps,
  });
  final List<OfflineCommandSection> sections;
  final _SheetStrings strings;
  final List<_AiCapability> aiCaps;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: ConstrainedBox(
          // Cap height so the list scrolls instead of pushing past the screen.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: DefaultTabController(
              length: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.record_voice_over_rounded,
                        color: AppColors.accent,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          strings.title,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).pop(),
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TabBar(
                    labelColor: AppColors.accent,
                    unselectedLabelColor: cs.onSurfaceVariant,
                    indicatorColor: AppColors.accent,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                    tabs: [
                      Tab(
                        height: 40,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.offline_bolt_rounded, size: 16),
                            const SizedBox(width: 6),
                            Text(strings.tabOffline),
                          ],
                        ),
                      ),
                      Tab(
                        height: 40,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.auto_awesome_rounded, size: 16),
                            const SizedBox(width: 6),
                            Text(strings.tabAi),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: TabBarView(
                      children: [
                        _OfflineTab(sections: sections, strings: strings),
                        _AiTab(caps: aiCaps, strings: strings),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Offline tab — intro + the localized, derived command list.
class _OfflineTab extends StatelessWidget {
  const _OfflineTab({required this.sections, required this.strings});
  final List<OfflineCommandSection> sections;
  final _SheetStrings strings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 4),
      children: [
        Text(
          strings.offlineIntro,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 13,
            height: 1.3,
          ),
        ),
        if (sections.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              strings.empty,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          )
        else
          for (final s in sections) _SectionBlock(section: s),
      ],
    );
  }
}

class _AiTab extends StatelessWidget {
  const _AiTab({required this.caps, required this.strings});
  final List<_AiCapability> caps;
  final _SheetStrings strings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 4),
      children: [
        Text(
          strings.aiIntro,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 13,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        for (final c in caps) _AiRow(cap: c, cs: cs),
      ],
    );
  }
}

class _AiRow extends StatelessWidget {
  const _AiRow({required this.cap, required this.cs});
  final _AiCapability cap;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accent.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(cap.icon, color: AppColors.accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cap.title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cap.examples.map((e) => '“$e”').join('   ·   '),
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionBlock extends StatelessWidget {
  const _SectionBlock({required this.section});
  final OfflineCommandSection section;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Arabic/Persian has no case + cursive joins, so don't upper-case or
    // letter-space the title (it would break the script's ligatures).
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(
            rtl ? section.title : section.title.toUpperCase(),
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: rtl ? 0 : 0.8,
            ),
          ),
        ),
        for (final cmd in section.commands) _CommandRow(command: cmd, cs: cs),
      ],
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command, required this.cs});
  final OfflineCommand command;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            command.label,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          // Examples read as quoted utterances — what the driver actually says.
          Text(
            command.examples.map((e) => '“$e”').join('   ·   '),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 13,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}
