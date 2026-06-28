# sunset-nag

A gentle but escalating nudge to get off the computer at sunset, built for
**GNOME on Wayland**.

At sunset, the screen warms up (via GNOME Night Light) starting at a mild
4000 K. Every 5 minutes, a desktop notification appears with two options:
**Snooze** ramps the temperature progressively warmer (toward 1800 K) and
pauses for a few minutes, or **It's an emergency** disables Night Light for
the rest of the night so you can keep working. Sunrise (or the daemon
stopping) restores your original Night Light settings.

No external packages: sunrise/sunset are computed locally in Python, and Night
Light is controlled via `gsettings`.

## How it works

- `sunset-nag` is a small Python script. On daemon start it persists the current
  Night Light state (temperature and enabled flag) so it can restore on exit.
- After sunset, the script enables Night Light, overrides the schedule to cover
  24 h (so GNOME applies the colour shift regardless of its own sunset calc),
  and starts the nag loop.
- The loop checks every few seconds. When `NAG_INTERVAL` minutes have passed, it
  sends a notification via `notify-send` with two action buttons:
  - **Snooze:** the temperature ramps `TEMP_STEP` K warmer (down to `END_TEMPERATURE`),
    then pauses for `SNOOZE_MINUTES` before the next nag.
  - **It's an emergency:** Night Light is disabled for the rest of the night and
    the daemon goes back to idle until the next sunset. Use sparingly.
- The daemon idles through the day and only activates between sunset and sunrise.
  After sunrise (or on SIGTERM/SIGINT), it restores the saved Night Light
  settings.

## Configure

Copy `.env.example` to `.env` and edit it. The daemon reloads this file every
loop, so changes take effect live:

```ini
ENABLED=true                 # set to false to disable without stopping the service
LAT=43.6532                  # north-positive (default: Toronto, ON)
LON=-79.3832                 # east-positive (negative = west)
SUN_ALTITUDE=-0.833          # standard; use -6 for civil twilight
START_TEMPERATURE=4000       # K applied at sunset (mild amber)
END_TEMPERATURE=1800         # K floor (deep lava-orange)
TEMP_STEP=200                # K ramp per Snooze
NAG_INTERVAL=5               # minutes between notifications
SNOOZE_MINUTES=5             # pause duration after clicking Snooze
```

## Install

```sh
./install.sh      # installs and starts the user service (re-runnable)
./sunset-nag status
```

`install.sh` migrates away from the older `auto-grayscale` service if present,
stops it cleanly, and installs `sunset-nag.service` as a systemd user unit.

## Manual control

```sh
./sunset-nag on       # force 1800K Night Light now (preview the extreme end)
./sunset-nag off      # restore saved settings and disable Night Light
./sunset-nag test     # ramp + fire a notification immediately (for testing)
./sunset-nag status   # location, sun times, current temperature, config
./sunset-nag times    # today's sunrise/sunset
```

While the service is running it enforces the nag ramp during sunset–sunrise, so
a manual `off` is overridden. Stop the service instead:
`systemctl --user stop sunset-nag.service`.

## Uninstall

```sh
./uninstall.sh
```

Stops the service, restores your saved Night Light settings, and removes the
systemd unit.

## Caveats

- This overrides GNOME Night Light's schedule while the daemon is active
  (setting it to a 24 h manual window). The original schedule, temperature,
  and enabled flag are saved on daemon start and restored on sunrise or clean
  shutdown, so uninstalling should leave your previous Night Light settings
  intact.
- **`notify-send` snooze behaviour** relies on GNOME Shell honouring `-A` action
  buttons. This works on stock GNOME (both X11 and Wayland), but extensions
  that replace the notification server (e.g. dunst on Wayland) may behave
  differently.
- The saved state file `.state.json` is written to the same directory as the
  script and is restored/deleted on every sunrise or clean shutdown. If the
  daemon crashes mid-nag, the file is restored on the next start.
- GNOME/Wayland only.
