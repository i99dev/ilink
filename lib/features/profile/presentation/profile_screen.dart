import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../settings/presentation/widgets/section_scaffold.dart';
import '../state/profile_guard.dart';
import 'pin_setup_screen.dart';

/// Local privacy settings; no account or network session is required.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Device profile')),
    body: const SectionScaffold(
      title: 'Device profile',
      subtitle: 'Your settings and vehicle data stay on this device.',
      child: _SecuritySection(),
    ),
  );
}

class _SecuritySection extends ConsumerWidget {
  const _SecuritySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final guard = ref.watch(profileGuardProvider).value;
    final enabled = guard?.pinEnabled ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionDivider(label: t.profileSectionSecurity),
        const SizedBox(height: 6),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: AppColors.accent,
          title: Text(
            t.profilePinEnableLabel,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            t.profilePinEnableSub,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          value: enabled,
          onChanged: (next) async {
            if (next) {
              final ok = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const PinSetupScreen()),
              );
              if (ok != true && context.mounted) {
                // If user cancelled setup leave the toggle off — no-op.
              }
            } else {
              await ref.read(profileGuardProvider.notifier).disable();
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(t.pinDisabledSnack)));
            }
          },
        ),
        if (enabled)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.lock_reset, color: cs.onSurfaceVariant),
            title: Text(
              t.profilePinChangeLabel,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
            ),
            trailing: Icon(Icons.chevron_right, color: cs.outline),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const PinSetupScreen())),
          ),
      ],
    );
  }
}
