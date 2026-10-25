#!/usr/bin/env python3
"""Management/wrapper contracts without real package files or services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
CLI = REPO / 'src/scripts/pve-mods'
WRAPPER = REPO / 'tools/community-scripts/pve-hardware-monitor.sh'


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.config = self.root / 'etc/pve-mods/pve-mods.conf'
        self.config.parent.mkdir(parents=True)
        self.original = '# preserved\n[modules]\nnode_info=0\nnag_screen=0\n[pve_trigger]\nenabled=0\n'
        self.config.write_text(self.original)
        self.env = dict(os.environ, PVE_MODs_ROOT=str(self.root),
                        PVE_MODs_SCRIPTS_DIR=str(self.bin), PATH=str(self.bin) + ':' + os.environ['PATH'])
        for name in ('apply-patches.sh', 'revert-patches.sh'):
            self.stub(name, '''printf '%s|%s|%s\\n' "${PVE_MODs_CHECK_ONLY:-0}" "${PVE_MODs_AUTOMATIC:-0}" "$*" >> "$PVE_MODs_ROOT/calls"
exit "${ENGINE_STATUS:-0}"''')
        self.stub('id', 'echo 0')
        self.stub('pveversion', 'echo pve-manager/fixture')
        self.stub('systemd-detect-virt', 'exit 1')
        self.stub('pve-mods', f'exec python3 "{CLI}" "$@"')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def cli(self, *args):
        return subprocess.run(['python3', str(CLI), *args], env=self.env, capture_output=True, text=True)

    def wrapper(self, *args):
        return subprocess.run(['bash', str(WRAPPER), *args], env=self.env, capture_output=True, text=True)

    def test_configure_is_idempotent_and_preserves_unrelated_lines(self):
        for _ in range(2):
            result = self.cli('configure', '--node-info', '--auto', 'guarded')
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), self.original.replace('node_info=0', 'node_info=1').replace('enabled=0', 'enabled=1'))
        self.assertFalse((self.root / 'calls').exists())

    def test_nag_conflict_preserves_config(self):
        self.config.write_text(self.original.replace('nag_screen=0', 'nag_screen=1'))
        before = self.config.read_bytes()
        self.assertNotEqual(self.cli('configure', '--node-info', '--auto', 'off').returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_missing_config_keys_preserve_original(self):
        self.config.write_text('[modules]\nnode_info=0\n')
        before = self.config.read_bytes()
        self.assertNotEqual(self.cli('configure', '--node-info', '--auto', 'guarded').returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_check_sets_check_only_and_automatic(self):
        self.assertEqual(self.cli('check', '--automatic', 'node_info').returncode, 0)
        self.assertEqual((self.root / 'calls').read_text(), '1|1|node_info\n')

    def test_engine_failure_is_propagated(self):
        self.env['ENGINE_STATUS'] = '7'
        self.assertEqual(self.cli('apply', 'node_info').returncode, 7)

    def test_status_reports_last_operations_and_journals(self):
        state = self.root / 'var/lib/pve-mods'
        (state / 'status').mkdir(parents=True)
        record = {'module': 'node_info', 'state': 'blocked', 'reason': 'validator missing', 'timestamp': 'fixture'}
        (state / 'status/node_info.json').write_text(json.dumps(record))
        (state / 'transactions/txn.fixture').mkdir(parents=True)
        result = self.cli('status', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'last_operations': [record], 'pending_transactions': ['txn.fixture']})

    def test_symlink_config_is_refused(self):
        target = self.root / 'outside'
        target.write_text(self.original)
        self.config.unlink()
        self.config.symlink_to(target)
        self.assertNotEqual(self.cli('configure', '--node-info', '--auto', 'off').returncode, 0)
        self.assertEqual(target.read_text(), self.original)

    def test_lock_contention_leaves_config_unchanged(self):
        import fcntl
        path = self.root / 'var/lib/pve-mods/lifecycle.lock'
        path.parent.mkdir(parents=True)
        self.env['PVE_MODs_LOCK_TIMEOUT'] = '0'
        with path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertNotEqual(self.cli('configure', '--node-info', '--auto', 'off').returncode, 0)
        self.assertEqual(self.config.read_text(), self.original)

    def test_wrapper_runs_only_package_configuration_check_and_apply(self):
        self.env['var_pve_mods_confirm'] = 'yes'
        result = self.wrapper('install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['1|1|node_info', '0|1|node_info'])
        self.assertIn('nag_screen=0', self.config.read_text())
        self.assertFalse((self.root / 'etc/apt').exists())

    def test_wrapper_hold_never_applies(self):
        self.env.update(var_pve_mods_confirm='yes', ENGINE_STATUS='1')
        result = self.wrapper('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['1|1|node_info'])

    def test_wrapper_refuses_container(self):
        self.stub('systemd-detect-virt', 'exit 0')
        self.assertNotEqual(self.wrapper('status').returncode, 0)
        self.assertEqual(self.config.read_text(), self.original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
