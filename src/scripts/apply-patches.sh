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
MAIN_CONF="${PVE_MODs_MAIN_CONF:-/etc/pve-mods/pve-mods.conf}"
CONFD_DIR="${PVE_MODs_CONFD_DIR:-/etc/pve-mods/conf.d}"
PATCHES_DIR="${PVE_MODs_PATCHES_DIR:-/usr/lib/pve-mods/patches}"
# Storage for non-patch replaced files (e.g. nag-screen's minified proxmoxlib).
# Patched text files need no backups - `patch -R` reverts them.
STASH_DIR="${PVE_MODs_STASH_DIR:-/var/lib/pve-mods/backup}"

info() { echo "[pve-mods] $*"; }
warn() { echo "[pve-mods] WARNING: $*" >&2; }

# read_conf <file> <section> <key> [default]
# Prints one value from an INI file, or the default if absent.
read_conf() {
    local file="$1" section="$2" key="$3" default="${4:-0}"
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    local val
    val=$(awk -F= -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2; exit
            }
        }
    ' "$file")
    echo "${val:-$default}"
}

# List the keys of the [modules] section in the main config, one per line.
list_modules() {
    [[ -f "$MAIN_CONF" ]] || return 0
    awk -F= '
        /^\[/ { in_sec = ($0 == "[modules]") }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            print $1
        }
    ' "$MAIN_CONF"
}

CHANGED=false
FAILED=false

# Run a mod hook honouring the exit-code convention. Sets CHANGED / FAILED.
run_hook() {
    local hook="$1" mod_conf="$2"
    [[ -x "$hook" ]] || return 0
    STASH_DIR="$STASH_DIR" MOD_CONF="$mod_conf" CONFD_DIR="$CONFD_DIR" "$hook"
    local rc=$?
    case "$rc" in
        0)   ;;
        100) CHANGED=true ;;
        *)   warn "  hook $(basename "$hook") reported an error (exit $rc)"; FAILED=true; return 1 ;;
    esac
    return 0
}

# ── main ──────────────────────────────────────────────────────────────────────
if ! command -v patch >/dev/null 2>&1; then
    warn "'patch' command not found; cannot apply mods. Install the 'patch' package."
    exit 1
fi

mapfile -t _all_modules < <(list_modules)
_target_modules=("${@:-${_all_modules[@]}}")
for mod in "${_target_modules[@]}"; do
    [[ "$mod" =~ ^[a-zA-Z0-9_-]+$ ]] || { FAILED=true; continue; }
    TRANSACTION_REASON="manifest preflight failed"
    # When modules are explicitly named as args, the caller decides what to apply.
    # When running for all modules (no args from dpkg trigger), respect the config.
    if [[ $# -eq 0 ]]; then
        [[ "$(read_conf "$MAIN_CONF" modules "$mod" 0)" == "1" ]] || continue
    fi

    mod_dir="$PATCHES_DIR/$mod"
    manifest="$mod_dir/patches.list"
    mod_conf="$CONFD_DIR/$mod.conf"

    if [[ ! -f "$manifest" ]]; then
        warn "No patch manifest for enabled mod '$mod' ($manifest); skipping."
        transaction_status "$mod" blocked "patch manifest missing" || true
        FAILED=true
        continue
    fi

    info "Checking mod: $mod"

    # Build the list of active patch files (those whose condition is met).
    active=()
    preflight_ok=true
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments and surrounding whitespace; skip blanks.
        line="${line%%#*}"
        line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [[ -z "$line" ]] && continue

        # Format: <patch-file> [section.key=value]
        read -r patch_name _ <<< "$line"
        condition=""
        if [[ "$line" == *[[:space:]]* ]]; then
            condition="$(echo "${line#"$patch_name"}" | sed -E 's/^[[:space:]]+//')"
        fi

        # Evaluate optional condition against the mod's conf.d file.
        if [[ -n "$condition" ]]; then
            local_key="${condition%%=*}"
            want="${condition#*=}"
            sect="${local_key%%.*}"
            ckey="${local_key#*.}"
            if [[ "$(read_conf "$mod_conf" "$sect" "$ckey" 0)" != "$want" ]]; then
                info "  skip $patch_name (condition $condition not met)"
                continue
            fi
        fi

        patch_file="$mod_dir/$patch_name"
        if [[ ! -f "$patch_file" ]]; then
            warn "  patch file missing: $patch_file"
            preflight_ok=false
            continue
        fi
        active+=("$patch_file")
    done < "$manifest"

    # Build the complete ordered result away from the live tree. Unknown or
    # partially applied inputs are held unchanged, including existing hooks.
    if [[ "$preflight_ok" != true ]] || ! transaction_patchset apply "${active[@]}"; then
        warn "Mod '$mod': held unchanged; patch transaction failed."
        status=blocked
        [[ "${TRANSACTION_REASON:-}" == unresolved* ]] && status=recovery-required
        transaction_status "$mod" "$status" "${TRANSACTION_REASON:-manifest preflight failed}" || true
        FAILED=true
        continue
    fi
    prior_changed="$CHANGED"
    [[ "$TRANSACTION_CHANGED" == true ]] && CHANGED=true

    if [[ "${PVE_MODs_CHECK_ONLY:-0}" == 1 ]]; then continue; fi

    # Run the post-apply hook. If it errors, roll the mod back so it is never
    # left half-applied (matches the preflight atomicity contract).
    if ! run_hook "$mod_dir/post-apply.sh" "$mod_conf"; then
        warn "Mod '$mod': post-apply hook failed - reverting mod to clean state."
        run_hook "$mod_dir/post-revert.sh" "$mod_conf"
        if transaction_rollback; then
            CHANGED="$prior_changed"
        else
            warn "Recovery required: refusing to overwrite files changed since commit."
            transaction_status "$mod" recovery-required "post-apply failed; rollback conflicts require manual review" || true
        fi
        if [[ -z "${TX_DIR:-}" ]]; then
            transaction_status "$mod" error "post-apply hook failed; text changes restored" || true
        fi
        FAILED=true
        continue
    fi
    if ! transaction_finish; then
        transaction_status "$mod" recovery-required "could not persist transaction completion; inspect journal" || true
        FAILED=true
        continue
    fi
    transaction_status "$mod" active "patches staged and committed; runtime health not assessed" || FAILED=true

done

if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    if ! systemctl restart pveproxy; then
        warn "pveproxy restart failed"
        for mod in "${_target_modules[@]}"; do
            transaction_status "$mod" error "pveproxy restart failed; inspect service health" || true
        done
        FAILED=true
    fi
fi

[[ "$FAILED" == "true" ]] && exit 1
exit 0
