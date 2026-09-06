import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/keep_alive_provider.dart';
import '../section_scaffold.dart';

class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionScaffold(
    title: 'Privacy',
    subtitle: 'Your device, your data',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Analytics, audio reporting and location tracking have been removed. '
          'Vehicle controls, voice models and workflows run locally. '
          'Enable a connection separately in Optional Services when you need it.',
        ),
        const SizedBox(height: 20),
        SwitchListTile(
          title: const Text('Keep local controls ready'),
          subtitle: const Text(
            'Keep the device service available in the background. No cloud connection is required.',
          ),
          value: ref.watch(keepAliveProvider).value ?? true,
          onChanged: (value) => ref.read(keepAliveProvider.notifier).set(value),
        ),
      ],
    ),
  );
}
