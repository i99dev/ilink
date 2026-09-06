import 'package:flutter/material.dart';

import '../../mini_apps/presentation/widgets/mini_app_remote_image.dart';
import '../domain/native_app.dart';

/// App icon for a native-store row. Loads [NativeApp.iconUrl] via the
/// shared remote-image loader (SVG-aware) and, when the catalog row has no
/// icon, falls back to a colored initial tile instead of a generic glyph —
/// the same affordance app launchers use for iconless packages.
class NativeAppIcon extends StatelessWidget {
  const NativeAppIcon({
    super.key,
    required this.app,
    required this.lang,
    this.size = 48,
  });

  final NativeApp app;
  final String lang;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.24;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: MiniAppRemoteImage(
          url: app.iconUrl,
          fallback: _LetterAvatar(name: app.localizedName(lang), size: size),
        ),
      ),
    );
  }
}

class _LetterAvatar extends StatelessWidget {
  const _LetterAvatar({required this.name, required this.size});
  final String name;
  final double size;

  // A small fixed palette; index by a stable hash of the name so the same
  // app always gets the same color across rebuilds.
  static const _palette = <Color>[
    Color(0xFF5E6AD2),
    Color(0xFF2E9E8F),
    Color(0xFFB5562E),
    Color(0xFF8A5CD1),
    Color(0xFF2F7FB5),
    Color(0xFFB54A78),
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final letter = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    final color = _palette[trimmed.hashCode.abs() % _palette.length];
    return Container(
      color: color,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
