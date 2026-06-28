---
name: gnome-night-light-control
description: Programmatically control GNOME Night Light on Wayland (schedule-gating gotchas, 24h-manual-schedule recipe, gsd-color management) plus daemon loop design pitfalls for sunset/sunrise-cycled nag daemons
source: auto-skill
extracted_at: '2026-06-28T17:13:00.796Z'
---

# GNOME Night Light Control (Wayland / gsettings)

## The Critical Gotchas (two of them)

1. **Schedule gating.** `night-light-enabled = true` is **only honoured when the current time falls inside the scheduled window**. Setting it alone outside the window is silently ignored — the screen does not change and nothing errors.

2. **Don't rely on `schedule-automatic = true` for scripted control.** We initially thought setting `automatic = true` (which lets GNOME compute sunset/sunrise from geolocation) was the fix. It works — *unless geolocation fails*. When it does, GNOME falls back to the sentinel coordinates `(91.0, 181.0)` and the schedule becomes **permanently locked on**: even `enabled = false` is ignored. We hit this in production and only a full `gsettings reset` of every `night-light-*` key plus a gsd-color restart broke the lock.

## The Reliable Recipe: 24h Manual Schedule

For any daemon that controls Night Light programmatically, **bypass the schedule check entirely** by widening the manual schedule to cover the full day:

```bash
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from 0.0
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to 23.99
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 4000
```

Now `enabled` is the real on/off switch and `temperature` is the real control knob. Use this pattern in any scripted Night Light daemon.

## Temperature Reference

| K    | Appearance            | Use case                            |
|------|-----------------------|-------------------------------------|
| 6500 | Neutral daylight      | GNOME default — baseline            |
| 4000 | Mild amber            | Barely noticeable, good starting pt |
| 2700 | Warm white            | GNOME's shipped idle default        |
| 1800 | Deep orange / lava    | Visibly unpleasant, deterrent       |
| 1000 | Extreme red           | Nearly unusable                     |

Lower = warmer = more orange. Values stored as `uint32`.

## Complete Enable / Ramp / Restore Sequence

```bash
# --- Save original settings BEFORE touching anything ---
orig_enabled=$(gsettings get org.gnome.settings-daemon.plugins.color night-light-enabled)
orig_temp=$(gsettings get org.gnome.settings-daemon.plugins.color night-light-temperature)
# orig_enabled will be "true" or "false"
# orig_temp will be "uint32 6500" etc. - keep it as-is, gsettings accepts it back

# --- Wide-schedule + start ---
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from 0.0
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to 23.99
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 4000

# --- Ramp down, e.g. every dismissed notification ---
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 3800
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 3600
# ... down to floor ...
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 1800

# --- Restore (on sunrise, SIGTERM, or manual off) ---
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature "$orig_temp"
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled "$orig_enabled"
```

Persist the original state to a JSON file on daemon start; read it back on restore. Delete the state file *after* successful restore, so a crash doesn't leave stale data.

## gsd-color Process Management

The `gsd-color` binary is the actual plugin that applies Night Light changes. It **must** be running for gsettings changes to take effect. Find it:

```bash
pidof /usr/lib/gsd-color      # or: pgrep -f gsd-color
```

### Rules

- **Restart with**: `/usr/lib/gsd-color &` (detach, suppress stdout/stderr).
- **Do not send `kill -HUP`** — gsd-color exits on SIGHUP and does **not** auto-respawn. You'll need to manually start it.
- After setting temperature, if nothing happens for a few seconds, gsd-color is almost certainly dead.
- `gnome-settings-daemon --replace` is the documented way to restart, but the binary is often not on `PATH` — run `/usr/lib/gsd-color` directly.

### Ensure-running helper (Python):
```python
import subprocess
try:
    subprocess.run(["pidof", "/usr/lib/gsd-color"], capture_output=True, check=True)
except subprocess.CalledProcessError:
    subprocess.Popen(
        ["/usr/lib/gsd-color"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
```

## Debugging Checklist

If Night Light reports "on" per gsettings but the screen looks unchanged:

1. **Is gsd-color running?**
   ```bash
   pidof /usr/lib/gsd-color || echo "DEAD - restart with /usr/lib/gsd-color &"
   ```
2. **Is the schedule covering "now"?**
   ```bash
   gsettings get org.gnome.settings-daemon.plugins.color night-light-schedule-automatic
   gsettings get org.gnome.settings-daemon.plugins.color night-light-schedule-from
   gsettings get org.gnome.settings-daemon.plugins.color night-light-schedule-to
   ```
   If `automatic` is `true`, check that coordinates are valid (not `(91.0, 181.0)`).
3. **Are coordinates garbage?** `gsettings get ... night-light-last-coordinates` — if you see `(91.0, 181.0)` or similar nonsense, geolocation failed and the automatic schedule is permanently locked. Fix: switch to the wide-manual-schedule recipe above.
4. **Hard reset (nuclear option):** `kill` gsd-color, `gsettings reset` all six `night-light-*` keys, then restart `/usr/lib/gsd-color`. We needed this to unlock Night Light after the coordinate-sentinel trap.

## Why Night Light over Grayscale (magnifier hack)

The earlier `auto-grayscale` approach repurposed the a11y screen magnifier at 1× zoom to set `color-saturation` between 1.0 and 0.0. That works on Wayland but:

- Conflicts with any user who actually uses the magnifier for zoom.
- Magnifier enable/disable can itself be visually jarring.
- GNOME Night Light is native compositor integration (via Mutter), doesn't conflict with any visible a11y feature, and shows up in Settings → Displays → Night Light.

## Pairing with Snoozeable Nag Notifications

For "nag me off the computer at sunset" style scripts, combine the ramp with `notify-send`'s action button:

```bash
notify-send -a "sunset-nag" -w -u normal \
  -A "snooze=Snooze 5 min" \
  "Time to wind down ☀️" \
  "Screen is 3800K. Dismiss to ramp warmer."
```

- `-w` (resident) keeps the notification pinned in GNOME Shell so the action stays clickable.
- `notify-send` exits with the **action key on stdout** when clicked — `snooze` here means user clicked Snooze; any other output (timeout, close button, etc.) means they dismissed.
- Works on **stock GNOME (Wayland + X11)**. Custom notification daemons (dunst, mako, swaync) may ignore the `-A` syntax or `-w`, so validate for your shell.

## Architecture Decision for a Sunset-Nag Daemon

- Use the **wide-manual-schedule** recipe, not `schedule-automatic = true` — it's the only approach with reliable on/off independent of geolocation.
- Save/restore Night Light state on daemon start/stop (to a file next to the script, gitignored) so the user's personal settings come back exactly. **Include schedule keys** (`schedule-automatic`, `schedule-from`, `schedule-to`) and store `from`/`to` as raw strings to avoid float drift.
- Treat gsd-color as a fragile process: check-and-restart on every ramp step, not just at daemon start.
- On SIGTERM/SIGINT, restore before exiting — the daemon should never leave Night Light in a "scripted" state.

## State Save/Restore Robustness

When a daemon plus manual CLI commands both mutate Night Light, the state file is a shared credential. These patterns prevent it from corrupting the user's real settings.

### Only snapshot original state once

```python
def _save_state():
    if state_path.is_file():
        return
    # write JSON with enabled, temperature, schedule-automatic, schedule-from, schedule-to
```

If you overwrite on every command, a daemon restart after a crash will save the ramped temperature as the "original" and restore it on the next shutdown.

### Store schedule boundaries as strings

gsettings returns `23.99`, but `float("23.99")` → `23.989999999999998`, and writing that back pollutes the user's settings. Keep `schedule-from` and `schedule-to` as raw strings:

```python
state = {
    "night-light-enabled": gsettings_bool(...),
    "night-light-temperature": gsettings_int(...),
    "night-light-schedule-automatic": gsettings_bool(...),
    "night-light-schedule-from": gsettings_string(...),   # "20.0"
    "night-light-schedule-to": gsettings_string(...),     # "22.0"
}
```

### Crash recovery at daemon startup

If a previous run left a state file, restore it first, then re-save:

```python
if state_path.is_file():
    _restore_state()
_save_state()
```

This prevents the daemon from treating a ramped screen as the user's original settings.

### Manual commands must not clobber the daemon's state file

`cmd_test()` should restore settings but keep the file in place so a concurrent daemon can still restore correctly on stop:

```python
def cmd_test():
    _save_state()
    # ... preview ...
    _restore_state(delete=False)   # restore but keep the file
```

`cmd_off()` is the owned shutdown path; it should restore, disable, and remove the file.

### `cmd_off()` should not hardcode a reset temperature

Do not `set_temperature(6500)` inside `cmd_off()` after restoring. That silently throws away a custom saved temperature. Restore the saved temperature and only disable Night Light:

```python
def cmd_off():
    _restore_state()               # restores temp, enabled, schedule
    _set_key("night-light-enabled", "false")
```

### Manual previews must start `gsd-color`

`cmd_on()` and `cmd_test()` won't visibly change the screen if `/usr/lib/gsd-color` isn't running. Call your `ensure_gsd_color()` helper right after enabling and setting the temperature.

## Daemon Loop Design Pitfalls (learned from code review)

These bugs were caught during review of a sunset→sunrise nag daemon. They're subtle, silent, and each one would cause the daemon to work for the first night and then break forever — so they're worth stating explicitly.

### 1. Snapshot the event boundary; don't recompute it every loop

The canonical bug: a daemon computes `(sunset, sunrise)` fresh on every loop iteration and checks `now >= sunrise` to detect "sunrise has passed". This **never fires**. A helper like `_compute_night_window(now)` returns *today's* sunrise while `now` is before it, but switches to *tomorrow's* sunrise the moment `now` passes today's — so the comparison target is **always in the future**.

**Fix:** capture the boundary in a state variable at the moment you *enter* the active period, and compare against that snapshot for the rest of the period:

```python
# On entering the nag window (sunset detected):
nag_start_sunset = sunset
nag_end_sunrise  = sunrise      # snapshot — DO NOT recompute for the exit check

# Every loop:
left = nag_start_sunset is not None and now >= nag_end_sunrise   # ✓ correct
# left = ... and now >= sunrise                                   # ✗ always False
```

The same logic applies to *entering* a window — use the freshly recomputed value there, but freeze it once you've transitioned into it.

### 2. Every mutating code path must save-state-before, restore-after

A daemon has multiple entry points: the long-running `daemon` command, plus manual `on` / `off` / `test` CLI subcommands. If `on` or `test` overwrite Night Light gsettings **without saving the user's original state first**, the eventual restore hardcodes a default (e.g. 6500K / off) and **silently destroys the user's personal Night Light config**.

**Rule:** every function that calls `_set_key("night-light-...", ...)` must be preceded by `_save_state()`, and every "done" path must call `_restore_state()`. The `daemon` command did this correctly; the manual commands initially did not.

```python
def cmd_test():
    load_env()
    _save_state()           # ← mandatory before any mutation
    configure_night_light_schedule()
    set_temperature(START_TEMPERATURE)
    # ... use it ...
    _restore_state()        # ← restore exactly what was saved
```

### 3. Idle sleep should scale to the next event, not tick constantly

A daemon that sleeps a fixed 5 s while idle all day generates ~17,280 needless wakeups/day. Compute seconds-until-next-sunset and cap the sleep:

```python
idle_sleep = min(60, max(5, int((sunset - now).total_seconds())))
time.sleep(idle_sleep)
```

This cuts idle wakeups ~12× while still catching config reloads and clock shifts within a minute.

### 4. Review checklist for any sunset/sunrise daemon

Before shipping, trace through these scenarios by hand (or in a test):

- [ ] **Night 1:** daemon starts before sunset → enters nag → ramps → sunrise detected → restores. Does it use a *snapshot* of sunrise for the exit check?
- [ ] **Night 2+:** after the first sunrise, does it correctly re-arm and enter the next sunset? (The snapshot-bug above causes a silent permanent stall here.)
- [ ] **Manual `on`/`test`:** are original settings saved *before* mutation? Does restore bring back the *exact* prior value, not a hardcoded default?
- [ ] **Crash mid-nag:** is the state file restored on next start, not left stale?
- [ ] **Idle CPU:** is the idle sleep bounded by time-to-next-event, not a tight fixed tick?
