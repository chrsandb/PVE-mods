#!/usr/bin/env bash
# post-revert hook for the node_info mod.
# Runs after node_info patches are reverted (module disabled via
# pve-mods-configure, or package uninstalled). Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Strips any capability granted to intel_gpu_top by the
# configure wizard, so www-data loses CAP_PERFMON again on disable/removal.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

# An isolated test root must never change host executable capabilities.
[[ "${PVE_MODs_ROOT:-/}" == / ]] || exit 0
bin="$(command -v intel_gpu_top 2>/dev/null || true)"
[[ -n "$bin" ]] || exit 0

command -v setcap &>/dev/null || exit 0
command -v getcap &>/dev/null || exit 0

if getcap "$bin" 2>/dev/null | grep -q 'cap_perfmon'; then
    setcap -r "$bin" || exit 1
    echo "[pve-mods] Removed CAP_PERFMON from $bin"
fi

exit 0
