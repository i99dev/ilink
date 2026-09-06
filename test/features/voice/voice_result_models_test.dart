import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/presentation/widgets/voice_result_models.dart';

void main() {
  group('ResultStatus.fromArgs', () {
    test('degraded true + message', () {
      final s = ResultStatus.fromArgs({'degraded': true, 'message': 'nope'});
      expect(s.degraded, isTrue);
      expect(s.message, 'nope');
    });

    test('missing degraded defaults to not-degraded', () {
      final s = ResultStatus.fromArgs(const {});
      expect(s.degraded, isFalse);
      expect(s.message, isNull);
    });

    test('non-bool degraded value is not treated as degraded', () {
      expect(ResultStatus.fromArgs({'degraded': 'true'}).degraded, isFalse);
      expect(ResultStatus.fromArgs({'degraded': 1}).degraded, isFalse);
    });
  });

  group('PlaceResult', () {
    test('fromJson parses a full entry', () {
      final p = PlaceResult.fromJson({
        'name': 'Dubai Mall',
        'latitude': 25.197,
        'longitude': 55.279,
        'distance_m': 2400,
        'address': 'Downtown',
        'rating': 4.6,
        'rating_count': 1200,
        'open_now': true,
      })!;
      expect(p.name, 'Dubai Mall');
      expect(p.lat, closeTo(25.197, 1e-9));
      expect(p.lng, closeTo(55.279, 1e-9));
      expect(p.distanceM, 2400);
      expect(p.rating, 4.6);
      expect(p.ratingCount, 1200);
      expect(p.openNow, isTrue);
    });

    test('fromJson coerces stringified numbers', () {
      final p = PlaceResult.fromJson({
        'name': 'X',
        'latitude': '25.1',
        'longitude': '55.2',
        'distance_m': '500',
      })!;
      expect(p.lat, closeTo(25.1, 1e-9));
      expect(p.distanceM, 500);
    });

    test('fromJson rejects entries missing name or coords', () {
      expect(PlaceResult.fromJson({'latitude': 1, 'longitude': 2}), isNull);
      expect(
        PlaceResult.fromJson({'name': '', 'latitude': 1, 'longitude': 2}),
        isNull,
      );
      expect(PlaceResult.fromJson({'name': 'X', 'latitude': 1}), isNull);
      expect(PlaceResult.fromJson('not a map'), isNull);
    });

    test('distanceLabel: metres under 1km, km above', () {
      expect(
        const PlaceResult(
          name: 'a',
          lat: 0,
          lng: 0,
          distanceM: 350,
        ).distanceLabel,
        '350 m',
      );
      expect(
        const PlaceResult(
          name: 'a',
          lat: 0,
          lng: 0,
          distanceM: 2400,
        ).distanceLabel,
        '2.4 km',
      );
      expect(
        const PlaceResult(name: 'a', lat: 0, lng: 0).distanceLabel,
        isNull,
      );
    });

    test('listFrom filters invalid rows and is fixed-length', () {
      final list = PlaceResult.listFrom([
        {'name': 'A', 'latitude': 1, 'longitude': 2},
        {'name': '', 'latitude': 1, 'longitude': 2}, // dropped
        'garbage', // dropped
      ]);
      expect(list, hasLength(1));
      expect(() => list.add(list.first), throwsUnsupportedError);
    });

    test('listFrom on a non-list yields empty', () {
      expect(PlaceResult.listFrom(null), isEmpty);
      expect(PlaceResult.listFrom('x'), isEmpty);
    });
  });

  group('PlacesResult.fromArgs', () {
    test('title fallback + underscore-normalized query', () {
      final r = PlacesResult.fromArgs({'category': 'gas_station'});
      expect(r.title, 'Nearby');
      expect(r.query, 'gas station');
    });

    test('query prefers category, then query, then title', () {
      expect(PlacesResult.fromArgs({'query': 'coffee'}).query, 'coffee');
      expect(PlacesResult.fromArgs({'title': 'Cafes'}).query, 'Cafes');
    });

    test('isEmpty when degraded or no places', () {
      expect(PlacesResult.fromArgs({'degraded': true}).isEmpty, isTrue);
      expect(PlacesResult.fromArgs(const {}).isEmpty, isTrue);
      expect(
        PlacesResult.fromArgs({
          'results': [
            {'name': 'A', 'latitude': 1, 'longitude': 2},
          ],
        }).isEmpty,
        isFalse,
      );
    });
  });

  group('RouteResult.fromArgs', () {
    test('parses fields and coordinate flags', () {
      final r = RouteResult.fromArgs({
        'destination': 'Mall',
        'duration_text': '23 min',
        'distance_text': '14 km',
        'traffic_delay_minutes': 7,
        'range_ok': false,
        'range_warning': 'Charge first',
        'destination_latitude': 25.1,
        'destination_longitude': 55.2,
      });
      expect(r.destination, 'Mall');
      expect(r.durationText, '23 min');
      expect(r.hasTrafficDelay, isTrue);
      expect(r.rangeOk, isFalse);
      expect(r.rangeWarning, 'Charge first');
      expect(r.hasCoords, isTrue);
    });

    test('hasTrafficDelay only at 3 min+', () {
      expect(
        RouteResult.fromArgs({'traffic_delay_minutes': 2}).hasTrafficDelay,
        isFalse,
      );
      expect(RouteResult.fromArgs(const {}).hasTrafficDelay, isFalse);
    });

    test('defaults destination + no coords when absent', () {
      final r = RouteResult.fromArgs(const {});
      expect(r.destination, 'Destination');
      expect(r.hasCoords, isFalse);
      expect(r.rangeOk, isNull);
    });
  });

  group('NavigateResult.fromArgs', () {
    test('canLaunch requires coords and not degraded', () {
      final ok = NavigateResult.fromArgs({
        'label': 'Home',
        'latitude': 1,
        'longitude': 2,
      });
      expect(ok.canLaunch, isTrue);
      expect(ok.label, 'Home');

      expect(
        NavigateResult.fromArgs({
          'degraded': true,
          'latitude': 1,
          'longitude': 2,
        }).canLaunch,
        isFalse,
      );
      expect(NavigateResult.fromArgs({'latitude': 1}).canLaunch, isFalse);
    });

    test('label defaults', () {
      expect(NavigateResult.fromArgs(const {}).label, 'Destination');
    });
  });

  group('WeatherResult.fromArgs', () {
    test('condition fallback chain', () {
      expect(WeatherResult.fromArgs({'condition': 'Sunny'}).condition, 'Sunny');
      expect(WeatherResult.fromArgs({'title': 'Cloudy'}).condition, 'Cloudy');
      expect(WeatherResult.fromArgs(const {}).condition, 'Weather');
    });

    test('parses temps and next_hours', () {
      final w = WeatherResult.fromArgs({
        'temperature_c': 31.6,
        'wind_kmh': 12,
        'temperature_high_c': 35,
        'temperature_low_c': 24,
        'weather_code': 2,
        'next_hours': [
          {'time': '2026-05-29T14:00', 'temperature_c': 32},
          {'time': '15:00', 'temperature_c': 33},
        ],
      });
      expect(w.tempC, 32); // rounded
      expect(w.windKmh, 12);
      expect(w.highC, 35);
      expect(w.lowC, 24);
      expect(w.hours, hasLength(2));
      expect(w.hours.first.label, '14:00');
      expect(w.hours.first.tempC, 32);
      expect(w.hours[1].label, '15:00');
    });

    test('next_hours tolerates missing/garbage', () {
      final w = WeatherResult.fromArgs({
        'next_hours': [
          'nope',
          {'time': '09:00'},
        ],
      });
      expect(w.hours, hasLength(1));
      expect(w.hours.first.tempC, isNull);
    });
  });

  group('TranslateResult.fromArgs', () {
    test('uppercases languages and builds the pair', () {
      final t = TranslateResult.fromArgs({
        'source_text': 'hello',
        'translated_text': 'مرحبا',
        'target_language': 'ar',
        'detected_language': 'en',
      });
      expect(t.sourceText, 'hello');
      expect(t.translatedText, 'مرحبا');
      expect(t.targetLanguage, 'AR');
      expect(t.languagePair, 'EN → AR');
    });

    test('languagePair falls back to target only', () {
      expect(
        TranslateResult.fromArgs({'target_language': 'fr'}).languagePair,
        'FR',
      );
      expect(TranslateResult.fromArgs(const {}).languagePair, isNull);
    });
  });
}
