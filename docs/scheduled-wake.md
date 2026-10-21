# Scheduled wake

This fork adds a **Scheduled wake** next to timed sessions: macOS wakes the
Mac at a set time, even with the lid closed, and Insomnia keeps it awake
until scheduled jobs are done, then lets it sleep again.

## Settings

Settings › Scheduled wake:

- **Wake at** and **On** (days): the daily wake. macOS keeps it as a
  repeating power event (`pmset repeat wakeorpoweron`), so it fires even
  when Insomnia is not running.
- **Stay awake at most until**: the session's end time. A stuck job cannot
  keep the Mac awake past it.
- **Done when**: what ends the session early.
  - *A command succeeds*: run with `zsh -c` every check; exit 0 means done
    (60 s limit per run).
  - *A file changes after the wake*: done once the file's modification time
    is after this morning's wake.
  - *These processes have finished*: comma-separated names (`pgrep -x`).
    Ignored for the first 10 minutes, so jobs that have not started yet do
    not count as finished.
  - *Never*: hold until the latest end.
- **Check every** and **Then wait**: how often the check runs, and how long
  it must keep passing before the session ends.

**Test the check** runs it once, as if the wake was at midnight.

## What happens

1. At the wake time macOS powers the Mac on. Insomnia, which listens for the
   system's power-on message, takes a sleep assertion at once and starts a
   session that ends at the latest end. With the lid closed this is the
   same session as any other: `pmset disablesleep`, the lid-close actions,
   the battery and heat rules and the recovery agent all apply.
2. If a timed session is already running, it is extended to the latest end
   instead, and the done check never ends it early.
3. The check runs on its interval. Once it has passed for the grace period,
   Insomnia ends the session (`jobsDone`) and sleep is back to normal; with
   the lid closed the Mac goes back to sleep.
4. If the session ends any other way (you end it, a battery or heat rule),
   the run is over for the day.

If the Mac is already awake at the wake time, the minute tick starts the run.
If it wakes later inside the window (for example you open the lid at 06:00
and the wake did not fire), the run starts then.

Background maintenance wakes do not trigger a run: macOS does not send them
the power-on message.

## The helper

pmset needs root to set a repeating wake. After `install.sh`, run once from a
checkout of this fork:

```bash
scripts/install-wake-helper.sh
```

It copies `scripts/insomnia-wake.sh` to `/usr/local/libexec/insomnia-wake`
(root-owned, mode 755) and adds `/etc/sudoers.d/insomnia-wake`, which lets
your account run only that helper. The helper accepts exactly:

```text
insomnia-wake set <days MTWRFSU> <HH:MM:00>
insomnia-wake clear
```

and refuses everything else. The script refuses to install if `/usr/local`
or `/usr/local/libexec` is not root-owned or is writable by others.
`scripts/uninstall-wake-helper.sh` clears the wake and removes both files.
`install.sh` and `uninstall.sh` are unchanged from upstream.

macOS keeps one repeating wake: setting one replaces any repeating wake you
set yourself with `pmset repeat`, and `clear` (turning the feature off)
cancels every repeating power event.

## Limits

- A scheduled wake does not unlock the screen. Jobs that drive apps on
  screen still cannot run while the Mac is locked.
- With the lid closed the built-in microphone is disconnected in hardware,
  and the display stays off.
- Keep the Mac on power for long runs; the battery end floor still applies.
