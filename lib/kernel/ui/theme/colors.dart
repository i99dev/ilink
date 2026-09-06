import 'package:flutter/material.dart';

/// Brand palette — context-free constants used for semantic intent
/// (active/destructive/warning/error/info/neutral). These colors are
/// designed to read correctly on both the light and dark surface
/// palettes, so widgets and context-free data structures (command
/// registries, voice tool labels) can reference them without knowing
/// the current [Brightness].
///
/// Surface, text, and divider tones are NOT here — they live on the
/// Material [ColorScheme] built in `app_theme.dart` and must be
/// accessed via `Theme.of(context).colorScheme.*`.
class AppColors {
  const AppColors._();

  // Active / healthy — the "on" state for toggles, confirmed voice,
  // successful actions. Also the M3 `colorScheme.primary` in both modes.
  static const accent = Color(0xFF22D3A8);

  // Destructive / lock — coral used for irreversible actions (door lock,
  // radio stop, emergency). Readable on both dark and light surfaces.
  static const primary = Color(0xFFE94560);

  // Informational — cool blue for neutral metadata and help/auth gates.
  static const secondary = Color(0xFF5B8CFF);

  // Caution — orange for soft warnings (degraded connection, compat
  // quirks, pairing required). Distinct from error.
  static const warning = Color(0xFFF4A261);

  // Hard error — request failed, integrity breach, session revoked.
  static const error = Color(0xFFE76F51);

  // Neutral brand gray for context-free icon tints (command registries,
  // voice tool color fields). Chosen to hit ≥4.5:1 contrast on both the
  // dark scaffold (#07070D) and the light scaffold (#F7F7FA), so a
  // command tile rendered on either mode stays readable.
  static const neutral = Color(0xFF6A7088);
}
