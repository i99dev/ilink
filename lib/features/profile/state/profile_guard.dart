import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileGuardState {
  const ProfileGuardState({required this.pinEnabled, this.pinHash});

  final bool pinEnabled;
  final String? pinHash;

  static const empty = ProfileGuardState(pinEnabled: false);

  ProfileGuardState copyWith({bool? pinEnabled, String? pinHash}) =>
      ProfileGuardState(
        pinEnabled: pinEnabled ?? this.pinEnabled,
        pinHash: pinHash ?? this.pinHash,
      );

  @override
  bool operator ==(Object other) =>
      other is ProfileGuardState &&
      other.pinEnabled == pinEnabled &&
      other.pinHash == pinHash;

  @override
  int get hashCode => Object.hash(pinEnabled, pinHash);
}

/// Owns the PIN-lock state for the Profile screen.
///
/// PIN is currently hashed with SHA-256 + per-install salt, persisted in
/// SharedPreferences. Backend-phase TODO: move the salted hash into
/// platform secure storage (Android Keystore / iOS Keychain) and add
/// rate limiting on failed attempts.
class ProfileGuardController extends AsyncNotifier<ProfileGuardState> {
  static const _kEnabled = 'profile_pin_enabled';
  static const _kHash = 'profile_pin_hash';
  static const _kSalt = 'profile_pin_salt';

  late SharedPreferences _prefs;

  @override
  Future<ProfileGuardState> build() async {
    _prefs = await SharedPreferences.getInstance();
    return ProfileGuardState(
      pinEnabled: _prefs.getBool(_kEnabled) ?? false,
      pinHash: _prefs.getString(_kHash),
    );
  }

  Future<void> enableWithPin(String pin) async {
    final salt = _ensureSalt();
    final hash = _hash(pin, salt);
    await _prefs.setBool(_kEnabled, true);
    await _prefs.setString(_kHash, hash);
    state = AsyncData(ProfileGuardState(pinEnabled: true, pinHash: hash));
  }

  Future<void> disable() async {
    await _prefs.setBool(_kEnabled, false);
    await _prefs.remove(_kHash);
    await _prefs.remove(_kSalt);
    state = const AsyncData(ProfileGuardState.empty);
  }

  /// Returns true on a correct PIN. Hashing is per-install-salted so a
  /// PIN database leak doesn't expose a rainbow-table-friendly hash.
  bool verify(String pin) {
    final s = state.value;
    if (s == null || !s.pinEnabled || s.pinHash == null) return true;
    final salt = _prefs.getString(_kSalt) ?? '';
    return _hash(pin, salt) == s.pinHash;
  }

  String _ensureSalt() {
    final existing = _prefs.getString(_kSalt);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _prefs.setString(_kSalt, fresh);
    return fresh;
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}

final profileGuardProvider =
    AsyncNotifierProvider<ProfileGuardController, ProfileGuardState>(
      ProfileGuardController.new,
    );
