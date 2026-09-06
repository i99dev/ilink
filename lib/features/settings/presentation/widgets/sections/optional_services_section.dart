import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/services/optional_services.dart';

class OptionalServicesSection extends ConsumerWidget {
  const OptionalServicesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(optionalServicesProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Optional Services',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Vehicle controls and local data work on this device. '
            'These services require internet and are off until you enable them. '
            'Analytics and tracking are not included.',
          ),
        ),
        for (final service in OptionalService.values)
          SwitchListTile(
            key: ValueKey('optional-service-${service.name}'),
            title: Text(_labels[service]!.$1),
            subtitle: Text(_labels[service]!.$2),
            value: settings.value?.contains(service) ?? false,
            onChanged: settings.isLoading
                ? null
                : (enabled) async {
                    try {
                      await ref
                          .read(optionalServicesProvider.notifier)
                          .setEnabled(service, enabled);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not save this setting. Please try again.',
                            ),
                          ),
                        );
                      }
                    }
                  },
          ),
      ],
    );
  }
}

const _labels = <OptionalService, (String, String)>{
  OptionalService.downloads: (
    'Catalogs and downloads',
    'Retrieve additional vehicle apps, themes and voice models. Installed content stays on this device.',
  ),
  OptionalService.streaming: (
    'Radio and TV streaming',
    'Allow internet playback. Local playlists remain available.',
  ),
  OptionalService.updates: (
    'GitHub updates',
    'Check GitHub Releases and download an update to this device. Installation still requires confirmation.',
  ),
};
