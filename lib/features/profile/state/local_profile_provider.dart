import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../kernel/access/domain/car.dart';
import '../../../kernel/access/domain/local_device_profile.dart';
import '../../../kernel/settings/app_settings.dart';

/// Device-local identity used to namespace installed content. No login session.
class LocalProfileController extends AsyncNotifier<LocalDeviceProfile> {
  @override
  Future<LocalDeviceProfile> build() async {
    final settings = await ref.watch(settingsProvider.future);
    return LocalDeviceProfile(
      id: 'local-device',
      displayName: 'This device',
      cars: [Car(deviceId: settings.deviceId, name: 'My vehicle')],
    );
  }
}

final localProfileProvider =
    AsyncNotifierProvider<LocalProfileController, LocalDeviceProfile>(
      LocalProfileController.new,
    );
final currentCarProvider = Provider<Car?>((ref) {
  final cars = ref.watch(localProfileProvider).value?.cars;
  return cars == null || cars.isEmpty ? null : cars.first;
});
