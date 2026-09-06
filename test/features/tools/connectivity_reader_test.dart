import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tools/data/connectivity_reader.dart';
import 'package:ilink/features/tools/domain/connectivity_state.dart';

void main() {
  group('ConnectivityReader.parseWifi', () {
    test('detects enabled / disabled / transitioning', () {
      expect(
        ConnectivityReader.parseWifi('Wi-Fi is enabled\n').state,
        NetState.on,
      );
      expect(
        ConnectivityReader.parseWifi('Wi-Fi is disabled\n').state,
        NetState.off,
      );
      expect(
        ConnectivityReader.parseWifi('Wi-Fi is enabling\n').state,
        NetState.transitioning,
      );
      expect(
        ConnectivityReader.parseWifi('Wi-Fi is disabling\n').state,
        NetState.transitioning,
      );
      expect(ConnectivityReader.parseWifi('garbage').state, NetState.unknown);
    });

    test('extracts SSID and RSSI', () {
      final r = ConnectivityReader.parseWifi('''
Wi-Fi is enabled
mWifiInfo SSID: "iPhone-Hotspot", BSSID: 00:11:22:33:44:55, RSSI: -52, Linkspeed: 433Mbps
''');
      expect(r.state, NetState.on);
      expect(r.ssid, 'iPhone-Hotspot');
      expect(r.rssi, -52);
    });

    test('treats <unknown ssid> as null', () {
      final r = ConnectivityReader.parseWifi('''
Wi-Fi is enabled
SSID: "<unknown ssid>"
''');
      expect(r.ssid, isNull);
    });

    test('handles missing fields gracefully', () {
      final r = ConnectivityReader.parseWifi('Wi-Fi is enabled\n');
      expect(r.state, NetState.on);
      expect(r.ssid, isNull);
      expect(r.rssi, isNull);
    });
  });

  group('ConnectivityReader.parseBluetooth', () {
    test('parses enabled true/false', () {
      expect(
        ConnectivityReader.parseBluetooth('enabled: true').state,
        NetState.on,
      );
      expect(
        ConnectivityReader.parseBluetooth('enabled: false').state,
        NetState.off,
      );
    });

    test('catches transitioning states', () {
      expect(
        ConnectivityReader.parseBluetooth('state: TURNING_ON').state,
        NetState.transitioning,
      );
      expect(
        ConnectivityReader.parseBluetooth('state: TURNING_OFF').state,
        NetState.transitioning,
      );
      expect(
        ConnectivityReader.parseBluetooth('state: BLE_TURNING_ON').state,
        NetState.transitioning,
      );
    });

    test('extracts connected device name', () {
      final r = ConnectivityReader.parseBluetooth('''
enabled: true
state: ON
Connected: Galaxy Buds, AirPods Max
''');
      expect(r.connectedDevice, 'Galaxy Buds');
    });

    test('treats "none" / empty as no device', () {
      expect(
        ConnectivityReader.parseBluetooth(
          'enabled: true\nConnected: none\n',
        ).connectedDevice,
        isNull,
      );
      expect(
        ConnectivityReader.parseBluetooth('enabled: true').connectedDevice,
        isNull,
      );
    });
  });

  group('ConnectivityReader.parseCellular', () {
    test('detects 1 / 0 / null from settings.global.mobile_data', () {
      expect(
        ConnectivityReader.parseCellular(mobileDataSetting: '1').state,
        NetState.on,
      );
      // Trailing newline is what `adb shell settings get` emits.
      expect(
        ConnectivityReader.parseCellular(mobileDataSetting: '0\n').state,
        NetState.off,
      );
      expect(
        ConnectivityReader.parseCellular(mobileDataSetting: 'null').state,
        NetState.unknown,
      );
      expect(
        ConnectivityReader.parseCellular(mobileDataSetting: '').state,
        NetState.unknown,
      );
    });

    test('AOSP mDataNetworkType= is parsed', () {
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: 'mDataNetworkType=LTE',
        ).generation,
        '4G',
      );
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: 'mDataNetworkType=NR',
        ).generation,
        '5G',
      );
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: 'mDataNetworkType=UNKNOWN',
        ).generation,
        isNull,
      );
    });

    test('BYD/MTK getRilDataRadioTechnology fallback is parsed', () {
      // Pulled live from `dumpsys telephony.registry` on the Leopard
      // 8 head unit during ETISALAT 4G service — the field shape the
      // old AOSP-only regex missed.
      const dump =
          'mServiceState={mVoiceRegState=0(IN_SERVICE), '
          'getRilVoiceRadioTechnology=14(LTE), '
          'getRilDataRadioTechnology=14(LTE), ...}';
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: dump,
        ).generation,
        '4G',
      );
    });

    test('AOSP shape wins when both fields are present', () {
      // Real-world rollout: a hybrid ROM ships both keys. The AOSP
      // one is more authoritative (the framework writes it after
      // network handover), so the parser must prefer it.
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump:
              'mDataNetworkType=NR\n'
              'getRilDataRadioTechnology=14(LTE)',
        ).generation,
        '5G',
      );
    });

    test('GPRS / EDGE / GSM map to 2G via either field', () {
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: 'getRilDataRadioTechnology=2(EDGE)',
        ).generation,
        '2G',
      );
      expect(
        ConnectivityReader.parseCellular(
          mobileDataSetting: '1',
          telephonyDump: 'mDataNetworkType=GPRS',
        ).generation,
        '2G',
      );
    });
  });

  group('ConnectivityReader.parseRoaming', () {
    test('handles 0/1/null', () {
      expect(ConnectivityReader.parseRoaming('1\n'), NetState.on);
      expect(ConnectivityReader.parseRoaming('0\n'), NetState.off);
      expect(ConnectivityReader.parseRoaming('null\n'), NetState.unknown);
      expect(ConnectivityReader.parseRoaming(''), NetState.unknown);
    });
  });

  group('ConnectivityReader.parseHotspot', () {
    test('softap on/off heuristics', () {
      expect(ConnectivityReader.parseHotspot('Tethering is on'), NetState.on);
      expect(ConnectivityReader.parseHotspot('softap stopped'), NetState.off);
      expect(ConnectivityReader.parseHotspot('garbage'), NetState.unknown);
    });
  });

  group('ConnectivityReader.compose', () {
    test('preserves previous fields on partial reads', () {
      const seed = ConnectivityState(
        cellular: NetState.on,
        roaming: NetState.off,
        bluetooth: NetState.on,
        wifi: NetState.on,
        hotspot: NetState.off,
        wifiSsid: 'OldSSID',
        wifiRssi: -60,
      );
      // Only wifi changes; everything else carries over.
      final next = ConnectivityReader.compose(
        previous: seed,
        wifiDump: 'Wi-Fi is disabled\n',
      );
      expect(next.wifi, NetState.off);
      expect(next.cellular, NetState.on);
      expect(next.roaming, NetState.off);
      expect(next.bluetooth, NetState.on);
      // Disabled WiFi clears SSID/RSSI in our parser (they aren't in
      // the dump), so the compose path explicitly sets them to null.
      expect(next.wifiSsid, isNull);
      expect(next.wifiRssi, isNull);
    });
  });
}
