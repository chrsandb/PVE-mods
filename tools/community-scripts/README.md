# Guarded host-tool integration

`pve-hardware-monitor.sh` is a host-tool entry point suitable for adaptation to
community-scripts/DevScripts `tools/pve/`. It is not an accepted/listed community
script. New scripts must go through that project's review and real-host tests.

This wrapper delegates every mutation to the installed PVE-mods package. It
creates no APT hooks, does not hold Proxmox updates, installs no GPU drivers,
and enables only `node_info`. It refuses an already enabled `nag_screen` rather
than changing an unrelated feature. Existing community post-install helpers
remain owned by community-scripts.

Install a tested release built from this branch first. No published legacy
release should be assumed to include the guarded engine or CLI. The wrapper can
bootstrap a new release when all documented `var_pve_mods_*` inputs are supplied;
use `--help` for them. Pin a reviewed bootstrap commit and provision the release
public keyring/fingerprint independently. Do not retrieve and trust a signing
key merely because it is attached to the same download.

Example with the guarded package already installed:

```sh
var_pve_mods_confirm=yes var_pve_mods_auto=off \
  bash tools/community-scripts/pve-hardware-monitor.sh install
pve-mods status --json
pve-mods check --automatic node_info
```

Automatic mode requires validators for changed targets. A missing validator
holds activation with a reason; it is not evidence that the host is broken.
Intel utilization also needs its documented permissions; these are not granted
by this installer. Intel temperature availability remains hardware-dependent.

## Bootstrap changes

The top-level installer supports `--version TAG`, `--repo OWNER/REPO`, `--yes`,
`--keyring FILE`, and `--signing-fingerprint FULL_FINGERPRINT`. Checksums are
mandatory, exact asset URLs are checked, downgrades refused, and HTTP failures
stop installation. Supplying signature trust verifies `SHA256SUMS.asc` before
using its hashes. Unattended installation requires signature trust; interactive
installation without it reports that only checksum integrity is verified.
A single `apt-get install /path/to/package.deb` resolves dependencies instead of
running a broad `apt-get --fix-broken` recovery.

The user must independently confirm the upstream release signing fingerprint;
this branch does not invent one or claim the legacy release signature has been
authenticated. Unsigned or corrupt unattended downloads are refused.

## Validation

```sh
python3 build/test/test-installer.py
python3 build/test/test-management-cli.py
bash -n tools/community-scripts/pve-hardware-monitor.sh
shellcheck install.sh tools/community-scripts/pve-hardware-monitor.sh
```

Tests use temporary roots and mocked network/package commands. Real PVE install,
upgrade, browser behavior and coexistence with community-scripts must be tested
in disposable hosts before advertising production compatibility. In particular,
exercise post-install before/after installing this package and both upgrade-hook
orders. Current community post-install subscription changes overlap with
`nag_screen`; keep that module off. Other UI modifications may still conflict.
