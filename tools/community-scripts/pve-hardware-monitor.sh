#!/usr/bin/env bash
# Host-tool entry point for community-scripts/DevScripts tools/pve/.
# Copyright (c) 2026 PVE-mods contributors. MIT; see repository LICENSE.
# Owns no patch engine or APT hooks. The installed package owns all mutations.
set -euo pipefail

fail() { printf '[pve-mods] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: pve-hardware-monitor.sh [install|check|status]

install enables node_info only, checks compatibility, then applies the package's
patches if validation succeeds. Unknown states are held back. Existing nag_screen
configuration is left unchanged and causes a conflict refusal.

If the guarded package is not installed, first install a tested release, or set:
  var_pve_mods_repo              OWNER/REPO (default Meliox/PVE-mods)
  var_pve_mods_ref               full reviewed bootstrap commit SHA (required)
  var_pve_mods_version           stable release TAG (required)
  var_pve_mods_keyring           independently provisioned public keyring (required)
  var_pve_mods_fingerprint       trusted full signing fingerprint (required)
  var_pve_mods_auto              off|guarded (default off)
  var_pve_mods_confirm           yes to authorize unattended installation

A release containing the guarded CLI is required. Legacy releases are not
silently treated as compatible. Run on the PVE host, not inside an LXC guest.
HELP
}
[[ "${1:-}" != --help && "${1:-}" != -h ]] || { usage; exit 0; }
action=${1:-install}
[[ $# -le 1 && "$action" =~ ^(install|check|status)$ ]] || { usage >&2; exit 2; }
[[ $(id -u) == 0 ]] || fail 'Run this tool as root on the PVE host'
command -v pveversion >/dev/null || fail 'Proxmox VE host required'
if command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; then
    fail 'Container execution is unsupported; run on the host'
fi
if ! command -v pve-mods >/dev/null; then
    [[ "$action" == install ]] || fail 'Install a guarded pve-mods release first'
    repo=${var_pve_mods_repo:-Meliox/PVE-mods}
    ref=${var_pve_mods_ref:-}
    version=${var_pve_mods_version:-}
    keyring=${var_pve_mods_keyring:-}
    fingerprint=${var_pve_mods_fingerprint:-}
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid repository'
    [[ "$ref" =~ ^[a-fA-F0-9]{40}$ ]] || fail 'Set var_pve_mods_ref to a reviewed full bootstrap commit SHA'
    [[ -n "$version" && -f "$keyring" && -n "$fingerprint" ]] || fail 'Version and independent signature trust configuration required'
    if [[ ${var_pve_mods_confirm:-} != yes ]]; then
        [[ -r /dev/tty ]] || fail 'Set var_pve_mods_confirm=yes for unattended installation'
        read -r -p "Install pve-mods $version and enable node_info? [y/N] " answer </dev/tty
        [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || fail 'Cancelled'
    fi
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 \
        "https://raw.githubusercontent.com/$repo/$ref/install.sh" -o "$temporary/install.sh"
    bash "$temporary/install.sh" --repo "$repo" --version "$version" --yes \
        --keyring "$keyring" --signing-fingerprint "$fingerprint"
    command -v pve-mods >/dev/null || fail 'Selected release has no guarded CLI; module configuration was not changed'
fi
case "$action" in
    status) exec pve-mods status ;;
    check) exec pve-mods check --automatic node_info ;;
    install)
        auto=${var_pve_mods_auto:-off}
        [[ "$auto" == off || "$auto" == guarded ]] || fail 'var_pve_mods_auto must be off or guarded'
        if [[ ${var_pve_mods_confirm:-} != yes ]]; then
            [[ -r /dev/tty ]] || fail 'Set var_pve_mods_confirm=yes to authorize unattended configuration'
            read -r -p "Enable node_info with automatic mode $auto? [y/N] " answer </dev/tty
            [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || fail 'Cancelled'
        fi
        pve-mods configure --node-info --auto "$auto"
        if ! pve-mods check --automatic node_info; then
            printf '[pve-mods] Compatibility check blocked activation. Proxmox packages were not held.\n' >&2
            exit 1
        fi
        exec pve-mods apply --automatic node_info ;;
esac
