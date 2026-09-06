import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/radio_favorites_store.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:shared_preferences/shared_preferences.dart';

Station _st(String id, {String name = 'N'}) =>
    Station(id: id, sourceUuid: '', name: name, streamUrl: 'http://h/$id');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<RadioFavoritesStore> make() async {
    final prefs = await SharedPreferences.getInstance();
    return RadioFavoritesStore(prefs);
  }

  test('empty by default', () async {
    final s = await make();
    expect(s.getAll(), isEmpty);
    expect(s.isFavorite('x'), isFalse);
  });

  test('add is idempotent and preserves most-recent-first order', () async {
    final s = await make();
    await s.add(_st('a'));
    await s.add(_st('b'));
    await s.add(_st('a')); // duplicate id — ignored
    expect(s.getAll().map((e) => e.id), ['b', 'a']);
  });

  test('remove drops the entry, preserves order of the rest', () async {
    final s = await make();
    await s.add(_st('a'));
    await s.add(_st('b'));
    await s.add(_st('c'));
    await s.remove('b');
    expect(s.getAll().map((e) => e.id), ['c', 'a']);
  });

  test('isFavorite reflects membership', () async {
    final s = await make();
    await s.add(_st('x'));
    expect(s.isFavorite('x'), isTrue);
    await s.remove('x');
    expect(s.isFavorite('x'), isFalse);
  });

  test('corrupted v2 json → empty, next write succeeds', () async {
    SharedPreferences.setMockInitialValues({'radio.favorites.v2': 'not json'});
    final s = await make();
    expect(s.getAll(), isEmpty);
    await s.add(_st('a'));
    expect(s.getAll().single.id, 'a');
  });

  test('GOLDEN: full Station snapshot round-trips across instances', () async {
    const original = Station(
      id: 'sha1abc',
      sourceUuid: 'uuid-x',
      name: 'Frequence Jazz',
      streamUrl: 'https://h/jazz.mp3',
      homepage: 'https://h',
      favicon: 'https://h/logo.png',
      countryCode: 'FR',
      countryName: 'France',
      state: 'IDF',
      language: 'french',
      languageCodes: ['fr'],
      tags: ['jazz', 'smooth'],
      codec: 'MP3',
      bitrate: 128,
      isHls: false,
      votes: 42,
      clickCount: 7,
    );
    final a = await make();
    await a.add(original);

    // Fresh store over the same prefs — simulates an app restart.
    final b = RadioFavoritesStore(await SharedPreferences.getInstance());
    final got = b.getAll().single;

    expect(got.id, original.id);
    expect(got.sourceUuid, original.sourceUuid);
    expect(got.name, original.name);
    expect(got.streamUrl, original.streamUrl);
    expect(got.homepage, original.homepage);
    expect(got.favicon, original.favicon);
    expect(got.countryCode, original.countryCode);
    expect(got.countryName, original.countryName);
    expect(got.state, original.state);
    expect(got.language, original.language);
    expect(got.languageCodes, original.languageCodes);
    expect(got.tags, original.tags);
    expect(got.codec, original.codec);
    expect(got.bitrate, original.bitrate);
    expect(got.isHls, original.isHls);
    expect(got.votes, original.votes);
    expect(got.clickCount, original.clickCount);
  });

  test('one-time migration drops the legacy v1 UUID blob', () async {
    SharedPreferences.setMockInitialValues({
      'radio.favorites': jsonEncode(['old-uuid-1', 'old-uuid-2']),
    });
    final s = await make();

    // v1 favourites cannot resolve against M3U — start empty.
    expect(s.getAll(), isEmpty);
    await Future<void>.delayed(Duration.zero); // let the async remove flush

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('radio.favorites'),
      isNull,
      reason: 'legacy key must be wiped exactly once',
    );

    // New snapshot favourites still work afterwards.
    await s.add(_st('new'));
    expect(s.getAll().single.id, 'new');
  });
}
