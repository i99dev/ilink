import '../_car_domain/command/command_outcome.dart';
import 'data/curated_playlist_api.dart' show CuratedFetchException;
import 'domain/curated_playlist.dart';
import 'radio_controller.dart';
import 'state/curated_playlists_controller.dart';

Future<Map<String, dynamic>> dispatchRadioCommand(
  RadioController controller,
  String commandId,
  Map<String, dynamic> args, {
  CuratedPlaylistsController? curated,
}) async {
  final outcome = switch (commandId) {
    'radio.play_by_name' => await _playByName(
      controller,
      curated,
      (args['name'] ?? '').toString(),
    ),
    'radio.play_station' => await controller.playStationById(
      (args['station_id'] ?? '').toString(),
    ),
    'radio.pause' => await controller.pause(),
    'radio.resume' => await controller.resume(),
    'radio.stop' => await controller.stop(),
    'radio.next_fav' => await controller.nextFavorite(),
    _ => CommandOutcome.failure('unknown radio command: $commandId'),
  };
  return outcome.toJson();
}

Future<CommandOutcome> _playByName(
  RadioController controller,
  CuratedPlaylistsController? curated,
  String name,
) async {
  final local = await controller.playByName(name);
  if (local.ok || curated == null) return local;

  try {
    final index = await curated.getIndex();
    final entry = matchCuratedEntry(index, name);
    if (entry == null) {
      return CommandOutcome.failure('no station or playlist matches "$name"');
    }
    final playlist = await curated.loadPlaylist(entry);
    final pick = pickCuratedStation(playlist, name);
    if (pick == null) {
      return CommandOutcome.failure(
        '"${entry.label}" has no playable stations',
      );
    }
    return await controller.playStation(pick);
  } on CuratedFetchException catch (e) {
    return CommandOutcome.failure('radio catalogue unavailable (${e.message})');
  } catch (_) {
    return CommandOutcome.failure('could not load the radio catalogue');
  }
}
