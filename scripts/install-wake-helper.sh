#!/bin/bash
# Installs the scheduled-wake helper (see docs/scheduled-wake.md). Run it once
# after install.sh, from a checkout of this fork; it asks for your password.
#
#   scripts/install-wake-helper.sh
#
# It copies scripts/insomnia-wake.sh to /usr/local/libexec/insomnia-wake
# (root-owned, mode 755) and writes /etc/sudoers.d/insomnia-wake, which lets
# this user run only that helper without a password. The helper accepts only
# `set <days> <HH:MM:00>` and `clear`. A directory on the way that is not
# root-owned, or that others can write to, could let someone swap the
# helper, so the script refuses then and changes nothing.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

SUDO=/usr/bin/sudo
STAT=/usr/bin/stat
MKTEMP=/usr/bin/mktemp
RM=/bin/rm

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/insomnia-wake.sh"
DIR=/usr/local/libexec
HELPER="$DIR/insomnia-wake"
SUDOERS=/etc/sudoers.d/insomnia-wake

[[ -f "$SRC" ]] || { echo "insomnia-wake.sh not found next to this script; run it from a checkout of the fork." >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo "Run this as yourself, not with sudo: the sudoers rule names your account." >&2; exit 1; }

safe_dir() { # absent, or a root-owned directory nobody else can write
  local dir="$1" owner mode
  [[ -e "$dir" ]] || return 0
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  owner="$("$STAT" -f %u "$dir")"
  mode="$("$STAT" -f %Lp "$dir")"
  [[ "$owner" == 0 ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}
for d in /usr/local "$DIR"; do
  safe_dir "$d" || { echo "$d is not a root-owned directory closed to other users; not installing the helper. Nothing was changed." >&2; exit 1; }
done

TMP="$("$MKTEMP")"
trap '"$RM" -f "$TMP"' EXIT
cat > "$TMP" <<SUDO
# Installed by Insomnia install-wake-helper.sh: the scheduled-wake helper, nothing else.
$USER ALL=(root) NOPASSWD: $HELPER
SUDO

echo "==> Installing $HELPER and $SUDOERS (requires your password)"
"$SUDO" visudo -cf "$TMP" >/dev/null || { echo "sudoers rule failed validation; nothing was changed." >&2; exit 1; }
"$SUDO" install -d -o root -g wheel -m 0755 "$DIR"
"$SUDO" install -o root -g wheel -m 0755 "$SRC" "$HELPER"
"$SUDO" install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"

# The rule must work without a password, as the app will call it.
if "$SUDO" -k && "$SUDO" -n -l "$HELPER" >/dev/null 2>&1; then
  echo "Scheduled-wake helper installed. Turn it on in Insomnia › Settings › Scheduled wake."
else
  echo "The helper is installed but sudo -n does not allow it; check $SUDOERS." >&2
  exit 1
fi
