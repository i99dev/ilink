# Firmware-analysis tools

Python helpers that live in
`<byd-workspace>/tools/` (NOT in the dash repo — they
operate on firmware blobs, which are never committed). Reproduce
locally on any machine with Python 3.13+ and ~50 GB of free disk.

`<byd-workspace>` is any scratch directory you choose outside this repository;
firmware blobs and the helper scripts that operate on them are never committed.

## Installation

```sh
pip install payload-dumper ext4 androguard pyaxmlparser crypto
```

`payload-dumper` is the official A/B-OTA splitter for Google
update payloads. `ext4` is a pure-Python ext2/4 reader (works on
Windows without WSL). `androguard` and `pyaxmlparser` decode
Android binary XML manifests.

## `tools/ext4_extract.py`

Walk an ext4 image and pull files matching a list of substring
needles.

```sh
python tools/ext4_extract.py <img> <out_dir> <needle1> [<needle2> ...]
```

Examples:

```sh
# Pull every build.prop from system.img
python tools/ext4_extract.py D:/byd/extracted/5f/parts/system.img \
  D:/byd/extracted/5f/sys build.prop

# Pull a specific APK
python tools/ext4_extract.py D:/byd/extracted/5f/parts/system.img \
  D:/byd/extracted/5f/sys BydAutoMap.apk
```

Empty needles list = pull everything (slow + 6 GB of output;
prefer the catalog tool for that).

The script sanitises Windows-incompatible path components (some
BYD apps embed Chinese characters in directory names), preserves
the `/` separator, and writes output preserving the in-image
directory tree.

## `tools/ext4_catalog.py`

List the full file tree of an ext4 image to a single text file —
no file bodies, just paths + sizes. Use this BEFORE you decide
which APKs to extract.

```sh
python tools/ext4_catalog.py <img> <out.txt>
```

Output format:

```
d /system
d /system/app
f      6963780 /system/app/AcquisitionControl/AcquisitionControl.apk
f       248186 /system/app/AppStartManagement/AppStartManagement.apk
...
l /system/lib/libfoo.so       (symlink)
```

A 5f system.img produces a ~3,000-line catalog (all 91 BYD APKs
plus framework, vendor libs, fonts, etc.). Filter for what you
care about:

```sh
# All BYD-prefixed APKs
grep -iE "Byd[A-Z][a-z]+\.apk$" out.txt

# All ContentProviders (look for com.byd.* pattern in package names)
grep -iE "/(content)?[Pp]rovider" out.txt

# Files mentioning a specific term
grep "amap" out.txt
```

## `payload_dumper` (third-party)

Splits Google A/B `payload.bin` into per-partition images.
Installed by `pip install payload-dumper`.

```sh
# Full extraction — all partitions
payload_dumper.exe --out parts payload.bin

# Just the partitions we need (faster)
payload_dumper.exe --out parts \
  --partitions system,vendor,product,system_ext payload.bin
```

Output: `parts/system.img`, `parts/vendor.img`, etc. Each is a
plain ext4 filesystem ready for `ext4_extract.py` /
`ext4_catalog.py`.

Doesn't apply to Di5.1 OTAs (those are BYD-encrypted before the
A/B layer; see [`encryption-notes.md`](./encryption-notes.md)).

## `androguard` quick recipes

Read APK package + main activity:

```python
from pyaxmlparser import APK
a = APK('path/to/app.apk')
print(a.package, a.version_name, a.get_main_activity())
```

Read the full binary manifest as XML (for intent filters,
launchMode, taskAffinity):

```python
import sys
from loguru import logger; logger.remove()  # silence chatty debug logs
from androguard.core.apk import APK
xml = APK('path/to/app.apk').get_android_manifest_axml().get_xml()
sys.stdout.buffer.write(xml)
```

Pipe the output to a file and grep for activities you suspect own
the cluster slot:

```sh
python -c "..." > app.manifest.xml
grep -E "Meter|Cluster|Display|launchMode|taskAffinity" app.manifest.xml
```

## `7-Zip` for ext4 listing fallback

When the Python `ext4` package can't open a particular image
(rare; usually a malformed superblock), 7-Zip's ext4 reader is
the fallback:

```sh
7z l -tExt path/to/image.img | head
```

Force the Ext type because 7-Zip's auto-detect sometimes finds a
fake zip header inside the image and stops listing prematurely.

## Workflow — full firmware analysis pass

End-to-end recipe for a new Di5.0-class firmware:

```sh
# 1. outer extract
mkdir -p D:/byd/extracted/<trim> && cd D:/byd/extracted/<trim>
unzip /d/byd/<trim>.zip

# 2. inner update.zip
mkdir parts && cd parts
unzip ../update.zip          # gets payload.bin + metadata
payload_dumper.exe --out . \
  --partitions system,vendor,product,system_ext payload.bin

# 3. catalog system.img
cd <byd-workspace>
python tools/ext4_catalog.py \
  D:/byd/extracted/<trim>/parts/system.img \
  D:/byd/extracted/<trim>/system.catalog.txt

# 4. pull build.prop
python tools/ext4_extract.py \
  D:/byd/extracted/<trim>/parts/system.img \
  D:/byd/extracted/<trim>/sys build.prop

# 5. cross-reference
diff <(awk '{print $NF}' D:/byd/extracted/5f/system.catalog.txt | sort) \
     <(awk '{print $NF}' D:/byd/extracted/<trim>/system.catalog.txt | sort)
```

A new-trim diff against 5f highlights:
- New BYD APKs only this trim has (potential new family or new
  ADAS-map override).
- Removed APKs (suggesting a different vendor integration we'd
  miss).
- Renamed paths.

For a Di5.1 firmware, skip step 2 (encrypted) and either get ADB
access to real hardware or accept that you'll route through the
coarse `dilinkFamily="di5.1"` fallback.

## Disposal

Firmware blobs are large and trim-specific; never commit them.
After analysis, the extracted directories under `D:/byd/extracted/`
can be deleted to reclaim disk. Keep the original ZIPs around in
case future analysis needs to re-extract; they're 5-10 GB each
but compress well to cold storage.
