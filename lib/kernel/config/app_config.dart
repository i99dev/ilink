import 'package:flutter/foundation.dart';

import 'package:ilink/sdk/_internal/logger.dart' show LogLevel;
export 'package:ilink/sdk/_internal/logger.dart' show LogLevel;

/// Compile-time app and vehicle configuration. Individual feature providers
/// own their separate compile-time options, such as GitHub update sources.
@immutable
class AppConfig {
  const AppConfig({
    required this.env,
    required this.mockCar,
    required this.daemonHost,
    required this.daemonPort,
    required this.adbdPort,
    required this.logLevel,
    this.powertrain = Powertrain.phev,
  });

  final AppEnv env;

  final bool mockCar;
  final String daemonHost;
  final int daemonPort;
  final int adbdPort;
  final LogLevel logLevel;

  /// Vehicle powertrain. Set per build via `--dart-define=POWERTRAIN=ev`
  /// (or `ice`); defaults to `phev` because the Leopard 8 — current
  /// production target — is a PHEV. Drives field-level filtering at the
  /// bridge boundary so an EV-only build never surfaces a stray
  /// `range_fuel_km = 0` from VHAL as a "0 km Fuel" breakdown line.
  final Powertrain powertrain;

  bool get isDev => env == AppEnv.dev;
  bool get isProd => env == AppEnv.prod;

  // Built once at startup and stashed in the Riverpod provider. Web builds
  // force [mockCar] (no Kotlin channel exists). `MOCK_MODE` and `NO_CAR`
  // are accepted as legacy aliases so existing local configs keep working.
  factory AppConfig.fromEnvironment() {
    const rawEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');
    const rawLog = String.fromEnvironment('LOG_LEVEL', defaultValue: 'debug');
    const mockCarDefine = bool.fromEnvironment('MOCK_CAR', defaultValue: false);
    const legacyMockMode = bool.fromEnvironment(
      'MOCK_MODE',
      defaultValue: false,
    );
    const legacyNoCar = bool.fromEnvironment('NO_CAR', defaultValue: false);
    const daemonHost = String.fromEnvironment(
      'DAEMON_HOST',
      defaultValue: '127.0.0.1',
    );
    const daemonPort = int.fromEnvironment('DAEMON_PORT', defaultValue: 58733);
    const adbdPort = int.fromEnvironment('ADBD_PORT', defaultValue: 5555);
    const rawPowertrain = String.fromEnvironment(
      'POWERTRAIN',
      defaultValue: 'phev',
    );

    return AppConfig(
      env: AppEnv.parse(rawEnv),
      mockCar: kIsWeb || mockCarDefine || legacyMockMode || legacyNoCar,
      daemonHost: daemonHost,
      daemonPort: daemonPort,
      adbdPort: adbdPort,
      logLevel: LogLevel.parse(rawLog),
      powertrain: Powertrain.parse(rawPowertrain),
    );
  }

  /// Copies local build settings.
  AppConfig copyWith({
    AppEnv? env,
    bool? mockCar,
    String? daemonHost,
    int? daemonPort,
    int? adbdPort,
    LogLevel? logLevel,
    Powertrain? powertrain,
  }) => AppConfig(
    env: env ?? this.env,
    mockCar: mockCar ?? this.mockCar,
    daemonHost: daemonHost ?? this.daemonHost,
    daemonPort: daemonPort ?? this.daemonPort,
    adbdPort: adbdPort ?? this.adbdPort,
    logLevel: logLevel ?? this.logLevel,
    powertrain: powertrain ?? this.powertrain,
  );
}

enum AppEnv {
  dev,
  prod;

  static AppEnv parse(String raw) => switch (raw.toLowerCase()) {
    'prod' || 'production' => AppEnv.prod,
    _ => AppEnv.dev,
  };
}

/// Vehicle propulsion family the build targets. Determines which range
/// signals from VHAL are surfaced to the UI.
///
///   - [phev] — has both a battery + a fuel tank (Leopard 8). Default.
///   - [ev]   — battery-only. Fuel range is dropped to null even if the
///              host echoes 0; prevents "0 km Fuel" appearing in the
///              hero-panel breakdown line.
///   - [ice]  — fuel-only. EV range is dropped to null.
enum Powertrain {
  phev,
  ev,
  ice;

  static Powertrain parse(String raw) => switch (raw.toLowerCase()) {
    'ev' || 'bev' => Powertrain.ev,
    'ice' || 'fuel' || 'petrol' => Powertrain.ice,
    _ => Powertrain.phev,
  };

  bool get hasBattery => this != Powertrain.ice;
  bool get hasFuelTank => this != Powertrain.ev;
}

// LogLevel moved to `lib/sdk/_internal/logger.dart` (SDK boundary
// lockdown 2026-05-13). Re-exported above so existing callers that
// imported `LogLevel` from this file keep working.
