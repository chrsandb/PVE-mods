#!/usr/bin/env bash
# Isolated regression fixtures; no host service or package modifications.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PVE_MODs_ROOT="$TMP/root" PVE_MODs_STATE_DIR="$TMP/state"
mkdir -p "$PVE_MODs_ROOT/usr/share/demo"
source "$REPO/src/scripts/patch-transaction.sh"
transaction_lock
printf 'one\n' > "$PVE_MODs_ROOT/usr/share/demo/file"
make_patch() {
    printf '%s\n' '--- a/usr/share/demo/file' '+++ b/usr/share/demo/file' '@@ -1 +1 @@' "-$2" "+$3" > "$TMP/$1"
}
make_patch one.patch one two
make_patch two.patch two three
transaction_patchset apply "$TMP/one.patch" "$TMP/two.patch"
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == three ]]
transaction_finish
transaction_patchset apply "$TMP/one.patch" "$TMP/two.patch"
[[ $TRANSACTION_CHANGED == false ]]
transaction_finish
transaction_patchset reverse "$TMP/two.patch" "$TMP/one.patch"
transaction_finish
transaction_patchset apply "$TMP/one.patch" "$TMP/two.patch"
transaction_rollback
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
# Failure of a later stage cannot leave the first patch live.
make_patch bad.patch unknown broken
if transaction_patchset apply "$TMP/one.patch" "$TMP/bad.patch"; then exit 1; fi
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
transaction_patchset apply "$TMP/one.patch"
transaction_finish
transaction_patchset apply "$TMP/one.patch"
[[ $TRANSACTION_CHANGED == false ]]
transaction_finish
transaction_patchset reverse "$TMP/one.patch"
transaction_finish
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
# A competing mutation defeats rollback and retains a recovery journal.
transaction_patchset apply "$TMP/one.patch"
printf 'vendor update\n' > "$PVE_MODs_ROOT/usr/share/demo/file"
if transaction_rollback; then exit 1; fi
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == 'vendor update' ]]
if transaction_patchset apply "$TMP/one.patch"; then exit 1; fi
rm -rf "$PVE_MODs_STATE_DIR/transactions"
# Lock contention is a truthful failure, with no target mutation.
if PVE_MODs_LOCK_TIMEOUT=0 bash -c 'source "$1"; transaction_lock' _ "$REPO/src/scripts/patch-transaction.sh"; then exit 1; fi
# Actual commit failure on the second file restores the first exactly.
printf 'one\n' > "$PVE_MODs_ROOT/usr/share/demo/file"
printf 'one\n' > "$PVE_MODs_ROOT/usr/share/demo/second"
sed 's@demo/file@demo/second@g' "$TMP/one.patch" > "$TMP/second.patch"
eval "$(declare -f transaction_replace | sed '1s/transaction_replace/real_transaction_replace/')"
transaction_replace() {
    [[ "$2" != */second ]] || return 1
    real_transaction_replace "$@"
}
if transaction_patchset apply "$TMP/one.patch" "$TMP/second.patch"; then exit 1; fi
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/second") == one ]]
unset -f transaction_replace
eval "$(declare -f real_transaction_replace | sed '1s/real_transaction_replace/transaction_replace/')"
# Automatic Perl changes need an explicit environment-matching validator.
sed 's@demo/file@demo/test.pm@g' "$TMP/one.patch" > "$TMP/perl.patch"
printf 'one\n' > "$PVE_MODs_ROOT/usr/share/demo/test.pm"
if PVE_MODs_AUTOMATIC=1 transaction_patchset apply "$TMP/perl.patch"; then exit 1; fi
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/test.pm") == one ]]
PVE_MODs_CHECK_ONLY=1 transaction_patchset apply "$TMP/one.patch"
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
# Symlinks are not traversed.
rm "$PVE_MODs_ROOT/usr/share/demo/file"
printf 'one\n' > "$TMP/external"
ln -s "$TMP/external" "$PVE_MODs_ROOT/usr/share/demo/file"
if transaction_patchset apply "$TMP/one.patch"; then exit 1; fi
[[ $(cat "$TMP/external") == one ]]
echo '[test] PASS: ordered staging, rollback, idempotence, unknown input, conflict recovery, locks and symlinks'
# Exercise entrypoint hooks/status without touching real services.
rm "$PVE_MODs_ROOT/usr/share/demo/file"
printf 'one\n' > "$PVE_MODs_ROOT/usr/share/demo/file"
mkdir -p "$TMP/patches/test_mod" "$TMP/bin"
cp "$TMP/one.patch" "$TMP/patches/test_mod/one.patch"
printf 'one.patch\n' > "$TMP/patches/test_mod/patches.list"
printf '#!/bin/bash\nexit 1\n' > "$TMP/patches/test_mod/post-apply.sh"
printf '#!/bin/bash\necho restart >> "$PVE_MODs_ROOT/restarts"\n' > "$TMP/bin/systemctl"
chmod +x "$TMP/patches/test_mod/post-apply.sh" "$TMP/bin/systemctl"
export PVE_MODs_LOCK_FILE="$TMP/integration.lock" PVE_MODs_PATCHES_DIR="$TMP/patches"
export PVE_MODs_MAIN_CONF="$TMP/no-conf" PVE_MODs_CONFD_DIR="$TMP/no-conf-d"
export PATH="$TMP/bin:$PATH"
if bash "$REPO/src/scripts/apply-patches.sh" test_mod; then exit 1; fi
[[ $(cat "$PVE_MODs_ROOT/usr/share/demo/file") == one ]]
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["state"] == "error"' "$PVE_MODs_STATE_DIR/status/test_mod.json"
rm "$TMP/patches/test_mod/post-apply.sh"
bash "$REPO/src/scripts/apply-patches.sh" test_mod
before=$(wc -l < "$PVE_MODs_ROOT/restarts")
bash "$REPO/src/scripts/apply-patches.sh" test_mod
[[ $(wc -l < "$PVE_MODs_ROOT/restarts") == "$before" ]]
printf 'unknown\n' > "$PVE_MODs_ROOT/usr/share/demo/file"
if PVE_MODs_AUTOMATIC=1 bash "$REPO/src/scripts/apply-patches.sh" test_mod; then exit 1; fi
[[ $(wc -l < "$PVE_MODs_ROOT/restarts") == "$before" ]]
python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x["state"] == "blocked" and x["automatic"]' "$PVE_MODs_STATE_DIR/status/test_mod.json"
echo '[test] PASS: hook failure rollback, status, no-op activation and automatic hold without restart'
