import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/profile_guard.dart';
import '../pin_lock_screen.dart';
import '../profile_screen.dart';
import 'avatar_circle.dart';

class UserAvatarButton extends ConsumerWidget {
  const UserAvatarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    const initials = '';
    final dotColor = cs.primary;
    return InkWell(
      onTap: () => _openProfile(context, ref),
      borderRadius: BorderRadius.circular(40),
      child: Tooltip(
        message: 'Device profile',
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              const AvatarCircle(initials: initials, size: 40),
              Positioned(
                right: 0,
                bottom: 0,
                child: _StatusDot(color: dotColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openProfile(BuildContext context, WidgetRef ref) async {
    final pinEnabled =
        ref.read(profileGuardProvider).value?.pinEnabled ?? false;
    if (!pinEnabled) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
      return;
    }
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const PinLockScreen(),
      ),
    );
    if (ok != true || !context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: cs.surface, width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(120),
            blurRadius: 6,
            spreadRadius: 0.5,
          ),
        ],
      ),
    );
  }
}
