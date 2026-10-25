#!/usr/bin/env bash
# Shared lock and recoverable, hash-guarded text-file transactions.
# Hooks have separate side effects and are deliberately outside this journal.
transaction_status() {
    [[ "${PVE_MODs_CHECK_ONLY:-0}" != 1 ]] || return 0
    local mod="$1" status="$2" reason="$3" state tmp automatic=false
    [[ "$mod" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    state="${PVE_MODs_STATE_DIR:-${PVE_MODs_ROOT%/}/var/lib/pve-mods}/status"
    mkdir -p "$state" || return 1
    [[ "${PVE_MODs_AUTOMATIC:-0}" == 1 ]] && automatic=true
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"
    reason="${reason//$'\n'/ }"; reason="${reason//$'\t'/ }"
    tmp=$(mktemp "$state/.status.XXXXXX") || return 1
    printf '{"module":"%s","state":"%s","reason":"%s","timestamp":"%s","automatic":%s}\n' \
        "$mod" "$status" "$reason" "$(date -u +%FT%TZ)" "$automatic" > "$tmp"
    mv -fT "$tmp" "$state/$mod.json"
}
transaction_lock() {
    local root="${PVE_MODs_ROOT:-/}"
    local lock="${PVE_MODs_LOCK_FILE:-${PVE_MODs_STATE_DIR:-${root%/}/var/lib/pve-mods}/lifecycle.lock}"
    mkdir -p "$(dirname "$lock")" || return 1
    exec {PVE_MODs_LOCK_FD}>"$lock" || return 1
    flock -w "${PVE_MODs_LOCK_TIMEOUT:-30}" "$PVE_MODs_LOCK_FD" || {
        echo '[pve-mods] lifecycle busy; no changes made' >&2; return 1;
    }
}
transaction_target_safe() {
    local component checkroot="$PVE_MODs_ROOT"
    local -a components
    IFS=/ read -ra components <<< "$1"
    for component in "${components[@]}"; do
        checkroot="$checkroot/$component"
        [[ ! -L "$checkroot" ]] || return 1
    done
    [[ -f "$checkroot" ]]
}
transaction_hash() { sha256sum -- "$1" | cut -d' ' -f1; }
# Installed dpkg metadata is the trust anchor for automatic inputs. This proves
# local package identity/integrity, not compatibility with every package release.
transaction_vendor_identity() {
    local path="$1" db="${PVE_MODs_DPKG_DIR:-${PVE_MODs_ROOT%/}/var/lib/dpkg}" owner
    owner=$(dpkg-query --admindir="$db" -S "/$path" 2>/dev/null) || return 1
    [[ "$owner" == *": /$path" && "$owner" != *$'\n'* ]] || return 1
    TX_PACKAGE="${owner%: /$path}"
    [[ "$TX_PACKAGE" =~ ^[a-z0-9][a-z0-9+.:~-]*$ ]] || return 1
    TX_VERSION=$(dpkg-query --admindir="$db" -W -f='${Version}' "$TX_PACKAGE" 2>/dev/null) || return 1
    [[ -n "$TX_VERSION" ]] || return 1
    TX_VENDOR_MD5=$(awk -v path="$path" '$2 == path {print $1}' "$db/info/$TX_PACKAGE.md5sums" 2>/dev/null) || return 1
    [[ "$TX_VENDOR_MD5" =~ ^[a-f0-9]{32}$ ]]
}
transaction_known_input() {
    local path="$1" snapshot="$2" catalog="$3" sha
    transaction_vendor_identity "$path" || return 1
    if [[ "$(md5sum -- "$snapshot" | cut -d' ' -f1)" == "$TX_VENDOR_MD5" ]]; then
        return 0
    fi
    sha=$(transaction_hash "$snapshot")
    [[ -f "$catalog" ]] || return 1
    awk -F '\t' -v p="$path" -v pkg="$TX_PACKAGE" -v ver="$TX_VERSION" -v md5="$TX_VENDOR_MD5" -v sha="$sha" \
        '$1==p && $2==pkg && $3==ver && $4==md5 && $5==sha {found=1} END {exit !found}' "$catalog"
}
transaction_validator() {
    local validator="${PVE_MODs_VALIDATOR:-${PVE_MODs_ROOT%/}/etc/pve-mods/validator}"
    local current="$validator" mode
    [[ "$validator" == /* && -f "$validator" && -x "$validator" ]] || return 1
    # Validate every ancestor: a root-owned file under a writable directory
    # could otherwise be swapped by another user before privileged execution.
    while :; do
        [[ ! -L "$current" && "$(stat -c %u -- "$current")" == 0 ]] || return 1
        mode=$(stat -c %a -- "$current") || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
        [[ "$current" == / ]] && break
        current=$(dirname "$current")
    done
    timeout --kill-after=5s "${PVE_MODs_VALIDATOR_TIMEOUT:-30s}" "$validator" "$1" "$2"
}
transaction_record_outputs() {
    local catalog="${PVE_MODs_STATE_DIR:-${PVE_MODs_ROOT%/}/var/lib/pve-mods}/known-outputs.tsv"
    local tmp path before after
    [[ -f "$TX_DIR/verified" ]] || return 0
    tmp=$(mktemp "${catalog}.XXXXXX") || return 1
    [[ ! -f "$catalog" ]] || cat "$catalog" > "$tmp" || { rm -f "$tmp"; return 1; }
    while IFS=$'\t' read -r path before after; do
        [[ -n "$path" ]] || continue
        # Identity captured while staging, checked again after activation.
        if transaction_vendor_identity "$path"; then
            awk -F '\t' -v p="$path" -v pkg="$TX_PACKAGE" -v ver="$TX_VERSION" -v md5="$TX_VENDOR_MD5" \
                '$1==p && $2==pkg && $3==ver && $4==md5 {found=1} END {exit !found}' "$TX_DIR/verified" || continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$TX_PACKAGE" "$TX_VERSION" "$TX_VENDOR_MD5" "$after" >> "$tmp"
        fi
    done < "$TX_DIR/committed"
    sync -f "$tmp" && mv -fT "$tmp" "$catalog" && sync -f "$(dirname "$catalog")"
}
transaction_rollback() {
    [[ -n "${TX_DIR:-}" && -f "$TX_DIR/committed" ]] || return 0
    local path before after failed=false
    while IFS=$'\t' read -r path before after; do
        [[ -n "$path" ]] || continue
        if transaction_target_safe "$path" &&
           [[ "$(transaction_hash "$PVE_MODs_ROOT/$path")" == "$after" ]]; then
            transaction_replace "$TX_DIR/before/$path" "$PVE_MODs_ROOT/$path" || failed=true
        elif transaction_target_safe "$path" && [[ "$(transaction_hash "$PVE_MODs_ROOT/$path")" == "$before" ]]; then
            :
        else
            echo "[pve-mods] recovery conflict: $path; journal $TX_DIR" >&2
            failed=true
        fi
    done < "$TX_DIR/committed"
    [[ "$failed" == false ]] || return 1
    local parent
    parent=$(dirname "$TX_DIR")
    rm -rf -- "$TX_DIR" && sync -f "$parent" || return 1
    TX_DIR=''
}
transaction_replace() {
    local source="$1" target="$2" tmp
    tmp=$(mktemp "${target}.pve-mods.XXXXXX") || return 1
    if ! cp --preserve=all -- "$source" "$tmp" || ! sync -f "$tmp" || ! mv -fT -- "$tmp" "$target" || ! sync -f "$(dirname "$target")"; then
        rm -f -- "$tmp"; return 1
    fi
}
transaction_patchset() {
    local direction="$1"; shift
    TRANSACTION_CHANGED=false
    TRANSACTION_REASON="patch input, validation or write failure; see operation log"
    local state="${PVE_MODs_STATE_DIR:-${PVE_MODs_ROOT%/}/var/lib/pve-mods}/transactions"
    mkdir -p "$state" || return 1
    # A prior interrupted transaction must be reviewed; never restore an old
    # package's bytes automatically after an unrelated vendor upgrade.
    local old
    for old in "$state"/txn.*; do
        [[ -d "$old" ]] || continue
        TRANSACTION_REASON="unresolved transaction $old; manual review required"
        echo "[pve-mods] unresolved transaction $old; manual review required" >&2
        return 1
    done
    TX_DIR=$(mktemp -d "$state/txn.XXXXXX") || return 1
    mkdir -p "$TX_DIR/before" "$TX_DIR/after"
    local pf path component target checkroot
    local catalog="${PVE_MODs_STATE_DIR:-${PVE_MODs_ROOT%/}/var/lib/pve-mods}/known-outputs.tsv"
    local -a paths=() options=()
    [[ "$direction" == reverse ]] && options=(-R)
    # Only modifications of existing regular files are supported. Header paths
    # must agree and contain no whitespace, traversal or redirected parents.
    for pf in "$@"; do
        while read -r path; do
            [[ "$path" =~ ^[a-zA-Z0-9_./+-]+$ && "$path" != /* && "/$path/" != */../* && "/$path/" != */./* ]] || { TRANSACTION_REASON="unsafe or inconsistent patch target: $path"; rm -rf "$TX_DIR"; return 1; }
            target="$PVE_MODs_ROOT/$path"
            checkroot="$PVE_MODs_ROOT"
            IFS=/ read -ra components <<< "$path"
            for component in "${components[@]}"; do
                checkroot="$checkroot/$component"
                [[ ! -L "$checkroot" ]] || { TRANSACTION_REASON="symlink target or ancestor: $path"; rm -rf "$TX_DIR"; return 1; }
            done
            [[ -f "$target" ]] || { TRANSACTION_REASON="patch target is not an existing regular file: $path"; rm -rf "$TX_DIR"; return 1; }
            [[ -f "$TX_DIR/before/$path" ]] && continue
            paths+=("$path")
            mkdir -p "$TX_DIR/before/$(dirname "$path")" "$TX_DIR/after/$(dirname "$path")"
            cp -a -- "$target" "$TX_DIR/before/$path" && cp -a -- "$target" "$TX_DIR/after/$path" || { rm -rf "$TX_DIR"; return 1; }
            if transaction_known_input "$path" "$TX_DIR/before/$path" "$catalog"; then
                printf '%s\t%s\t%s\t%s\n' "$path" "$TX_PACKAGE" "$TX_VERSION" "$TX_VENDOR_MD5" >> "$TX_DIR/verified"
            elif [[ "${PVE_MODs_AUTOMATIC:-0}" == 1 ]]; then
                TRANSACTION_REASON="unrecognized package input: $path (vendor checksum or recorded output required)"
                echo "[pve-mods] automatic patch held: $TRANSACTION_REASON" >&2
                rm -rf "$TX_DIR"; return 1
            fi
        done < <(awk '/^--- / {old=$2} /^\+\+\+ / {if (old != "a/" substr($2,3) || $2 !~ /^b\//) print "INVALID"; else print substr($2,3)}' "$pf")
    done
    local -a patchset=("$@") inverse=()
    local complete=true index
    [[ "$direction" == apply ]] && inverse=(-R)
    cp -a "$TX_DIR/after" "$TX_DIR/probe" || { rm -rf "$TX_DIR"; return 1; }
    for ((index=${#patchset[@]}-1; index>=0; index--)); do
        if ! patch "${inverse[@]}" -p1 -F0 -f -s --no-backup-if-mismatch -d "$TX_DIR/probe" < "${patchset[$index]}" >/dev/null 2>&1; then
            complete=false; break
        fi
    done
    rm -rf "$TX_DIR/probe"
    for pf in "$@"; do
        [[ "$complete" == true ]] && break
        if patch "${options[@]}" -p1 -F0 -f --dry-run -s -d "$TX_DIR/after" < "$pf" >/dev/null 2>&1; then
            if ! patch "${options[@]}" -p1 -F0 -f -s --no-backup-if-mismatch -d "$TX_DIR/after" < "$pf"; then
                rm -rf "$TX_DIR"; return 1
            fi
        elif patch "${inverse[@]}" -p1 -F0 -f --dry-run -s -d "$TX_DIR/after" < "$pf" >/dev/null 2>&1; then
            : # Already in the requested state.
        else
            TRANSACTION_REASON="incompatible or partial patch: $(basename "$pf"); held unchanged"
            echo "[pve-mods] incompatible or partial patch: $pf; held unchanged" >&2
            if declare -F report_patch_failure >/dev/null; then
                if [[ "$direction" == reverse ]]; then report_patch_failure "$pf" reverse; else report_patch_failure "$pf"; fi
            fi
            rm -rf "$TX_DIR"; return 1
        fi
    done
    for path in "${paths[@]}"; do
        cmp -s "$TX_DIR/before/$path" "$TX_DIR/after/$path" && continue
        if [[ "$path" == *.js ]]; then
            if command -v node >/dev/null; then
                node --check "$TX_DIR/after/$path" >/dev/null || { TRANSACTION_REASON="JavaScript syntax validation failed: $path"; rm -rf "$TX_DIR"; return 1; }
            elif [[ "${PVE_MODs_AUTOMATIC:-0}" == 1 ]]; then
                TRANSACTION_REASON='node syntax validator unavailable'
                echo '[pve-mods] automatic patch held: node syntax validator unavailable' >&2
                rm -rf "$TX_DIR"; return 1
            fi
        fi
        if [[ "$path" == *.pm && "${PVE_MODs_AUTOMATIC:-0}" == 1 ]]; then
            # perl -c executes BEGIN blocks and needs matching PVE libraries.
            # A trusted host-specific validator must explicitly opt in.
            if ! transaction_validator "$TX_DIR/after" "$path"; then
                TRANSACTION_REASON='trusted /etc/pve-mods/validator unavailable or matching Perl validation failed'
                echo '[pve-mods] automatic patch held: matching Perl validation unavailable or failed' >&2
                rm -rf "$TX_DIR"; return 1
            fi
        fi
    done
    if [[ "${PVE_MODs_CHECK_ONLY:-0}" == 1 ]]; then
        echo '[pve-mods] staged patchset validated; check only, no activation'
        rm -rf "$TX_DIR"
        TX_DIR=''
        return 0
    fi
    # Flush snapshots before recording any write intent.
    sync -f "$TX_DIR" || { rm -rf "$TX_DIR"; return 1; }
    # Check the entire group before the first write, and each target again at
    # replacement. The lock coordinates our tools, not external package writers.
    for path in "${paths[@]}"; do
        if [[ "${PVE_MODs_AUTOMATIC:-0}" == 1 ]] && ! transaction_known_input "$path" "$TX_DIR/before/$path" "$catalog"; then
            TRANSACTION_REASON="package identity changed during staging: $path"
            rm -rf "$TX_DIR"; return 1
        fi
        if ! transaction_target_safe "$path" || [[ "$(transaction_hash "$PVE_MODs_ROOT/$path")" != "$(transaction_hash "$TX_DIR/before/$path")" ]]; then
            TRANSACTION_REASON="live input changed during staging: $path"
            rm -rf "$TX_DIR"; return 1
        fi
    done
    : > "$TX_DIR/committed"
    local before after
    for path in "${paths[@]}"; do
        before=$(transaction_hash "$TX_DIR/before/$path")
        after=$(transaction_hash "$TX_DIR/after/$path")
        [[ "$before" != "$after" ]] || continue
        if ! transaction_target_safe "$path" || [[ "$(transaction_hash "$PVE_MODs_ROOT/$path")" != "$before" ]]; then
            transaction_rollback; return 1
        fi
        # Journal intent before rename so interruption is detectable/recoverable.
        printf '%s\t%s\t%s\n' "$path" "$before" "$after" >> "$TX_DIR/committed"
        sync -f "$TX_DIR/committed" || { transaction_rollback; return 1; }
        if ! transaction_replace "$TX_DIR/after/$path" "$PVE_MODs_ROOT/$path"; then
            TRANSACTION_REASON="failed to replace or persist target: $path"
            transaction_rollback; return 1
        fi
        TRANSACTION_CHANGED=true
    done
    return 0
}
transaction_finish() {
    if [[ -n "${TX_DIR:-}" ]]; then
        transaction_record_outputs || return 1
        # Persist target renames before dropping the recovery journal.
        sync -f "$TX_DIR" || return 1
        rm -rf -- "$TX_DIR" || return 1
        sync -f "$(dirname "$TX_DIR")" || return 1
    fi
    TX_DIR=''
}
