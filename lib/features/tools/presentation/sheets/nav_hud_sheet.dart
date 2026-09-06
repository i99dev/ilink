import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../nav_hud/application/nav_hud_controller.dart';
import '../../../nav_hud/presentation/nav_hud_panel.dart';

/// Bottom sheet shown when the Nav-HUD (pin) circle on the home Tools strip is
/// tapped. Hosts the single [NavHudPanel] — the one Nav-HUD UI — so activation +
/// configuration live in exactly one widget (it moved off Settings; the strip is
/// now its only entry point). The strip's presenter supplies the drag handle and
/// `isScrollControlled`; this just bounds the height and embeds the panel, which
/// is itself a scrollable `ListView`.
///
/// Stateful so it can run the cluster-transport probe ([ensureLoaded]) only when
/// the sheet is actually opened — NOT when the Tools-strip ring instantiates the
/// controller just to read `armed`. Eager-probing on the controller's build()
/// leaked a `.timeout` Timer into widget trees that never show this sheet.
class NavHudSheet extends ConsumerStatefulWidget {
  const NavHudSheet({super.key});

  @override
  ConsumerState<NavHudSheet> createState() => _NavHudSheetState();
}

class _NavHudSheetState extends ConsumerState<NavHudSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(navHudControllerProvider.notifier).ensureLoaded();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: const NavHudPanel(),
      ),
    );
  }
}
