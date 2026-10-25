# Guarded patch lifecycle

PVE-mods still modifies Proxmox-owned files. These safeguards reduce update
risk; they do not turn those modifications into an official Proxmox plugin.

The opt-in dpkg upgrade trigger uses automatic mode. For every patch target it
requires either the exact installed vendor bytes from the owning package's
`/var/lib/dpkg/info/*.md5sums`, or a previously verified PVE-mods output recorded
for that same package, package version and vendor checksum. Missing checksums,
ambiguous ownership, locally modified inputs and old outputs after a package
version change are held unchanged. Dpkg's local metadata is the trust anchor;
this is not a separate package-signature or supported-version manifest.

Patches use deterministic zero-fuzz matching. A complete ordered patch set is
assembled in a staging directory, including dependent patches touching the same
file. Changed JavaScript is checked with `node --check`; automatic mode holds if
Node is unavailable. Manual mode still permits a missing Node validator and does
not compile Perl. Syntax success cannot establish UI or API compatibility.

## Persistent Perl validator

Automatic Perl changes also require an administrator-provided validator at
`/etc/pve-mods/validator`. It must be a root-owned regular executable, with no
symlinks or group/other-writable file or ancestor directory. It is called once for
each changed `.pm` target as:

```text
/etc/pve-mods/validator STAGED_ROOT RELATIVE_TARGET
```

Exit 0 means the assembled target passed the administrator's validation;
any other exit status holds the module. Output goes to the operation log.
The hook runs with the patcher's privileges. It must leave the live host and
staging tree unchanged. `PVE_MODs_VALIDATOR=/absolute/path` overrides this location
for explicitly managed invocations and has the same ownership requirements.
The default persistent location works from dpkg triggers without environment
configuration. No validator is enabled automatically: until one is installed,
automatic node_info changes involving Perl are held with a visible reason.

A minimal validator for reviewed PVE-mods patches on a host with matching PVE Perl
libraries can use the following script. Review it before installing it as
root: `perl -c` executes Perl `BEGIN` blocks and imports host dependencies. For
stronger isolation, replace it with a validator that invokes a disposable
environment containing the matching Proxmox packages.

```bash
#!/bin/bash
set -euo pipefail
staged_root="$1"
relative_target="$2"
case "$relative_target" in
    usr/share/perl5/PVE/API2/Nodes.pm) ;;
    *) echo 'Unsupported Perl validation target' >&2; exit 1 ;;
esac
exec /usr/bin/perl -I "$staged_root/usr/share/perl5" -c "$staged_root/$relative_target"
```

Install the reviewed script using `install -o root -g root -m 0755` at the
persistent path. A compile failure or missing PVE dependency holds the module;
this script does not check application behavior. Run a check against the actual
host before depending on automatic activation.

## Transactions, status and recovery

Apply, revert and package preinst share `/var/lib/pve-mods/lifecycle.lock`.
Configuration tools must use that same lock. All live hashes are checked before
the first replacement, and checked again immediately before each replacement.
Each replacement writes a same-directory temporary file, preserves snapshot
metadata, flushes it and renames it. The journal, target data and directory
changes are flushed before a successful transaction is discarded.

Multi-file activation is recoverable per file, not globally atomic. Journals
live under `/var/lib/pve-mods/transactions/txn.*`, with `before/` and `after/`
snapshots and a `committed` TSV containing target path, before SHA256 and after
SHA256. An interrupted operation blocks subsequent operations until reviewed.
The patcher does not blindly restore old vendor bytes after an unrelated update.

On a checked write failure, rollback restores only targets whose bytes still
match its own output. A third-party edit is preserved and leaves a recovery
journal. This guard covers file content: metadata-only external changes are not
identified separately, and restoration uses the snapshot metadata. The lock
coordinates PVE-mods tools; an external writer can still race between the final
check and rename. Hooks have their own side effects outside the text journal.

Last-operation status is stored in `/var/lib/pve-mods/status/MODULE.json` with
`module`, `state`, `reason`, `timestamp` (UTC) and `automatic` fields. States are
`active`, `inactive`, `blocked`, `error` or `recovery-required`. This is a record
of the operation, not a continuous health or current-integrity assessment.
Known outputs are recorded in `/var/lib/pve-mods/known-outputs.tsv` only from
recognized inputs and successful transactions. Do not edit that file to bypass
a failed input check.

For a retained journal, compare its snapshots/hashes with the current files and
installed package version before taking action. Restore vendor originals by
reinstalling the correct Proxmox package when appropriate; preserve conflicting
local edits. Remove a journal only after manually resolving its state, then
rerun the check. Service restart failures are reported, but PVE-mods does not
currently perform runtime/API health checks or automatic health-based rollback.

`PVE_MODs_CHECK_ONLY=1` on `apply-patches.sh` stages and validates without running
hooks, changing live targets, restarting services or updating status. It still
acquires the lock and uses temporary staging files. Combine it with
`PVE_MODs_AUTOMATIC=1` to exercise the automatic trust and validator gates.

For isolated testing, `PVE_MODs_ROOT`, `PVE_MODs_STATE_DIR`, `PVE_MODs_DPKG_DIR`,
`PVE_MODs_LOCK_FILE` and configuration/patch directory overrides redirect the
relevant paths. State directory defaults to `ROOT/var/lib/pve-mods`; dpkg metadata
defaults to `ROOT/var/lib/dpkg`. They are test/administration interfaces, not a
mechanism for an unprivileged user to authorize host patching.

Upgrading from an older PVE-mods version without the shared helper uses the
checked legacy preinst reversion once. Later upgrades use staged reversion.
Automatic-trigger failures warn and hold the modification; they do not fail the
Proxmox package upgrade.
