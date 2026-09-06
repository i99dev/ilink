import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_config.dart';

/// Local build configuration, supplied once at app startup.
final appConfigBaseProvider = Provider<AppConfig>((_) {
  throw StateError(
    'Override appConfigBaseProvider with AppConfig.fromEnvironment().',
  );
});
final appConfigProvider = Provider<AppConfig>(
  (ref) => ref.watch(appConfigBaseProvider),
);
final powertrainProvider = Provider<Powertrain>((_) => Powertrain.phev);
