/// Head-unit chassis vendor — the OEM behind the BYD-style DiLink
/// software stack on the device ilink is running on.
///
/// Different vendors expose the same Android API surface in different
/// ways: e.g. Yuanfeng heads run a Baidu-OS fork that uses different
/// system-property keys for vehicle identification, Liangshan heads
/// gate certain features behind a paid SDK that we don't have, etc.
/// The detector classifies into this enum once at boot from the HU's
/// raw `getprop` output; the registry keys per-(vendor, model) profile
/// off it.
///
/// Coverage seeded from the Dudu Launcher Pro APK survey
/// (2026-05-10) — the eight host names Dudu's resource strings + intent
/// filters reference. New entries land here when an unknown vendor
/// shows up in the Sentry tag stream.
enum HuVendor {
  /// BYD's first-party DiLink HU. The most common case and the only
  /// one we've reverse-engineered to [IntegrationTier.full] today
  /// (Leopard 5 + 8 line). Identified by the presence of
  /// `apps.setting.product.outswver` and `persist.sys.byd.default_name`.
  byd('byd', 'BYD DiLink'),

  /// Yuanfeng aftermarket HU running a Baidu-OS-derived launcher
  /// stack. Common on Han EV / Han DM aftermarket installs. Different
  /// system-property keys for vehicle id; the BYD outswver prop is
  /// absent.
  yuanfeng('yuanfeng', 'Yuanfeng (Baidu OS)'),

  /// Desay SV automotive HU — second-tier OEM common on Tang and
  /// some Yuan trims. Stock Android base, Desay-specific media stack.
  desay('desay', 'Desay SV'),

  /// Liangshan / Far Frontier aftermarket HU. Premium add-on with a
  /// licensed SDK gate (Dudu surfaces a "scan QR to buy" prompt for
  /// Liangshan-only features). We treat this as [IntegrationTier.stock]
  /// pending a license arrangement.
  liangshan('liangshan', 'Liangshan / Far Frontier'),

  /// Shinco aftermarket chassis. Routes the home key through
  /// `shinco.intent.action.LAUNCHER` — the manifest alias picks this
  /// up automatically.
  shinco('shinco', 'Shinco'),

  /// HK aftermarket chassis. Routes the home key through
  /// `com.hk.LAUNCHER`.
  hk('hk', 'HK'),

  /// acloud aftermarket chassis. Routes the home key through
  /// `com.acloud.action.home`.
  acloud('acloud', 'acloud'),

  /// NWD aftermarket chassis. Routes the home key through
  /// `com.nwd.action.ACTION_GOHOME`.
  nwd('nwd', 'NWD'),

  /// First-time install on a head unit we haven't profiled. The app
  /// stays usable (launcher mode + voice + MQTT) but every
  /// car-control surface dims to "unsupported on this car" until a
  /// registry entry maps the (vendor, model) tuple to a tier.
  unknown('unknown', 'Unknown HU');

  const HuVendor(this.wireValue, this.displayLabel);

  /// Stable string for serialization. Lowercase + no spaces so Sentry
  /// tags and MQTT payloads group cleanly.
  final String wireValue;

  /// Human-readable label for in-app surfaces.
  final String displayLabel;

  /// Reverse lookup for parsing wire values. Unknown raw values fall
  /// to [HuVendor.unknown] — same fail-closed posture as the registry.
  static HuVendor fromWire(String? raw) {
    for (final v in HuVendor.values) {
      if (v.wireValue == raw) return v;
    }
    return HuVendor.unknown;
  }
}
