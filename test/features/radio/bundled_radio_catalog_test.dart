import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/playlists/catalogue_http.dart';
import 'package:ilink/features/radio/data/curated_playlist_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bundled radio discovery loads without HTTP and contains no credential URLs',
    () async {
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
      final api = CuratedPlaylistApi(http: CatalogueHttp(dio: dio));
      final index = await api.fetchIndex();
      expect(index.entries.length, greaterThan(100));
      var count = 0;
      for (final entry in index.entries) {
        final playlist = await api.fetchPlaylist(entry);
        expect(playlist.stations, isNotEmpty);
        for (final station in playlist.stations) {
          final uri = Uri.parse(station.streamUrl);
          expect(uri.userInfo, isEmpty);
          expect(uri.query, isEmpty);
          expect(uri.fragment, isEmpty);
          expect(uri.host, isNot(contains('digitalocean')));
          expect(uri.host, isNot(contains('ilink')));
        }
        count += playlist.stations.length;
      }
      expect(count, greaterThan(5000));
      expect(requests, 0);
    },
  );
}
