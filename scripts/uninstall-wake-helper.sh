#!/bin/bash
# Removes the scheduled-wake helper: clears the repeating wake first (macOS
# would otherwise keep waking the Mac), then deletes the helper and its
# sudoers rule. Asks for your password. Run it before or after uninstall.sh.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

SUDO=/usr/bin/sudo
HELPER=/usr/local/libexec/insomnia-wake
SUDOERS=/etc/sudoers.d/insomnia-wake

if [[ -x "$HELPER" ]]; then
  echo "==> Clearing the repeating wake"
  "$SUDO" "$HELPER" clear || echo "Could not clear it; check 'pmset -g sched' and run 'sudo pmset repeat cancel'." >&2
  "$SUDO" rm -f "$HELPER"
fi
if [[ -e "$SUDOERS" ]] || "$SUDO" test -e "$SUDOERS"; then
  "$SUDO" rm -f "$SUDOERS"
fi
echo "Scheduled-wake helper removed."
