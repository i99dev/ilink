# Firmware extraction recipe

Step-by-step for unpacking a BYD OTA ZIP to the point where you can
diff `build.prop` and read APK manifests. Validated on the three
firmwares analysed for v1.5.0-b (L8 / L5L / 5f); future BYD trims
should follow the same shape with at most one twist.

## Prerequisites (one-time)

- **Python 3** with these packages in your user site:
  ```sh
  pip install payload-dumper ext4 androguard pyaxmlparser
  ```
- **7-Zip** for ext4 listing when the Python `ext4` package can't
  open a particular image:
  ```sh
  scoop install 7zip
  ```
- ~50 GB free on the disk where you'll extract — each firmware
  expands to ~10–15 GB.

## Step 1 — outer ZIP

The outer container is a regular ZIP. The user-visible layout
differs by DiLink generation but unzip handles both:

```sh
mkdir -p D:/byd && cd D:/byd
unzip Di5.1_..._-----l8.zip   # outer L8 / L5L
unzip Di5.0_..._5f.zip        # outer 5f
```

What you'll see inside:

| File | Di5.1 (L8 / L5L) | Di5.0 (5f) |
|---|---|---|
| `Anc/`, `Dsp/`, `Mcu/` | audio + DSP + microcontroller blobs (not useful for app compat work) | (only `anc/` exists) |
| `Config.xml` | encrypted BYD config blob | absent |
| `META-INF/com/android/otacert` | signing cert (verify-only) | same |
| `metadata` | OTA fingerprint — **always read this first** | same |
| `Android/Target/android.zip` | wrapped Android payload — Di5.1 is **encrypted** (see [encryption-notes.md](./encryption-notes.md)) | absent |
| `update.zip` | absent | wrapped Google A/B OTA — **standard zip**, can extract |

## Step 2 — read the metadata first

Before any heavy extraction, `cat metadata` at the outer root.
You'll get the build fingerprint and trim discriminators that
classify the firmware without touching `system.img`:

```
post-build       = BYD-AUTO/IVI/IVI:13/TP1A.220624.014/...
post-carseries   = F                      ← BYD's vehicle architecture family
post-ads-platform= huawei | default       ← Huawei vs BYD's own ADAS
post-multidisplayuser = 1                 ← present iff Di5.1
post-sdk-level   = 32 | 33                ← Android 12 (Di5.0) vs 13 (Di5.1)
pre-device       = IVI | DiLink5.0
post-project-type= 5.0                    ← Di5.0 only; Di5.1 omits
```

That's enough to know which compatibility class the trim falls
into. If you see `post-ads-platform=huawei` it's the L8-class
(Huawei ADAS); `default` is BYD's own (`com.byd.naviauto`).

## Step 3a — Di5.0 inner payload (5f-class)

The inner `update.zip` is a vanilla Google A/B OTA. Two more
extraction passes:

```sh
mkdir -p D:/byd/extracted/5f && cd D:/byd/extracted/5f
unzip /d/byd/Di5.0_..._5f/update.zip   # pulls payload.bin, ~6.2 GB

# payload.bin is Google's A/B OTA format. payload_dumper splits it
# into per-partition .img files (system / vendor / product / system_ext).
payload_dumper --out parts \
  --partitions system,vendor,product,system_ext payload.bin
```

This takes 5–15 min depending on disk speed. Output is
`parts/system.img` (~6.6 GB), `parts/vendor.img`, `parts/product.img`,
`parts/system_ext.img`.

## Step 3b — Di5.1 inner payload (L8 / L5L-class)

The inner `Android/Target/android.zip` has non-standard magic bytes
(`42 e2 ee f0` on L8, `50 e4 6c 1c` on L5L) and high entropy
throughout — it's BYD-encrypted, not a plain zip. See
[encryption-notes.md](./encryption-notes.md) for what we know and
what the bypass paths are.

Practical workaround until/unless the encryption is broken: pull
the same data from running L8 / L5L hardware over ADB, since the
device decrypts on first boot. The rest of this recipe still
applies once you have the partition images.

## Step 4 — read `build.prop`

```sh
cd <byd-workspace>
python tools/ext4_extract.py \
  D:/byd/extracted/5f/parts/system.img D:/byd/extracted/5f/sys \
  build.prop default.prop
```

This pulls every file whose path contains "build.prop" or
"default.prop" (~3 hits). Look in the output directory:

```
D:/byd/extracted/5f/sys/system/build.prop      ← /system/build.prop
D:/byd/extracted/5f/sys/build.prop             ← /vendor/build.prop or similar
```

Cross-reference values against [build-prop.md](./build-prop.md). A
new trim should add a column there.

## Step 5 — APK catalog

```sh
python tools/ext4_catalog.py \
  D:/byd/extracted/5f/parts/system.img \
  D:/byd/extracted/5f/system.catalog.txt
```

Catalog is a flat text file: one path per line with `f <size>` for
files and `d` for directories. Filter for BYD-prefixed APKs:

```sh
grep -iE "Byd[A-Z][a-z]+\.apk$" D:/byd/extracted/5f/system.catalog.txt
```

The 5f firmware has 91 APKs in `/system/app` alone — see
[apk-catalog.md](./apk-catalog.md) for the curated list of which
ones are relevant for compat work.

## Step 6 — read APK manifests

For any APK suspected of owning a divergence axis (typically the
ADAS map app and the launcher), pull the binary and read its
manifest:

```sh
# Pull the APK
python tools/ext4_extract.py \
  D:/byd/extracted/5f/parts/system.img D:/byd/extracted/5f/sys \
  BydAutoMap.apk

# Then in Python:
python -c "
from pyaxmlparser import APK
a = APK('D:/byd/extracted/5f/sys/system/app/BydAutoMap/BydAutoMap.apk')
print('package:', a.package)
print('main_activity:', a.get_main_activity())
print('activities:', len(a.get_activities()))
print('services:', len(a.get_services()))
print('providers:', len(a.get_providers()))
"
```

For the full XML (intent filters, taskAffinity, launchMode):

```sh
python -c "
import sys
from loguru import logger; logger.remove()
from androguard.core.apk import APK
xml = APK('D:/byd/extracted/5f/sys/system/app/BydAutoMap/BydAutoMap.apk').get_android_manifest_axml().get_xml()
sys.stdout.buffer.write(xml)
" > D:/byd/extracted/5f/manifest.naviauto.xml
```

Then grep the manifest for the activity that targets the cluster
display — typically a `taskAffinity` containing "meter" or a
`launchMode="singleInstance"` activity inside the BYD ADAS-map
package.

## Common gotchas

- **Non-ASCII filenames.** Some BYD apps have Chinese characters
  in their directory names; `tools/ext4_extract.py` already
  sanitises per-component to keep Windows NTFS happy.
- **Sparse zip artifacts.** 7-Zip's auto-detect sometimes finds a
  fake zip header inside an ext4 image and stops listing. Force
  the type with `7z l -tExt …` or use the Python `ext4` package.
- **`SystemProperties.get` not in stock Android SDK.** When testing
  the model detector locally, the platform-channel side will
  return null on most non-BYD Android builds. The Dart classifier
  treats null/empty the same — falls back to `unknown`, which is
  the safest behavior.
- **Different OTA tooling per generation.** Di5.0 uses Google A/B
  with `payload.bin`. Di5.1 wraps the same shape inside the BYD
  encryption layer. New generations may change again — always read
  `metadata` first to spot the change.
