import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/apps/app_voice_dispatch.dart';
import 'package:ilink/kernel/shell/shell_command.dart';
import 'package:ilink/kernel/shell/shell_ops_coordinator.dart';

/// Records every argv the dispatcher runs and replies with canned stdout —
/// lets us assert the exact `am start` / `monkey` / `pm` commands without a
/// real bridge. `pm list packages` returns a fixed inventory; everything
/// else (am/monkey) returns the supplied [amStdout] (default empty = success).
class _FakeShell {
  _FakeShell({this.amStdout = '', this.packages = const []});
  final String amStdout;
  final List<String> packages;
  final List<List<String>> calls = [];

  ShellOpsCoordinator get coord => ShellOpsCoordinator(
    exec: (ShellCommand cmd) async {
      calls.add(cmd.argv);
      if (cmd.argv.first == 'pm' && cmd.argv.contains('list')) {
        return packages.map((p) => 'package:$p').join('\n');
      }
      return amStdout;
    },
  );

  List<String> get last => calls.last;
}

void main() {
  group('dispatchAppCommand', () {
    test('app.search opens YouTube on the query via a VIEW intent', () async {
      final shell = _FakeShell();
      final res = await dispatchAppCommand(shell.coord, 'app.search', {
        'app': 'YouTube',
        'query': 'jazz',
      });
      expect(res['ok'], isTrue);
      expect(shell.last, [
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        'https://www.youtube.com/results?search_query=jazz',
        'com.google.android.youtube',
      ]);
    });

    test('app.search with no query just launches the app', () async {
      final shell = _FakeShell();
      final res = await dispatchAppCommand(shell.coord, 'app.search', {
        'app': 'Spotify',
        'query': '',
      });
      expect(res['ok'], isTrue);
      expect(shell.last.first, 'monkey');
      expect(shell.last, contains('com.spotify.music'));
    });

    test(
      'app.navigate uses google.navigation and passes "home" verbatim',
      () async {
        final shell = _FakeShell();
        final res = await dispatchAppCommand(shell.coord, 'app.navigate', {
          'destination': 'home',
        });
        expect(res['ok'], isTrue);
        expect(shell.last, [
          'am',
          'start',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          'google.navigation:q=home',
          'com.google.android.apps.maps',
        ]);
      },
    );

    test('app.navigate honours a named maps app (Waze)', () async {
      final shell = _FakeShell();
      await dispatchAppCommand(shell.coord, 'app.navigate', {
        'destination': 'Dubai Mall',
        'app': 'waze',
      });
      expect(shell.last[5], 'https://waze.com/ul?q=Dubai%20Mall&navigate=yes');
      expect(shell.last.last, 'com.waze');
    });

    test('app.open of a catalog app launches its package', () async {
      final shell = _FakeShell();
      final res = await dispatchAppCommand(shell.coord, 'app.open', {
        'app': 'Spotify',
      });
      expect(res['ok'], isTrue);
      expect(shell.last, contains('com.spotify.music'));
    });

    test('app.open of an unknown app resolves via pm list packages', () async {
      final shell = _FakeShell(packages: const ['com.whatsapp', 'com.foo.bar']);
      final res = await dispatchAppCommand(shell.coord, 'app.open', {
        'app': 'WhatsApp',
      });
      expect(res['ok'], isTrue);
      expect(shell.last, contains('com.whatsapp'));
    });

    test('app.open of a truly-missing app fails cleanly', () async {
      final shell = _FakeShell(packages: const ['com.android.settings']);
      final res = await dispatchAppCommand(shell.coord, 'app.open', {
        'app': 'Nonsuch',
      });
      expect(res['ok'], isNot(true));
      expect(res['error'], contains('Nonsuch'));
    });

    test(
      'an am "Error:" stdout surfaces as a failure (app not installed)',
      () async {
        final shell = _FakeShell(
          amStdout: 'Error: Activity not started, unable to resolve Intent',
        );
        final res = await dispatchAppCommand(shell.coord, 'app.search', {
          'app': 'YouTube',
          'query': 'jazz',
        });
        expect(res['ok'], isNot(true));
      },
    );

    test('unknown command id → error', () async {
      final shell = _FakeShell();
      final res = await dispatchAppCommand(shell.coord, 'app.teleport', {});
      expect(res['ok'], isNot(true));
      expect(res['error'], contains('unknown app command'));
    });
  });
}
