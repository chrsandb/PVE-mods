#!/usr/bin/env bash
# Sourceable wizard fixtures without root, prompts, hardware or apt.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PVE_MODs_ROOT="$TMP/root" PVE_MODs_STATE_DIR="$TMP/state"
export PVE_MODs_MAIN_CONF="$TMP/config/main.conf" PVE_MODs_CONFD_DIR="$TMP/config/conf.d"
export PVE_MODs_TRANSACTION_HELPER="$REPO/src/scripts/patch-transaction.sh" PVE_MODs_CONFIGURE_D="$TMP/modules"
mkdir -p "$PVE_MODs_CONFD_DIR" "$PVE_MODs_CONFIGURE_D"
source "$REPO/src/scripts/pve-mods-configure"
MOD_NODE_INFO=0 MOD_NAG_SCREEN=0 PVE_TRIGGER_ENABLED=0
write_main_conf
printf 'initial module\n' > "$CONFD_DIR/node_info.conf"
node_info_write_conf() {
    # Module render runs before the save lock. Hardware/package prompts run
    # before this function, never under the lifecycle lock.
    flock -n "$PVE_MODs_STATE_DIR/lifecycle.lock" true
    printf 'new module\n' > "$NODE_INFO_CONF"
}
transaction_lock
wizard_snapshot
wizard_unlock
MOD_NODE_INFO=1
wizard_save node_info
grep -q 'node_info=1' "$CONF_FILE"
[[ $(cat "$CONFD_DIR/node_info.conf") == 'new module' ]]
flock -n "$PVE_MODs_STATE_DIR/lifecycle.lock" true
# Stale interactive data must not overwrite a newer CLI configuration.
transaction_lock
wizard_snapshot
wizard_unlock
printf 'concurrent edit\n' > "$CONF_FILE"
if wizard_save node_info; then exit 1; fi
[[ $(cat "$CONF_FILE") == 'concurrent edit' ]]
# An actual save failure restores files already written under the same lock.
write_main_conf
transaction_lock
wizard_snapshot
wizard_unlock
printf 'before save\n' > "$CONFD_DIR/node_info.conf"
transaction_lock
wizard_snapshot
wizard_unlock
eval "$(declare -f transaction_replace | sed '1s/transaction_replace/real_transaction_replace/')"
transaction_replace() {
    [[ "$2" != "$CONF_FILE" ]] || return 1
    real_transaction_replace "$@"
}
MOD_NODE_INFO=0
if wizard_save node_info; then exit 1; fi
grep -q 'node_info=1' "$CONF_FILE"
[[ $(cat "$CONFD_DIR/node_info.conf") == 'before save' ]]
flock -n "$PVE_MODs_STATE_DIR/lifecycle.lock" true
echo '[test] PASS: wizard locked snapshots/save, stale edit refusal, rollback and lock release before apply'
