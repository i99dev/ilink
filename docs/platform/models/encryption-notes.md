# BYD OTA encryption notes

What we observed across the three firmwares analysed for v1.5.0-b
support, and what it means for static analysis of future trims.

## Two generations, two layers

| Generation | Inner blob | Format |
|---|---|---|
| Di5.0 (`5f`) | `update.zip` at outer ZIP root | **standard PK zip** (Google A/B OTA, payload.bin inside) — extracts cleanly with `unzip` |
| Di5.1 (`l8`, `l5l`) | `Android/Target/android.zip` | **BYD-encrypted** — non-PK magic bytes, high entropy throughout, different magic per file |

Magic bytes observed:

```
L8  android.zip first 16:  42 e2 ee f0 21 e1 a3 b9 c0 e9 58 69 8c 3e 37 fa
L5L android.zip first 16:  50 e4 6c 1c 96 36 1d e8 8f 77 cd 2a e3 f8 1e f2
```

Different starting bytes per file rules out a simple-rename.
High entropy throughout (we sampled the first 256 and last 256
bytes of L8, no obvious zeros, no obvious patterns) suggests real
encryption — likely AES-CTR or AES-CBC. The OTA cert in
`META-INF/com/android/otacert` is intact and verifiable, so the
encryption is layered ABOVE the standard Android update format,
not a replacement.

## What this means for static analysis

We **cannot** statically extract Di5.1 firmware via the public
OTA. To get the same data we'd otherwise pull from `system.img`
(build.prop, APK list, AIDL definitions), we have three options:

### Path 1 — on-device extraction (recommended)

The head unit decrypts the OTA on first install, then operates on
the decrypted partitions. ADB-pulling from a running L8 / L5L:

```sh
# build.prop
adb pull /system/build.prop          ./l5l/system_build.prop
adb pull /vendor/build.prop          ./l5l/vendor_build.prop
adb pull /system/system_ext/etc/build.prop ./l5l/system_ext_build.prop

# APK list (no APK bodies, just the catalog)
adb shell pm list packages -f | grep "/system/" > ./l5l/system_apks.txt

# Specific APK manifest (BydAutoMap as example)
APK=$(adb shell pm path com.byd.naviauto | sed 's|^package:||')
adb pull "$APK" ./l5l/BydAutoMap.apk
```

Faster than firmware extraction (no decryption needed), and gives
us exactly the data we need. The downside: needs physical access
to a working unit of each trim we want to support.

### Path 2 — find the encryption key

The decryption logic must be in the head unit somewhere — likely
in the recovery / bootloader / OEM updater. Reverse-engineering
the OTA updater binary would expose the key derivation. This is
non-trivial and may have legal implications depending on how the
binary is licensed.

We have not pursued this path. If we ever do, the scope is:

1. Pull the recovery image off a Di5.1 device (`adb reboot
   recovery`, then dd the recovery partition out).
2. Disassemble the OTA-updater binary inside (typically
   `/sbin/recovery` or similar).
3. Find the function that decrypts `android.zip` before passing
   it to the standard Android updater.
4. Identify the key — could be embedded constant, derived from
   device id, or fetched from a server.

Probably 2–4 weeks of focused work and brittle to firmware
updates.

### Path 3 — wait for an Di5.0 → Di5.1 upgrade OTA

Some BYD trims provide an in-place upgrade ZIP that's NOT
encrypted (because the source device hasn't been updated yet and
needs to read the new image). If we ever lay hands on one of
those, the inner system.img is plaintext.

Unreliable and trim-specific; treat as opportunistic only.

## Why the Di5.0 OTA is plaintext

The `update.zip` in the 5f firmware is a vanilla Google A/B OTA:
`payload.bin` + `payload_metadata.bin` + `META-INF/`. We extract
it with `payload_dumper` (a Python tool that splits payload.bin
into per-partition .img files).

This is the standard Android A/B update format, used by Pixel,
Samsung, and most Android OEMs. BYD didn't add their encryption
layer for Di5.0 — the encryption appears to be a Di5.1-and-newer
addition.

## Implications for new-trim onboarding

When a new trim arrives:

1. **Di5.0 family (or older)** → extract the OTA directly,
   follow [`firmware-extraction.md`](./firmware-extraction.md)
   from start to finish.
2. **Di5.1 family** → start with the OTA's `metadata` file (it's
   plaintext; gives us carseries / ads-platform / multidisplay /
   sdk-level), then either:
   - Get on-device ADB access (Path 1) → ~half day to compat
   - Skip and use coarse `dilinkFamily="di5.1"` routing → covers
     the 80% case if the trim's ADAS-map package is the standard
     `com.byd.naviauto` (which appears to be the Di5.1 default
     when `post-ads-platform=default`)

For now, the runtime detector + `model_match: di5.1` fallback in
the textproto means **a new Di5.1 trim works out of the box for
any op that isn't Huawei-specific**, even without firmware
extraction. The only thing that requires per-trim work is when
the trim ships Huawei ADAS (`post-ads-platform=huawei`) — those
need a per-trim `model_match` entry pointing at the specific
Huawei package name.

## What we DO NOT do

- We do not attempt to break BYD's encryption from this end.
  Future contributors who do should land that work in a separate
  external research archive with appropriate handling
  of the legal/licensing surface, not in the public dash repo.
- We do not redistribute extracted firmware images. Anything
  pulled from a firmware ZIP is for analysis only and stays on
  the engineer's local machine; nothing under
  `D:\byd\extracted\` should ever be committed.
