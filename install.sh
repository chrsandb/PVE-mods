#!/usr/bin/env bash
# Versioned release installer. No checksum bypass; unattended installs require
# an independently trusted signing key. See tools/community-scripts/README.md.
set -euo pipefail

info() { printf '[pve-mods] %s\n' "$*"; }
err() { printf '[pve-mods] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: install.sh [--version TAG] [--repo OWNER/REPO] [--yes]
                  [--keyring FILE --signing-fingerprint FINGERPRINT]

Checksums are mandatory. --yes additionally requires a trusted keyring and
fingerprint to authenticate SHA256SUMS.asc. Provision the key independently.
Without --yes, installation requires confirmation on /dev/tty.
HELP
}

REPO=Meliox/PVE-mods
VERSION=latest
ASSUME_YES=0
KEYRING=""
FINGERPRINT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --yes) ASSUME_YES=1; shift ;;
        --version|--repo|--keyring|--signing-fingerprint)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || err "Missing value for $1"
            case "$1" in
                --version) VERSION="$2" ;;
                --repo) REPO="$2" ;;
                --keyring) KEYRING="$2" ;;
                --signing-fingerprint) FINGERPRINT="${2^^}" ;;
            esac
            shift 2 ;;
        *) err "Unknown option: $1" ;;
    esac
done
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || err 'Invalid repository'
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || err 'Invalid release tag'
if [[ -n "$KEYRING" || -n "$FINGERPRINT" ]]; then
    [[ -f "$KEYRING" && "$FINGERPRINT" =~ ^([A-F0-9]{40}|[A-F0-9]{64})$ ]] || err 'Supply both a keyring and full signing fingerprint'
elif [[ "$ASSUME_YES" == 1 ]]; then
    err 'Unattended installation requires --keyring and --signing-fingerprint'
fi
[[ $(id -u) == 0 ]] || err 'This installer must run as root'
for cmd in curl python3 dpkg dpkg-query dpkg-deb apt-get sha256sum; do
    command -v "$cmd" >/dev/null || err "Required command not found: $cmd"
done
[[ $(dpkg-query -W -f='${Status}' pve-manager 2>/dev/null) == 'install ok installed' ]] || err 'Installed pve-manager required'
if [[ -n "$KEYRING" ]]; then
    command -v gpgv >/dev/null || err 'gpgv required for signature verification'
    KEYRING=$(readlink -f "$KEYRING")
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 "$1" -o "$2"; }
API_URL="https://api.github.com/repos/$REPO/releases/latest"
[[ "$VERSION" == latest ]] || API_URL="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
fetch "$API_URL" "$TMP_DIR/release.json" || err 'Could not fetch release metadata'
# Parse JSON as data, require one all-architecture package and exact release URLs.
python3 - "$TMP_DIR/release.json" "$REPO" "$VERSION" > "$TMP_DIR/assets" <<'PY'
import json,re,sys
try:
    release=json.load(open(sys.argv[1]))
    tag=release['tag_name']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*',tag): raise ValueError('invalid tag')
    if sys.argv[3]!='latest' and tag!=sys.argv[3]: raise ValueError('tag mismatch')
    if release.get('draft') or release.get('prerelease'): raise ValueError('stable release required')
    assets=release['assets']
    packages=[a for a in assets if re.fullmatch(r'pve-mods_[A-Za-z0-9.+~_-]+_all\.deb',a['name'])]
    if len(packages)!=1: raise ValueError('expected exactly one package')
    def url(name):
        matches=[a for a in assets if a['name']==name]
        if len(matches)!=1: raise ValueError('missing or duplicate '+name)
        expected=f'https://github.com/{sys.argv[2]}/releases/download/{tag}/{name}'
        if matches[0]['browser_download_url']!=expected: raise ValueError('unexpected asset URL')
        return expected
    print(tag); print(packages[0]['name']); print(url(packages[0]['name'])); print(url('SHA256SUMS'))
    signatures=[a for a in assets if a['name']=='SHA256SUMS.asc']
    print(url('SHA256SUMS.asc') if signatures else '')
except (KeyError,ValueError,TypeError) as exc:
    print('Invalid release metadata: '+str(exc),file=sys.stderr);sys.exit(1)
PY
mapfile -t assets < "$TMP_DIR/assets"
TAG=${assets[0]}; DEB_NAME=${assets[1]}
fetch "${assets[2]}" "$TMP_DIR/$DEB_NAME" || err 'Package download failed'
fetch "${assets[3]}" "$TMP_DIR/SHA256SUMS" || err 'Checksum download failed'
if [[ -n "$KEYRING" ]]; then
    [[ -n "${assets[4]:-}" ]] || err 'Release has no checksum signature'
    fetch "${assets[4]}" "$TMP_DIR/SHA256SUMS.asc" || err 'Signature download failed'
    mkdir -m 700 "$TMP_DIR/gnupg"
    gpgv --homedir "$TMP_DIR/gnupg" --keyring "$KEYRING" --status-fd 1 \
        "$TMP_DIR/SHA256SUMS.asc" "$TMP_DIR/SHA256SUMS" > "$TMP_DIR/signature.status" || err 'Invalid release signature'
    # Match a full signing or primary-key fingerprint from a successful VALIDSIG.
    python3 - "$TMP_DIR/signature.status" "$FINGERPRINT" <<'PY'
import sys
valid=False
for line in open(sys.argv[1]):
    fields=line.split()
    if len(fields)>=3 and fields[:2]==['[GNUPG:]','VALIDSIG']:
        valid |= sys.argv[2] in (fields[2], fields[11] if len(fields)>11 else '')
if not valid: sys.exit('Signature does not match the trusted fingerprint')
PY
else
    info 'Checksum integrity only; no independently trusted signature supplied.'
fi
EXPECTED_SUM=$(python3 - "$TMP_DIR/SHA256SUMS" "$DEB_NAME" <<'PY'
import re,sys
matches=[]
for line in open(sys.argv[1]):
    match=re.fullmatch(r'([a-fA-F0-9]{64}) [ *](.+)\n?',line)
    # Older published manifests use ../file.deb; accept that exact spelling too.
    if match and match[2] in (sys.argv[2],'../'+sys.argv[2]): matches.append(match[1].lower())
if len(matches)!=1: sys.exit('Expected exactly one checksum for selected package')
print(matches[0])
PY
)
ACTUAL_SUM=$(sha256sum "$TMP_DIR/$DEB_NAME"); ACTUAL_SUM=${ACTUAL_SUM%% *}
[[ "$ACTUAL_SUM" == "$EXPECTED_SUM" ]] || err 'Package checksum mismatch; refusing installation'
[[ $(dpkg-deb -f "$TMP_DIR/$DEB_NAME" Package) == pve-mods ]] || err 'Unexpected package name'
[[ $(dpkg-deb -f "$TMP_DIR/$DEB_NAME" Architecture) == all ]] || err 'Unexpected package architecture'
PACKAGE_VERSION=$(dpkg-deb -f "$TMP_DIR/$DEB_NAME" Version)
if INSTALLED_VERSION=$(dpkg-query -W -f='${Version}' pve-mods 2>/dev/null); then
    dpkg --compare-versions "$PACKAGE_VERSION" ge "$INSTALLED_VERSION" || err 'Refusing to downgrade installed pve-mods'
fi
if [[ "$ASSUME_YES" != 1 ]]; then
    [[ -r /dev/tty ]] || err 'No terminal; use --yes with trusted signature options'
    read -r -p "Install pve-mods $TAG from $REPO? [y/N] " response </dev/tty
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]] || err 'Installation cancelled'
fi
info "Installing verified pve-mods $PACKAGE_VERSION"
# Use one dependency-resolving transaction rather than blind apt --fix-broken.
apt-get install -y -- "$TMP_DIR/$DEB_NAME"
info 'Installed. Run pve-mods-configure to select modules, or pve-mods status.'
