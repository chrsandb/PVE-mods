#!/usr/bin/env bash
# Installed package trust, validation, race and interruption fixtures.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PVE_MODs_ROOT="$TMP/root" PVE_MODs_STATE_DIR="$TMP/state"
export PVE_MODs_DPKG_DIR="$TMP/root/var/lib/dpkg"
mkdir -p "$PVE_MODs_ROOT/usr/share/demo" "$PVE_MODs_DPKG_DIR/info"
source "$REPO/src/scripts/patch-transaction.sh"
transaction_lock
file="$PVE_MODs_ROOT/usr/share/demo/file.js"
printf 'const temperature = 1;\n' > "$file"
cat > "$TMP/good.patch" <<'PATCH'
--- a/usr/share/demo/file.js
+++ b/usr/share/demo/file.js
@@ -1 +1 @@
-const temperature = 1;
+const temperature = 2;
PATCH
cat > "$PVE_MODs_DPKG_DIR/status" <<'STATUS'
Package: demo
Status: install ok installed
Architecture: all
Version: 1.0
Description: fixture

STATUS
printf '/usr/share/demo/file.js\n' > "$PVE_MODs_DPKG_DIR/info/demo.list"
printf '%s  usr/share/demo/file.js\n' "$(md5sum "$file" | cut -d' ' -f1)" > "$PVE_MODs_DPKG_DIR/info/demo.md5sums"
PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/good.patch"
transaction_finish
# Recorded outputs are valid for this package version only.
PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/good.patch"
[[ $TRANSACTION_CHANGED == false ]]
transaction_finish
sed -i 's/Version: 1.0/Version: 2.0/' "$PVE_MODs_DPKG_DIR/status"
if PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/good.patch"; then exit 1; fi
[[ $TRANSACTION_REASON == 'unrecognized package input:'* ]]
sed -i 's/Version: 2.0/Version: 1.0/' "$PVE_MODs_DPKG_DIR/status"
transaction_patchset reverse "$TMP/good.patch"
transaction_finish
# This still matches patch context and parses, but is not vendor input.
printf '// third party addition\n' >> "$file"
if PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/good.patch"; then exit 1; fi
grep -q 'third party addition' "$file"
printf 'const temperature = 1;\n' > "$file"
# Staged JS syntax is actually checked, not just the source assets.
sed 's/+const temperature = 2;/+const temperature = ;/' "$TMP/good.patch" > "$TMP/bad-js.patch"
if transaction_patchset apply "$TMP/bad-js.patch"; then exit 1; fi
[[ $TRANSACTION_REASON == 'JavaScript syntax validation failed:'* ]]
grep -q 'temperature = 1' "$file"
sed 's@usr/share/demo/file.js@../outside@g' "$TMP/good.patch" > "$TMP/path.patch"
printf 'outside\n' > "$TMP/outside"
if transaction_patchset apply "$TMP/path.patch"; then exit 1; fi
[[ $(cat "$TMP/outside") == outside ]]
# Actual reverse write failure must be reported and preserve patched input.
transaction_patchset apply "$TMP/good.patch"
transaction_finish
eval "$(declare -f transaction_replace | sed '1s/transaction_replace/real_transaction_replace/')"
transaction_replace() { return 1; }
if transaction_patchset reverse "$TMP/good.patch"; then exit 1; fi
grep -q 'temperature = 2' "$file"
unset -f transaction_replace
eval "$(declare -f real_transaction_replace | sed '1s/real_transaction_replace/transaction_replace/')"
transaction_patchset reverse "$TMP/good.patch"
transaction_finish
# An edit to a later target during validation blocks the whole precommit group.
cp "$file" "$PVE_MODs_ROOT/usr/share/demo/second.js"
sed 's@demo/file.js@demo/second.js@g' "$TMP/good.patch" > "$TMP/second.patch"
mkdir "$TMP/bin"
cat > "$TMP/bin/node" <<'NODE'
#!/bin/bash
printf 'external writer\n' > "$PVE_MODs_ROOT/usr/share/demo/second.js"
exit 0
NODE
chmod +x "$TMP/bin/node"
if PATH="$TMP/bin:$PATH" transaction_patchset apply "$TMP/good.patch" "$TMP/second.patch"; then exit 1; fi
[[ $TRANSACTION_REASON == 'live input changed during staging:'* ]]
grep -q 'temperature = 1' "$file"
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/second.js") == 'external writer' ]]
# Known vendor Perl input must reach the validation gate, not just the trust gate.
cp "$file" "$PVE_MODs_ROOT/usr/share/demo/file.pm"
sed 's@demo/file.js@demo/file.pm@g' "$TMP/good.patch" > "$TMP/perl.patch"
printf '/usr/share/demo/file.pm\n' >> "$PVE_MODs_DPKG_DIR/info/demo.list"
printf '%s  usr/share/demo/file.pm\n' "$(md5sum "$PVE_MODs_ROOT/usr/share/demo/file.pm" | cut -d' ' -f1)" >> "$PVE_MODs_DPKG_DIR/info/demo.md5sums"
if PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/perl.patch"; then exit 1; fi
[[ $TRANSACTION_REASON == 'trusted /etc/pve-mods/validator unavailable'* ]]
# Persistent validator lookup checks root ownership and writable ancestors.
mkdir -p "$PVE_MODs_ROOT/etc/pve-mods"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$PVE_MODs_ROOT/validator-args"\n' > "$PVE_MODs_ROOT/etc/pve-mods/validator"
chmod 755 "$PVE_MODs_ROOT/etc/pve-mods/validator"
if transaction_validator "$TMP/staged" usr/share/demo/file.pm; then exit 1; fi
[[ ! -f "$PVE_MODs_ROOT/validator-args" ]]
# Mock only ownership/modes to exercise persistent-hook discovery as non-root.
cat > "$TMP/bin/stat" <<'STAT'
#!/bin/bash
if [[ $2 == %u ]]; then echo 0; else echo 755; fi
STAT
chmod +x "$TMP/bin/stat"
PATH="$TMP/bin:$PATH" transaction_validator "$TMP/staged" usr/share/demo/file.pm
[[ $(head -1 "$PVE_MODs_ROOT/validator-args") == "$TMP/staged" ]]
[[ $(tail -1 "$PVE_MODs_ROOT/validator-args") == usr/share/demo/file.pm ]]
# A trusted but hung validator is bounded; no live file is activated.
printf '#!/bin/bash\nsleep 10\n' > "$PVE_MODs_ROOT/etc/pve-mods/validator"
if PATH="$TMP/bin:$PATH" PVE_MODs_VALIDATOR_TIMEOUT=0.1s transaction_validator "$TMP/staged" usr/share/demo/file.pm; then exit 1; fi
# A process killed after rename leaves its journal; the next run holds it.
if PVE_MODs_STATE_DIR="$TMP/interrupted" bash -c '
    source "$1"
    transaction_lock
    transaction_patchset apply "$2"
    kill -TERM $$
' _ "$REPO/src/scripts/patch-transaction.sh" "$TMP/good.patch"; then exit 1; fi
compgen -G "$TMP/interrupted/transactions/txn.*/committed" >/dev/null
if PVE_MODs_STATE_DIR="$TMP/interrupted" transaction_patchset apply "$TMP/good.patch"; then exit 1; fi
echo '[test] PASS: package identity, recorded outputs, validators, invalid JS/paths, reverse failure, precommit races and interruption journal'
