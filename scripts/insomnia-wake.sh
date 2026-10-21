#!/bin/bash
# insomnia-wake: sets or clears the daily wake for Insomnia's scheduled wake.
#
# install.sh installs this as /usr/local/libexec/insomnia-wake, owned by root
# and not writable by anyone else, and adds /etc/sudoers.d/insomnia-wake so
# the user can run it with sudo -n. It accepts exactly two forms and refuses
# everything else, so the sudoers rule grants no more than this:
#
#   insomnia-wake set <days> <HH:MM:00>   pmset repeat wakeorpoweron <days> <time>
#   insomnia-wake clear                   pmset repeat cancel
#
# <days> is one to seven distinct pmset weekday letters (MTWRFSU). macOS keeps
# one repeating wake, so set replaces any repeating wake already on file, and
# clear removes every repeating power event, not just Insomnia's.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PMSET=/usr/bin/pmset

usage() {
  echo "usage: insomnia-wake set <days MTWRFSU> <HH:MM:00> | insomnia-wake clear" >&2
  exit 64
}

case "${1:-}" in
  set)
    [[ $# -eq 3 ]] || usage
    days="$2"
    time="$3"
    [[ "$days" =~ ^[MTWRFSU]{1,7}$ ]] || { echo "insomnia-wake: days must be letters from MTWRFSU" >&2; exit 64; }
    # No letter twice.
    for (( i = 0; i < ${#days}; i++ )); do
      rest="${days:i+1}"
      [[ "$rest" != *"${days:i:1}"* ]] || { echo "insomnia-wake: a day appears twice" >&2; exit 64; }
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:00$ ]] || { echo "insomnia-wake: time must be HH:MM:00" >&2; exit 64; }
    exec "$PMSET" repeat wakeorpoweron "$days" "$time"
    ;;
  clear)
    [[ $# -eq 1 ]] || usage
    exec "$PMSET" repeat cancel
    ;;
  *)
    usage
    ;;
esac
