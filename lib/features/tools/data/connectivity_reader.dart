import '../domain/connectivity_state.dart';

/// Pure parsers for `dumpsys` / `settings get` / `cmd` output.
///
/// Why pure: golden-file tests pin every parser to a recorded sample
/// of real BYD output. When DiLink rev N+1 changes a line format, the
/// parser test fails BEFORE the field hits production. This is the
/// brittlest point in the whole feature — test it harder than
/// anything else.
///
/// Each parser is a static function; no Riverpod, no I/O, no time.
class ConnectivityReader {
  const ConnectivityReader._();

  // ─── WiFi ──────────────────────────────────────────────────────────

  /// Parse `dumpsys wifi` output. Looks for the canonical anchors
  /// shipped on AOSP / DiLink5.1.
  ///
  /// Anchors:
  ///   * `Wi-Fi is enabled`  → on
  ///   * `Wi-Fi is disabled` → off
  ///   * `Wi-Fi is enabling` / `disabling` → transitioning
  ///   * `mWifiInfo SSID: "...", RSSI: ...` → wifiSsid/wifiRssi
  static ({NetState state, String? ssid, int? rssi}) parseWifi(String dump) {
    NetState state;
    if (dump.contains(RegExp(r'Wi-?Fi is enabled\b', caseSensitive: false))) {
      state = NetState.on;
    } else if (dump.contains(
      RegExp(r'Wi-?Fi is disabled\b', caseSensitive: false),
    )) {
      state = NetState.off;
    } else if (dump.contains(
      RegExp(r'Wi-?Fi is (enabling|disabling)\b', caseSensitive: false),
    )) {
      state = NetState.transitioning;
    } else {
      state = NetState.unknown;
    }
    String? ssid;
    int? rssi;
    final ssidMatch = RegExp(r'SSID:\s*"([^"]*)"').firstMatch(dump);
    if (ssidMatch != null && ssidMatch.group(1)!.isNotEmpty) {
      // Filter <unknown ssid> sentinel.
      final candidate = ssidMatch.group(1)!;
      if (candidate != '<unknown ssid>') ssid = candidate;
    }
    final rssiMatch = RegExp(r'RSSI:\s*(-?\d+)\s*\b').firstMatch(dump);
    if (rssiMatch != null) {
      rssi = int.tryParse(rssiMatch.group(1)!);
    }
    return (state: state, ssid: ssid, rssi: rssi);
  }

  // ─── Bluetooth ─────────────────────────────────────────────────────

  /// Parse `dumpsys bluetooth_manager` output.
  static ({NetState state, String? connectedDevice}) parseBluetooth(
    String dump,
  ) {
    NetState state;
    // AOSP standard line: `enabled: true` / `enabled: false`.
    final enabled = RegExp(
      r'enabled:\s*(true|false)',
      caseSensitive: false,
    ).firstMatch(dump);
    if (enabled != null) {
      state = enabled.group(1)!.toLowerCase() == 'true'
          ? NetState.on
          : NetState.off;
    } else if (dump.contains('state: BLE_TURNING_ON') ||
        dump.contains('state: BLE_TURNING_OFF') ||
        dump.contains('state: TURNING_ON') ||
        dump.contains('state: TURNING_OFF')) {
      state = NetState.transitioning;
    } else if (dump.contains('state: ON')) {
      state = NetState.on;
    } else if (dump.contains('state: OFF')) {
      state = NetState.off;
    } else {
      state = NetState.unknown;
    }
    String? connectedDevice;
    // Dump format varies; common patterns:
    //   `devices connected: ` followed by a list
    //   `Connected:` line listing names
    final connMatch = RegExp(
      r'(?:Connected|connected devices?):\s*\n?\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(dump);
    if (connMatch != null) {
      final raw = connMatch.group(1)!.trim();
      if (raw.isNotEmpty &&
          raw != '0' &&
          !raw.startsWith('[]') &&
          !raw.toLowerCase().startsWith('none')) {
        // Take the first device name (chop at separator).
        final firstName = raw.split(RegExp(r'[,;]')).first.trim();
        if (firstName.isNotEmpty) connectedDevice = firstName;
      }
    }
    return (state: state, connectedDevice: connectedDevice);
  }

  // ─── Cellular Data ─────────────────────────────────────────────────

  /// Parse `settings get global mobile_data` (returns `"1"`, `"0"`,
  /// or `"null"`) for cellular state, plus optional
  /// `dumpsys telephony.registry` for the radio generation.
  ///
  /// **Why settings.global.mobile_data and not `svc data`:** on the
  /// Leopard 8 ROM (and seemingly other Di5.x trims), invoking
  /// `svc data` without an arg returns the usage help text
  /// ("Enable/Disable Mobile Data Connectivity") rather than the
  /// state string the old parser was looking for — so the old reader
  /// always returned `NetState.unknown` and the UI rendered the
  /// switch as off / non-interactive. The Settings.Global key is
  /// the framework-level flag the modem stack honours; shell-uid can
  /// read AND write it without `MODIFY_PHONE_STATE`. Verified via
  /// `adb shell settings put global mobile_data 0` round-tripping
  /// on this ROM.
  ///
  /// For the generation we try `mDataNetworkType=…` first (AOSP
  /// shape) and fall back to `getRilDataRadioTechnology=N(NAME)`
  /// which is what BYD/MTK ROMs actually emit. Either path feeds
  /// the same [_normalizeGen] bucket.
  static ({NetState state, String? generation}) parseCellular({
    required String mobileDataSetting,
    String? telephonyDump,
  }) {
    final raw = mobileDataSetting.trim().toLowerCase();
    final state = switch (raw) {
      '1' => NetState.on,
      '0' => NetState.off,
      _ => NetState.unknown,
    };
    String? generation;
    if (telephonyDump != null) {
      // AOSP shape first.
      final aosp = RegExp(r'mDataNetworkType=(\w+)').firstMatch(telephonyDump);
      if (aosp != null) {
        generation = _normalizeGen(aosp.group(1)!);
      }
      // BYD/MTK shape fallback. The dump can carry several
      // `getRilDataRadioTechnology=N(NAME)` lines for multi-sub
      // devices; the FIRST hit corresponds to the active sub (phoneId=0)
      // on every fixture I've seen — keep `.firstMatch` so a stale
      // OUT_OF_SERVICE entry on subId=1 doesn't clobber the live one.
      if (generation == null) {
        final mtk = RegExp(
          r'getRilDataRadioTechnology=\d+\((\w+)\)',
        ).firstMatch(telephonyDump);
        if (mtk != null) {
          generation = _normalizeGen(mtk.group(1)!);
        }
      }
    }
    return (state: state, generation: generation);
  }

  static String? _normalizeGen(String raw) {
    final upper = raw.toUpperCase();
    if (upper.contains('NR') || upper.startsWith('5G')) return '5G';
    if (upper.contains('LTE') || upper.contains('4G')) return '4G';
    if (upper.contains('HSPA') ||
        upper.contains('UMTS') ||
        upper.contains('3G')) {
      return '3G';
    }
    if (upper.contains('EDGE') ||
        upper.contains('GPRS') ||
        upper.contains('2G')) {
      return '2G';
    }
    if (upper == 'UNKNOWN' || upper == 'NONE') return null;
    return null;
  }

  // ─── Roaming ───────────────────────────────────────────────────────

  /// Parse `settings get global data_roaming` (returns "0", "1", or
  /// "null"). Trim whitespace defensively.
  static NetState parseRoaming(String settingsOutput) {
    final v = settingsOutput.trim();
    if (v == '1') return NetState.on;
    if (v == '0') return NetState.off;
    return NetState.unknown;
  }

  // ─── Hotspot ───────────────────────────────────────────────────────

  /// Parse `cmd wifi is-wifi-enabled` … no, that's just wifi. For
  /// hotspot we use `cmd wifi get-softap-supported-features` /
  /// `dumpsys wifi | grep "softap"`. AOSP doesn't expose a clean
  /// state line; we look for `Tethering is on/off` or
  /// `wifi_iface_state: SOFTAP` patterns.
  static NetState parseHotspot(String dump) {
    if (dump.contains(
      RegExp(r'softap.*started|tethering.*on', caseSensitive: false),
    )) {
      return NetState.on;
    }
    if (dump.contains(
      RegExp(r'softap.*stopped|tethering.*off', caseSensitive: false),
    )) {
      return NetState.off;
    }
    return NetState.unknown;
  }

  // ─── Compose ───────────────────────────────────────────────────────

  /// One-shot composer used by the state provider after a batch read.
  /// `previous` is the last known state — fields that the current
  /// poll didn't include carry over so transient parse misses don't
  /// flap the UI. Pure function — runtime + golden-file tests share
  /// this single entry point.
  static ConnectivityState compose({
    required ConnectivityState previous,
    String? wifiDump,
    String? btDump,
    String? mobileDataSetting,
    String? telephonyDump,
    String? roamingSetting,
    String? hotspotDump,
  }) {
    var state = previous;
    if (wifiDump != null) {
      final w = parseWifi(wifiDump);
      state = state.copyWith(wifi: w.state, wifiSsid: w.ssid, wifiRssi: w.rssi);
    }
    if (btDump != null) {
      final b = parseBluetooth(btDump);
      state = state.copyWith(
        bluetooth: b.state,
        btConnectedDevice: b.connectedDevice,
      );
    }
    if (mobileDataSetting != null) {
      final c = parseCellular(
        mobileDataSetting: mobileDataSetting,
        telephonyDump: telephonyDump,
      );
      state = state.copyWith(
        cellular: c.state,
        cellularGeneration: c.generation,
      );
    }
    if (roamingSetting != null) {
      state = state.copyWith(roaming: parseRoaming(roamingSetting));
    }
    if (hotspotDump != null) {
      state = state.copyWith(hotspot: parseHotspot(hotspotDump));
    }
    return state;
  }
}
