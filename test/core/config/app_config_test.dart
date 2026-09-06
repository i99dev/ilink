import 'package:ilink/kernel/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises the default-value path and enum parsers. The full matrix of
// --dart-define values is covered in integration tests (those set defines
// at the command line); unit tests can only verify behaviour under the
// compile-time state of the test binary itself.
void main() {
  group('AppConfig.fromEnvironment (defaults)', () {
    final cfg = AppConfig.fromEnvironment();

    test('env defaults to dev', () {
      expect(cfg.env, AppEnv.dev);
      expect(cfg.isDev, isTrue);
      expect(cfg.isProd, isFalse);
    });

    test('log level defaults to debug', () {
      expect(cfg.logLevel, LogLevel.debug);
    });

    test('daemon host/port match the legacy hardcodes', () {
      expect(cfg.daemonHost, '127.0.0.1');
      expect(cfg.daemonPort, 58733);
      expect(cfg.adbdPort, 5555);
    });

    test('powertrain defaults to phev (Leopard 8)', () {
      expect(cfg.powertrain, Powertrain.phev);
      expect(cfg.powertrain.hasBattery, isTrue);
      expect(cfg.powertrain.hasFuelTank, isTrue);
    });
  });

  group('Powertrain.parse', () {
    test('maps known propulsion families case-insensitively', () {
      expect(Powertrain.parse('ev'), Powertrain.ev);
      expect(Powertrain.parse('BEV'), Powertrain.ev);
      expect(Powertrain.parse('ice'), Powertrain.ice);
      expect(Powertrain.parse('Fuel'), Powertrain.ice);
      expect(Powertrain.parse('petrol'), Powertrain.ice);
      expect(Powertrain.parse('phev'), Powertrain.phev);
    });

    test('unknown values fall back to phev', () {
      expect(Powertrain.parse(''), Powertrain.phev);
      expect(Powertrain.parse('hybrid'), Powertrain.phev);
      expect(Powertrain.parse('nonsense'), Powertrain.phev);
    });

    test('hasBattery / hasFuelTank reflect the family', () {
      expect(Powertrain.ev.hasBattery, isTrue);
      expect(Powertrain.ev.hasFuelTank, isFalse);
      expect(Powertrain.ice.hasBattery, isFalse);
      expect(Powertrain.ice.hasFuelTank, isTrue);
    });
  });

  group('AppEnv.parse', () {
    test('accepts prod aliases', () {
      expect(AppEnv.parse('prod'), AppEnv.prod);
      expect(AppEnv.parse('production'), AppEnv.prod);
      expect(AppEnv.parse('PROD'), AppEnv.prod);
    });

    test('falls back to dev for unknown values', () {
      expect(AppEnv.parse('staging'), AppEnv.dev);
      expect(AppEnv.parse(''), AppEnv.dev);
      expect(AppEnv.parse('nonsense'), AppEnv.dev);
    });
  });

  group('LogLevel.parse', () {
    test('maps known levels case-insensitively', () {
      expect(LogLevel.parse('debug'), LogLevel.debug);
      expect(LogLevel.parse('INFO'), LogLevel.info);
      expect(LogLevel.parse('warn'), LogLevel.warn);
      expect(LogLevel.parse('warning'), LogLevel.warn);
      expect(LogLevel.parse('error'), LogLevel.error);
    });

    test('unknown values fall back to debug', () {
      expect(LogLevel.parse('verbose'), LogLevel.debug);
      expect(LogLevel.parse(''), LogLevel.debug);
    });
  });
}
