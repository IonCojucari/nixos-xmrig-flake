#!/usr/bin/env bash
#
# Build the --extra-files tree for one rig: the XMRig API token, the Glances
# API password, and an optional console password for `admin`.
#
# Usage:  scripts/mk-secrets.sh <rig-name>
#
# Writes secrets/<rig-name>/, which is gitignored and stays on this machine.
# Hand it to nixos-anywhere with --extra-files; it is copied to the root of
# the new system before first boot.
#
# Why not put these in the flake: everything in /nix/store is world-readable,
# so a token or a password hash written into a .nix file is published to every
# local user on every rig, and baked into every build.

set -euo pipefail

RIG="${1:-}"
if [ -z "$RIG" ]; then
  echo "usage: $0 <rig-name>" >&2
  echo >&2
  echo "  e.g. $0 miner-a1b2c3d4   (matches a nixosConfigurations entry)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/secrets/$RIG"

if [ -e "$DIR" ]; then
  echo "ERROR: $DIR already exists." >&2
  echo "       Delete it if you really mean to issue new credentials — the" >&2
  echo "       token in there is the one Home Assistant is configured with." >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Directory modes are not cosmetic here.
#
# nixos-anywhere ships this tree as `tar -C <dir> -cpf- . | tar -C /mnt -xf-`,
# and GNU tar applies the archived mode to directories that already exist at
# the destination. A 0700 on this directory would therefore land on /mnt —
# i.e. the new system's / — and a 0700 on etc/ would land on /etc. Both are
# how you get an unbootable or unloggable machine.
#
# So: directories 0755 (what NixOS ships anyway), secrecy on the files only.
# --------------------------------------------------------------------------
# Checked before anything is written. `openssl passwd -6` is OpenSSL-only:
# LibreSSL -- which is what /usr/bin/openssl is on macOS, and this script is
# meant to run from any workstation -- rejects -5 and -6. Discovering that at
# the prompt would abort the run with two secrets already on disk.
if ! printf 'x' | openssl passwd -6 -stdin >/dev/null 2>&1; then
  echo "ERROR: this openssl cannot do 'passwd -6' (LibreSSL, most likely)." >&2
  echo "       Install OpenSSL, or run this on the rig itself." >&2
  exit 1
fi

# Anything that fails from here on must leave nothing behind. Half a tree is
# worse than none: the guard above would then refuse to regenerate it, while
# the token and the Glances password already exist on disk without ever having
# been printed -- credentials nobody has and nobody can reissue.
cleanup() {
  [ -n "${COMPLETE:-}" ] || rm -rf "$DIR"
}
trap cleanup EXIT

mkdir -p "$DIR/etc/xmrig" "$DIR/etc/glances"
chmod 755 "$DIR" "$DIR/etc" "$DIR/etc/xmrig" "$DIR/etc/glances"

# --------------------------------------------------------------------------
# XMRig HTTP API bearer token. One per rig: a shared token means one leak
# reaches the whole fleet, and Home Assistant needs a distinct secret per
# entity anyway.
# --------------------------------------------------------------------------
TOKEN="$(openssl rand -hex 24)"
printf '%s' "$TOKEN" > "$DIR/etc/xmrig/token"
chmod 600 "$DIR/etc/xmrig/token"

# --------------------------------------------------------------------------
# Glances HTTP Basic password, for the same reason and on the same terms.
#
# Glances' REST API used to answer every RFC1918 address with no credential,
# while the XMRig API next door required a bearer token — and Glances is the
# one that serves the process list, the logged-in users and the mounted
# filesystems. The service now refuses to start without this file.
#
# Plaintext on purpose: the rig hashes it into Glances' own salted format at
# service start (modules/monitoring.nix). Home Assistant needs the plaintext to
# send Basic auth, so a hash here would help nobody.
# --------------------------------------------------------------------------
GLANCES_PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$GLANCES_PASSWORD" > "$DIR/etc/glances/password"
chmod 600 "$DIR/etc/glances/password"

# --------------------------------------------------------------------------
# Console password for `admin`.
#
# admin is in wheel with passwordless sudo, so this is a root password in
# effect. Skipping it is a legitimate choice — it just means an SSH key is the
# only way in, with no console fallback if the network does not come up.
#
# `!` is the locked-account marker: a valid value for /etc/shadow that no
# password matches. Writing the file either way keeps
# `warning: password file does not exist` out of every rebuild.
# --------------------------------------------------------------------------
echo
echo "--------------------------------------------------------------"
echo " Console password for 'admin' on $RIG"
echo
echo " admin is in wheel with passwordless sudo. Leaving this empty"
echo " means SSH keys are the only way in, with no console fallback."
echo "--------------------------------------------------------------"

HASH='!'
while true; do
  read -rsp "Password for 'admin' (empty to skip): " pw1; echo
  if [ -z "$pw1" ]; then
    echo "  -> skipped; SSH key only."
    break
  fi
  read -rsp "Repeat it: " pw2; echo
  if [ "$pw1" = "$pw2" ]; then
    # Piped, never passed as an argument: argv is world-readable through
    # /proc/<pid>/cmdline for as long as the process runs.
    HASH="$(printf '%s' "$pw1" | openssl passwd -6 -stdin)"
    echo "  -> will be set at install time."
    break
  fi
  echo "  Passwords did not match. Try again." >&2
done
unset pw1 pw2

printf '%s\n' "$HASH" > "$DIR/etc/admin.passwd"
chmod 600 "$DIR/etc/admin.passwd"

COMPLETE=1

cat <<EOF

Wrote $DIR
  etc/xmrig/token       0600  XMRig API bearer token
  etc/glances/password  0600  Glances HTTP Basic password
  etc/admin.passwd      0600  $([ "$HASH" = '!' ] && echo 'locked (no console password)' || echo 'SHA-512 crypt hash')

Install with:

  nix run github:nix-community/nixos-anywhere -- \\
    --flake .#$RIG \\
    --target-host admin@<ip> \\
    --extra-files $DIR \\
    --no-substitute-on-destination

Home Assistant: add the rig in Settings -> Devices & Services -> XMRig and
paste both of these into the form (the integration stores them in the config
entry, there is no secrets.yaml key to add):

  Access token      $TOKEN
  Glances username  glances
  Glances password  $GLANCES_PASSWORD

EOF
