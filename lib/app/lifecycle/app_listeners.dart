import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Upgrade cleanup removes retired remote credentials without touching user data.
final bootWipeResumeProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('standalone_credentials_removed.v1') == true) return;
  const secure = FlutterSecureStorage();
  for (final key in [
    'mqtt_credentials_v1',
    'auth_tokens_v1',
    'license_v1.meta',
  ]) {
    await secure.delete(key: key);
  }
  for (final key in (await secure.readAll()).keys.where(
    (key) => key.startsWith('account_snapshot.v1.'),
  )) {
    await secure.delete(key: key);
  }
  for (final key in [
    'access_token',
    'refresh_token',
    'user_id',
    'backend_url_override',
    'pending_wipe_state',
  ]) {
    await prefs.remove(key);
  }
  await prefs.setBool('standalone_credentials_removed.v1', true);
});
