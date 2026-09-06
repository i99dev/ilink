import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class InstallIdController extends AsyncNotifier<String> {
  static const _kKey = 'install_id';
  static const _uuid = Uuid();

  @override
  Future<String> build() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}';
    await prefs.setString(_kKey, fresh);
    return fresh;
  }

  /// Wipe the persisted install id. Only called from the
  /// "prepare for new owner" flow — ordinary sign-out keeps the
  /// id so a re-pair by the same user recognises the same device.
  /// Invalidates this provider so the next read mints a fresh id
  /// on the new owner's first onboarding step.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
    ref.invalidateSelf();
  }
}

final installIdProvider = AsyncNotifierProvider<InstallIdController, String>(
  InstallIdController.new,
);
