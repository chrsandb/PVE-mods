#!/usr/bin/env bash
# Manifest-driven text patches are staged sequentially and committed using
# patch-transaction.sh. Unknown inputs are held unchanged. Module hooks have
# their own side effects and are not covered by the text-file journal.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/patch-diagnostics.sh"
source "$SCRIPT_DIR/patch-transaction.sh"
transaction_lock || exit 1

# Root paths (overridable via environment, mainly for testing).
PVE_MODs_ROOT="${PVE_MODs_ROOT:-/}"
CONFD_DIR="${PVE_MODs_CONFD_DIR:-/etc/pve-mods/conf.d}"
PATCHES_DIR="${PVE_MODs_PATCHES_DIR:-/usr/lib/pve-mods/patches}"
# Storage for non-patch replaced files (e.g. nag-screen's minified proxmoxlib).
STASH_DIR="${PVE_MODs_STASH_DIR:-/var/lib/pve-mods/backup}"

info() { echo "[pve-mods] $*"; }
warn() { echo "[pve-mods] WARNING: $*" >&2; }

# ── main ──────────────────────────────────────────────────────────────────────
if ! command -v patch >/dev/null 2>&1; then
    warn "'patch' command not found; cannot revert mods."
    exit 0
fi

[[ -d "$PATCHES_DIR" ]] || exit 0

CHANGED=false
FAILED=false

mapfile -t _all_modules < <(for d in "$PATCHES_DIR"/*/; do [[ -d "$d" ]] && basename "$d"; done)
_target_modules=("${@:-${_all_modules[@]}}")
for mod in "${_target_modules[@]}"; do
    [[ "$mod" =~ ^[a-zA-Z0-9_-]+$ ]] || { FAILED=true; continue; }
    mod_dir="$PATCHES_DIR/$mod/"
    [[ -d "$mod_dir" ]] || continue
    manifest="$mod_dir/patches.list"
    mod_conf="$CONFD_DIR/$mod.conf"

    [[ -f "$manifest" ]] || continue
    info "Reverting mod: $mod"

    # Collect patch names (ignore conditions and comments), then reverse order.
    mapfile -t patches < <(
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            [[ -z "$line" ]] && continue
            read -r patch_name _ <<< "$line"
            echo "$patch_name"
        done < "$manifest"
    )

    ordered=()
    for (( i=${#patches[@]}-1 ; i>=0 ; i-- )); do
        patch_file="$mod_dir/${patches[$i]}"
        [[ -f "$patch_file" ]] || { FAILED=true; continue; }
        ordered+=("$patch_file")
    done
    if ! transaction_patchset reverse "${ordered[@]}"; then
        transaction_status "$mod" blocked "${TRANSACTION_REASON:-revert failed}" || true
        FAILED=true
        continue
    fi
    [[ "$TRANSACTION_CHANGED" == true ]] && CHANGED=true
    # Run the post-revert hook first (undo non-patch actions such as symlinks).
    hook="$mod_dir/post-revert.sh"
    if [[ -x "$hook" ]]; then
        info "Running post-revert hook for $mod"
        STASH_DIR="$STASH_DIR" MOD_CONF="$mod_conf" CONFD_DIR="$CONFD_DIR" "$hook"
        rc=$?
        case "$rc" in
            0)   ;;
            100) CHANGED=true ;;
            *)   warn "post-revert hook for $mod reported an error (exit $rc)"; FAILED=true ;;
        esac
    fi


    transaction_status "$mod" inactive "patches reverted; hook or service failures may require inspection" || true
    transaction_finish

done

if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    if ! systemctl restart pveproxy; then FAILED=true; fi
fi

[[ "$FAILED" == "false" ]] || exit 1
exit 0
