import 'package:flutter/material.dart';

/// Visual payload the assistant wants to *show* the user while speaking.
/// Each variant is a separate class so the rendering widget's switch is
/// exhaustive — adding a new kind forces the renderer to handle it.
///
/// Kept small and purely descriptive: no `IconData`/colour lookups here
/// beyond what the builder already computed. Widgets turn a variant into
/// pixels; this layer doesn't know what a Flutter widget is.
sealed class AssistantCard {
  const AssistantCard();
}

/// `car_status` readback. Nullable fields mirror the SDK's hot
/// cache — the car hasn't necessarily reported every value yet when
/// the card is built.
class StatusCard extends AssistantCard {
  const StatusCard({
    this.batteryPct,
    this.rangeEvKm,
    this.cabinTempC,
    this.outsideTempC,
    this.doorsLocked,
  });

  final int? batteryPct;
  final int? rangeEvKm;
  final int? cabinTempC;
  final int? outsideTempC;
  final bool? doorsLocked;
}

/// Rendered after a `radio_assistant` delegate call. `action` reflects
/// what the subagent ended up doing (play/pause/stop/next), defaulting
/// to "playing" when the sub-model didn't surface one.
class RadioCard extends AssistantCard {
  const RadioCard({
    required this.stationName,
    this.stationId,
    this.country,
    this.faviconUrl,
    this.action = 'playing',
  });

  final String stationName;
  final String? stationId;
  final String? country;
  final String? faviconUrl;
  final String action;
}

/// Generic "the assistant did this car action" confirmation. Populated
/// from the matching [CarCommand]'s icon / colour / label so it visually
/// agrees with the UI tile the user would tap for the same thing.
class ConfirmationCard extends AssistantCard {
  const ConfirmationCard({
    required this.icon,
    required this.color,
    required this.title,
    this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
}

/// Tool call came back with `{error: ...}` — surface a visible signal
/// instead of silently failing. The driver shouldn't have to inspect
/// the dock or wait for the assistant's audio apology.
class ErrorCard extends AssistantCard {
  const ErrorCard({required this.title, this.detail});

  final String title;
  final String? detail;
}
