"""Require a versionCode newer than every published release asset.

`tool/set_version_code.dart` derives the code from the versionName immediately
before this runs; this is the independent check that the result actually moves
forward, because Android refuses an update whose versionCode did not increase.

There is no lower bound beyond "positive": iLINK ships under its own
applicationId, so it carries no continuity requirement from any earlier app.
"""
import json
import os
import re
import subprocess
from pathlib import Path


def gh(*args):
    return subprocess.check_output(['gh', 'api', *args], text=True)


def main():
    text = Path('pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r'^version: [^\r\n]+\+(\d+)\s*$', text, re.MULTILINE)
    if not match or int(match[1]) < 1:
        raise SystemExit('versionCode must be an explicit positive integer')
    current = int(match[1])
    repo = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise SystemExit('Invalid repository')
    pages = json.loads(gh(f'repos/{repo}/releases?per_page=100', '--paginate', '--slurp'))
    highest = 0
    for releases in pages:
        for release in releases:
            for asset in release.get('assets', []):
                if asset.get('name') != 'ilink-release.json':
                    continue
                if not 0 < asset.get('size', 0) <= 65536:
                    raise SystemExit('Invalid previous release metadata size')
                # API resource ID avoids trusting a release-supplied download URL.
                asset_id = int(asset['id'])
                metadata = json.loads(gh(f'repos/{repo}/releases/assets/{asset_id}', '-H', 'Accept: application/octet-stream'))
                code = metadata.get('versionCode')
                if type(code) is not int or code < 1:
                    raise SystemExit('Invalid previous release versionCode')
                highest = max(highest, code)
    if current <= highest:
        raise SystemExit(f'versionCode {current} must exceed previous release {highest}')
    print(f'versionCode {current} is newer than published baseline {highest}')


if __name__ == '__main__':
    main()
