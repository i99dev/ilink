"""Tests for check-release-version.py, the gate that protects every release.

Run with:  uv run --python 3.12 scripts/ci/check_release_version_test.py

Standard library only, so it needs nothing but an interpreter. The GitHub API
is stubbed by replacing the module's `gh` helper, which keeps the test offline
and lets it assert the one behaviour that matters: a versionCode that does not
move forward must fail the build, because Android will refuse the update
anyway.
"""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('check-release-version.py')


def load_module():
    spec = importlib.util.spec_from_file_location('check_release_version', MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stub_gh(published_code):
    """Fake `gh api`.

    `published_code=None` means a repository with no releases at all, which is
    what a first release actually faces. Any integer means one published
    release whose metadata asset reports that versionCode.
    """

    def gh(*args):
        if 'releases/assets/' in args[0]:
            return json.dumps({
                'versionName': 'x',
                'versionCode': published_code,
                'sha256': 'y',
                'sizeBytes': 1,
            })
        if published_code is None:
            return json.dumps([[]])
        return json.dumps([[{
            'assets': [{'name': 'ilink-release.json', 'size': 120, 'id': 42}],
        }]])

    return gh


class CheckReleaseVersion(unittest.TestCase):
    def setUp(self):
        self._cwd = os.getcwd()
        self._tmp = tempfile.TemporaryDirectory()
        os.chdir(self._tmp.name)
        os.environ['GITHUB_REPOSITORY'] = 'i99dev/ilink'
        self.addCleanup(self._restore)

    def _restore(self):
        os.chdir(self._cwd)
        self._tmp.cleanup()

    def run_guard(self, version, published_code=None):
        Path('pubspec.yaml').write_text(
            f'name: ilink\nversion: {version}\n', encoding='utf-8'
        )
        module = load_module()
        module.gh = stub_gh(published_code)
        module.main()

    def assert_rejected(self, version, published_code=None, contains=''):
        with self.assertRaises(SystemExit) as caught:
            self.run_guard(version, published_code)
        if contains:
            self.assertIn(contains, str(caught.exception))

    def test_accepts_a_code_above_the_published_one(self):
        self.run_guard('3.23.0-b+3023000', published_code=3022000)

    def test_rejects_an_unchanged_code(self):
        # The exact release-#2 failure: release-please bumps the versionName
        # but not the build metadata, so without tool/set_version_code.dart the
        # second release would carry the first one's versionCode.
        self.assert_rejected(
            '3.22.0-b+3022000',
            published_code=3022000,
            contains='must exceed previous release',
        )

    def test_rejects_a_downgrade(self):
        self.assert_rejected('3.22.0-b+3021999', published_code=3022000)

    def test_requires_explicit_build_metadata(self):
        self.assert_rejected('3.22.0-b', contains='explicit positive integer')

    def test_rejects_zero(self):
        self.assert_rejected('3.22.0-b+0', contains='explicit positive integer')

    def test_accepts_a_small_code_on_a_fresh_repository(self):
        # iLINK has its own applicationId and inherits no continuity floor, so
        # a 1.0.0 first release must be allowed.
        self.run_guard('1.0.0+1000000')

    def test_rejects_a_repository_that_is_not_owner_slash_name(self):
        os.environ['GITHUB_REPOSITORY'] = 'i99dev/ilink; rm -rf /'
        self.assert_rejected('3.22.0-b+3022000', contains='Invalid repository')


if __name__ == '__main__':
    unittest.main(verbosity=2)
