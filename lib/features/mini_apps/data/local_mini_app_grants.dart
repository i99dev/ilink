import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mini_app_install_storage.dart';

/// Owner approvals apply only to one exact installed archive, never an app id
/// alone. Legacy installations have no implicit bridge permissions.
class LocalMiniAppGrants {
  LocalMiniAppGrants(this._prefs, this._installs);
  final Future<SharedPreferences> Function() _prefs;
  final MiniAppInstallStorage _installs;

  String _key(String id, String hash) => 'mini_apps.scope_grant.$id.$hash';

  Future<void> approve(String id, String hash, Set<String> scopes) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException(
        'Permission approval needs a bundle checksum',
      );
    }
    if (scopes.any((s) => !scopeDescriptions.containsKey(s))) {
      throw const FormatException('Unknown mini-app permission');
    }
    final saved = await (await _prefs()).setString(
      _key(id, hash),
      jsonEncode(scopes.toList()..sort()),
    );
    if (!saved) throw StateError('Could not save mini-app permissions');
  }

  Future<Set<String>?> approved(String id, String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) return null;
    final raw = (await _prefs()).getString(_key(id, hash));
    if (raw == null) return null;
    try {
      final scopes = (jsonDecode(raw) as List).cast<String>().toSet();
      return scopes.every(scopeDescriptions.containsKey) ? scopes : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> allows(String id, String? hash, String scope) async {
    if (hash == null || await _installs.bundleShaFor(id) != hash) return false;
    return (await approved(id, hash))?.contains(scope) ?? false;
  }

  Future<void> revoke(String id, String hash) async {
    await (await _prefs()).remove(_key(id, hash));
  }
}

const scopeDescriptions = <String, String>{
  'car.read': 'Read vehicle signals and identity',
  'car.write': 'Send vehicle commands (vehicle safety checks still apply)',
  'location.read': 'Read precise location',
  'workflow.read': 'Read local automations and action catalog',
  'workflow.write':
      'Create, run and enable automations, including vehicle commands and app launches',
  'voice.read': 'Read voice assistant status',
  'pkg.read': 'Read installed apps and app usage',
  'pkg.launch': 'Launch, move and stop apps',
  'pkg.launch.cluster': 'Launch and move apps on the instrument cluster',
  'display.read': 'Read connected displays',
  'surface.write': 'Create and control app windows',
  'cursor.write': 'Control the pointer',
  'gesture.dispatch': 'Send touch gestures to other apps',
  'boot.write': 'Change apps launched at boot',
};

/// The direct bridge surface uses the same scope vocabulary as native families.
String? directBridgeScope(String handler) {
  if (handler == 'car.command') return 'car.write';
  if (handler.startsWith('car.')) return 'car.read';
  if (handler == 'location.read') return 'location.read';
  if (handler == 'voice.status') return 'voice.read';
  if (handler.startsWith('workflow.')) {
    return const {
          'workflow.catalog',
          'workflow.list',
          'workflow.templates',
          'workflow.myTemplates',
          'workflow.getTemplate',
        }.contains(handler)
        ? 'workflow.read'
        : 'workflow.write';
  }
  return null;
}

final localMiniAppGrantsProvider = Provider<LocalMiniAppGrants>((ref) {
  return LocalMiniAppGrants(
    SharedPreferences.getInstance,
    ref.watch(miniAppInstallStorageProvider),
  );
});
