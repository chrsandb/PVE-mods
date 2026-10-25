#!/usr/bin/env python3
"""Installer contract tests: all network/package/service commands are stubbed."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[2] / 'install.sh'
FINGERPRINT = 'A' * 40


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], FIXTURE=str(self.root))
        self.package = b'fixture-package\n'
        (self.root / 'package').write_bytes(self.package)
        (self.root / 'keyring').touch()
        self.name = 'pve-mods_2.2.0_all.deb'
        self.base = 'https://github.com/Meliox/PVE-mods/releases/download/v2.2.0/'
        self.metadata = {'tag_name': 'v2.2.0', 'assets': [
            {'name': name, 'browser_download_url': self.base + name}
            for name in (self.name, 'SHA256SUMS', 'SHA256SUMS.asc')]}
        self.save_metadata()
        (self.root / 'sums').write_text(hashlib.sha256(self.package).hexdigest() + '  ../' + self.name + '\n')
        self.stub('id', 'echo 0')
        self.stub('dpkg-query', '''case "$*" in
*Status*) printf 'install ok installed';;
*) exit 1;; esac''')
        self.stub('dpkg-deb', '''case "$3" in
Package) echo pve-mods;; Architecture) echo all;; Version) echo 2.2.0;; esac''')
        self.stub('apt-get', 'printf "%s\\n" "$*" >> "$FIXTURE/installed"')
        self.stub('gpgv', '''if [[ "${BAD_SIGNATURE:-0}" == 1 ]]; then exit 1; fi
printf '[GNUPG:] VALIDSIG %s 2026-10-25 1 0 4 0 22 8 00 %s\\n' "${SIGNER:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}" "${SIGNER:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}"''')
        self.stub('curl', '''url=""; dest=""
while [[ $# -gt 0 ]]; do
case "$1" in
-o) dest="$2"; shift 2;;
https://*) url="$1"; shift;;
*) shift;; esac
done
case "$url" in
https://api.github.com/*) cp "$FIXTURE/metadata" "$dest";;
*/SHA256SUMS.asc) if [[ -f "$FIXTURE/signature" ]]; then cp "$FIXTURE/signature" "$dest"; else printf signature > "$dest"; fi;;
*/SHA256SUMS) cp "$FIXTURE/sums" "$dest";;
*.deb) cp "$FIXTURE/package" "$dest";;
*) exit 22;; esac''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def save_metadata(self):
        (self.root / 'metadata').write_text(json.dumps(self.metadata))

    def run_install(self, *args):
        return subprocess.run(['bash', str(INSTALLER), *args], env=self.env, text=True, capture_output=True)

    def signed(self, *args):
        return self.run_install('--yes', '--keyring', str(self.root / 'keyring'),
                                '--signing-fingerprint', FINGERPRINT, *args)

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'installed').exists())

    def test_valid_signed_release_uses_one_apt_transaction(self):
        result = self.signed('--version', 'v2.2.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'installed').read_text().splitlines()), 1)

    @unittest.skipUnless(shutil.which('gpg') and shutil.which('gpgv'), 'GnuPG required')
    def test_real_detached_signature_roundtrip(self):
        home = self.root / 'gnupg'
        home.mkdir(mode=0o700)
        gpg = ['gpg', '--homedir', str(home), '--batch', '--pinentry-mode', 'loopback', '--passphrase', '']
        subprocess.run([*gpg, '--quick-generate-key', 'Installer fixture <fixture@example.invalid>', 'ed25519', 'sign', '0'], check=True, capture_output=True)
        keys = subprocess.run([*gpg, '--with-colons', '--list-keys'], check=True, capture_output=True, text=True).stdout
        fingerprint = next(line.split(':')[9] for line in keys.splitlines() if line.startswith('fpr:'))
        with (self.root / 'keyring').open('wb') as stream:
            subprocess.run([*gpg, '--export', fingerprint], stdout=stream, check=True)
        subprocess.run([*gpg, '--detach-sign', '--output', str(self.root / 'signature'), str(self.root / 'sums')], check=True, capture_output=True)
        (self.bin / 'gpgv').unlink()
        result = self.run_install('--yes', '--keyring', str(self.root / 'keyring'), '--signing-fingerprint', fingerprint)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unattended_requires_signature_trust(self):
        self.assert_refused(self.run_install('--yes'))

    def test_invalid_signature_blocks_install(self):
        self.env['BAD_SIGNATURE'] = '1'
        self.assert_refused(self.signed())

    def test_wrong_fingerprint_blocks_install(self):
        self.env['SIGNER'] = 'B' * 40
        self.assert_refused(self.signed())

    def test_wrong_checksum_blocks_install(self):
        (self.root / 'package').write_bytes(b'changed')
        self.assert_refused(self.signed())

    def test_duplicate_checksum_blocks_install(self):
        sums = self.root / 'sums'
        sums.write_text(sums.read_text() * 2)
        self.assert_refused(self.signed())

    def test_missing_checksum_blocks_install(self):
        self.metadata['assets'] = self.metadata['assets'][:1]
        self.save_metadata()
        self.assert_refused(self.signed())

    def test_wrong_release_tag_blocks_install(self):
        self.assert_refused(self.signed('--version', 'v2.1.0'))

    def test_foreign_asset_origin_blocks_install(self):
        self.metadata['assets'][0]['browser_download_url'] = 'https://example.com/package.deb'
        self.save_metadata()
        self.assert_refused(self.signed())

    def test_http_failure_blocks_install(self):
        self.stub('curl', 'exit 22')
        self.assert_refused(self.signed())

    def test_missing_argument_has_clear_error(self):
        result = self.run_install('--version')
        self.assert_refused(result)
        self.assertIn('Missing value', result.stderr)

    def test_non_pve_host_blocks_install(self):
        self.stub('dpkg-query', 'exit 1')
        self.assert_refused(self.signed())

    def test_downgrade_blocks_install(self):
        self.stub('dpkg-query', '''case "$*" in
*Status*) printf 'install ok installed';;
*) echo 9.0.0;; esac''')
        self.assert_refused(self.signed())

    def test_metadata_package_identity_is_checked(self):
        self.stub('dpkg-deb', 'echo unexpected-package')
        self.assert_refused(self.signed())


if __name__ == '__main__':
    unittest.main(verbosity=2)
