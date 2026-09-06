import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/installed_mini_app_store.dart';
import '../data/local_mini_app_grants.dart';
import '../data/mini_app_install_storage.dart';
import '../domain/mini_app.dart';
import '../state/mini_app_providers.dart';

/// Each checkbox is an explicit local-owner grant for these exact bytes.
Future<Set<String>?> showMiniAppScopeConsent(
  BuildContext context, {
  required String name,
  required List<String> requested,
  required List<String> network,
  Set<String>? initialScopes,
}) async {
  final selected = (initialScopes ?? requested.toSet())
      .where(scopeDescriptions.containsKey)
      .toSet();
  final extra = requested
      .where((s) => !scopeDescriptions.containsKey(s))
      .toList();
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Permissions for $name'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Only selected permissions are granted to this bundle. You can remove requested permissions or explicitly add a missing permission for a trusted local app. Vehicle and Android safety checks still apply.',
                ),
                if (extra.isNotEmpty)
                  Text(
                    'Unsupported requests (not granted): ${extra.join(', ')}',
                  ),
                for (final entry in scopeDescriptions.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    subtitle: Text(
                      '${entry.key}${requested.contains(entry.key) ? ' — requested by app' : ''}',
                    ),
                    value: selected.contains(entry.key),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    }),
                  ),
                Text(
                  'Online origins: ${network.isEmpty ? 'None' : network.join(', ')}. Online access also requires Optional Services.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, selected),
            child: const Text('Allow selected'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> confirmMiniAppInstall(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  MiniApp? app;
  for (final item in ref.read(miniAppCatalogProvider).value ?? <MiniApp>[]) {
    if (item.id == id) app = item;
  }
  if (app == null) return false;
  try {
    if (app.privileged) {
      throw StateError('Legacy signed extensions require review.');
    }
    final manifest = await ref
        .read(installedMiniAppStoreProvider)
        .inspectBundledApp(app);
    if (!context.mounted) return false;
    final scopes = await showMiniAppScopeConsent(
      context,
      name: app.localizedName('en'),
      requested: (manifest['permissions'] as List).cast<String>(),
      network: (manifest['network'] as List).cast<String>(),
    );
    if (scopes == null) return false;
    await ref
        .read(localMiniAppGrantsProvider)
        .approve(app.id, app.bundleSha256, scopes);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
}

/// Existing installations are fail-closed until the owner reviews local scopes.
Future<bool> ensureMiniAppLaunchConsent(
  BuildContext context,
  WidgetRef ref,
  MiniApp app,
  String indexPath, {
  bool forceReview = false,
}) async {
  final hash = await ref
      .read(miniAppInstallStorageProvider)
      .bundleShaFor(app.id);
  if (hash == null || hash != app.bundleSha256 || app.privileged) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Reimport this bundle to verify its identity before granting permissions.',
          ),
        ),
      );
    }
    return false;
  }
  final grants = ref.read(localMiniAppGrantsProvider);
  final previous = await grants.approved(app.id, hash);
  if (!forceReview && previous != null) return true;
  final file = File('${File(indexPath).parent.path}/manifest.json');
  if (!await file.exists() || await file.length() > 128 * 1024) return false;
  final manifest =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (manifest['id'] != app.id || manifest['version'] != app.version) {
    return false;
  }
  if (!context.mounted) return false;
  final scopes = await showMiniAppScopeConsent(
    context,
    name: app.localizedName('en'),
    requested: (manifest['permissions'] as List? ?? []).cast<String>(),
    network: app.network,
    initialScopes: previous,
  );
  if (scopes == null) return false;
  await grants.approve(app.id, hash, scopes);
  return true;
}
