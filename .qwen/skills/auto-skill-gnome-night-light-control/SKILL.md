---
name: gnome-night-light-control
description: Programmatically control GNOME Night Light on Wayland (schedule-gating gotchas, 24h-manual-schedule recipe, gsd-color management) plus daemon loop design pitfalls for sunset/sunrise-cycled nag daemons — zenity modal dialogs, per-interaction journald logging, collapsing snooze duration for escalation, and the dismiss-without-action fall-through bug
source: auto-skill
extracted_at: '2026-06-29T02:58:00.000Z'
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
- [ ] **Mid-evening ENABLED toggle:** does the `entered` branch prime `current_temp_k` outside the `if ENABLED:` guard?

### 5. Mid-evening `ENABLED` toggle must not corrupt the ramp start temp

The `entered` branch sets `current_temp_k = START_TEMPERATURE` inside the `if ENABLED:` guard. If the daemon was running with `ENABLED=false` through the sunset transition and the user flips it to `true` mid-evening, the daemon never re-fires `entered` (it's already in the window), so `current_temp_k` starts the ramp from whatever stale value it held.

**Fix:** always prime the ramp start temperature on entry, regardless of `ENABLED`:

```python
if entered:
    nag_start_sunset = sunset
    nag_end_sunrise = sunrise
    # Always prime, regardless of ENABLED:
    current_temp_k = START_TEMPERATURE
    if ENABLED:
        configure_night_light_schedule()
        set_temperature(current_temp_k)
```

Then when `ENABLED` flips on, the active-nag block picks up the already-primed correct starting temperature on the next loop.

## Multi-Action Notifications and the Emergency Pattern

### Two-button design: Snooze + Emergency

A nag daemon that only offers one escape hatch forces the user into an all-or-nothing choice. Splitting into two actions is cleaner:

- **Snooze** — ramp the temperature warmer, pause for `SNOOZE_MINUTES`
- **It's an emergency** — disable Night Light for the rest of the night (use sparingly)

Pass multiple `-A` flags to `notify-send` for each action:

```bash
notify-send -a "sunset-nag" -w -u normal \
  -A "snooze=Snooze 5 min" \
  -A "emergency=It's an emergency" \
  "Time to wind down ☀️" \
  "Screen is 3800K."
```

Return the action string (not a boolean) and handle each case:

```python
def send_nag_notification(temp_k):
    cmd = ["notify-send", "-a", "sunset-nag", "-w", "-u", "normal",
           "-A", "snooze=Snooze 5 min",
           "-A", "emergency=It's an emergency",
           "Time to wind down ☀️", f"Screen is {temp_k}K."]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return result.stdout.strip()   # "snooze", "emergency", or ""
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""

# In daemon loop:
action = send_nag_notification(current_temp_k)
if action == "snooze":
    snoozed_until = datetime.now() + timedelta(minutes=SNOOZE_MINUTES)
    current_temp_k = max(END_TEMPERATURE, current_temp_k - TEMP_STEP)
    set_temperature(current_temp_k)
elif action == "emergency":
    _restore_state()
    _set_key("night-light-enabled", "false")
    # daemon goes idle until next sunset — no more nags tonight
```

### Emergency semantics

The emergency action must **restore saved state**, **disable Night Light**, and **suppress nags for the rest of the night** — without re-enabling Night Light. The trap is in *how* you suppress.

Nulling `nag_start_sunset` to "exit the active period" is **wrong**. The `entered` transition is `nag_start_sunset is None and now_utc >= sunset`; after an emergency it is still night, so the very next loop iteration re-fires `entered`, which calls `configure_night_light_schedule()` and flips `night-light-enabled` back to `true` — defeating the emergency seconds later.

**Correct fix:** keep the nag window marked active (leave `nag_start_sunset` / `nag_end_sunrise` set) so `entered` cannot re-fire, and gate the active-nag branch with a `nag_disabled` flag that is cleared at sunrise:

```python
elif action == "emergency":
    _restore_state(delete=False)      # keep the backup for the rest of the run
    try:
        _set_key("night-light-enabled", "false")
    except subprocess.CalledProcessError:
        pass
    nag_disabled = True               # suppress nags until sunrise
    last_nag_time = None
    snoozed_until = None
    print("emergency -- Night Light disabled until sunrise", flush=True)
    time.sleep(DAEMON_SLEEP)
    continue
```

The active-nag branch must include `and not nag_disabled`:

```python
if ENABLED and nag_start_sunset is not None and \
   now_utc < nag_end_sunrise and not nag_disabled:
    ...
```

and the `left` (sunrise) transition clears `nag_disabled = False` alongside the other trackers, so the next sunset starts fresh.

**Why `delete=False`:** the daemon keeps running after an emergency and will mutate gsettings again (next sunset). Restoring without deleting keeps the original-settings backup on disk so a crash before sunrise can still restore; deleting it here leaves the rest of the run unbacked-up.

**Common bug (the other extreme):** restoring state + disabling Night Light but leaving every tracker non-`None` and adding no suppression flag. The active-nag branch is still gated on `nag_start_sunset is not None`, so the daemon keeps re-nagging every `NAG_INTERVAL` despite the emergency. The `nag_disabled` flag is the minimal addition that suppresses nags *without* triggering `entered` re-entry — do not try to avoid it by nulling `nag_start_sunset`.

## zenity Modal Dialogs as a Nag Alternative

`notify-send` produces a passive notification bubble that the user can easily ignore. For a nag tool whose entire purpose is to be hard to ignore, `zenity` modal dialogs are a stronger choice — they produce a real popup window that stays on top until dismissed. This is a drop-in replacement: the caller still gets back `"snooze"`, `"emergency"`, or `""`.

### zenity's return pattern differs from notify-send

This is the main gotcha when swapping. zenity splits the result across **both stdout and exit code**, unlike notify-send which puts everything on stdout:

| Outcome | stdout | exit code |
|---------|--------|-----------|
| OK button (`--ok-label`) clicked | empty | 0 |
| Extra button (`--extra-button`) clicked | the button's label | non-zero |
| Window closed (X) / timeout | empty | non-zero |

So you must check stdout content first, then fall back to exit code — checking only the exit code conflates "extra button" with "closed":

```python
def send_nag_notification(temp_k):
    cmd = [
        "zenity", "--warning",
        "--title", "sunset-nag",
        "--text", f"Time to wind down \u2600\ufe0f\nScreen is {temp_k}K.",
        "--ok-label", f"Snooze {SNOOZE_MINUTES} min",
        "--extra-button", "It\u2019s an emergency",
        "--width", "400",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    out = result.stdout.strip()
    if "emergency" in out.lower():
        return "emergency"
    if result.returncode == 0:
        return "snooze"
    return ""   # dismissed without a button
```

### Tradeoffs vs notify-send

| Aspect | notify-send | zenity |
|--------|-------------|--------|
| Visibility | Passive bubble, easy to ignore | Modal window, must dismiss |
| Auto-expiry | Yes (unless `-w` resident) | No — blocks until clicked |
| Action buttons | `-A key=Label`, stdout = key | `--ok-label` + `--extra-button`, stdout = label |
| Return parsing | stdout string only | stdout + exit code combined |
| Best for | Gentle reminders | Hard nags that must be acknowledged |

zenity has no silent-expiry path — the dialog blocks until the user interacts. For a nag tool this is a feature (harder to ignore); for a background daemon it means the loop is paused until dismissal, so the dialog stays on screen across `NAG_INTERVAL` boundaries rather than stacking up.

### POC test before integrating

Before swapping into a daemon, test zenity directly to verify the dialog renders and the return pattern matches expectations:

```bash
zenity --warning --title="sunset-nag" \
  --text="Time to wind down \u2600\ufe0f\nScreen is 4000K." \
  --ok-label="Snooze 5 min" \
  --extra-button="It's an emergency" \
  --width=400; echo "exit: $?"
```

Click each button and observe stdout + exit code. Only swap the daemon's `send_nag_notification` once the return mapping is confirmed.

## Logging Each Nag Interaction

A nag daemon running under systemd only logs stdout via journald (`journalctl --user -u <service> -f`). If the daemon only prints on sunset/sunrise transitions, you **cannot tell from the logs** whether nags are firing, whether the user is snoozing, or whether the dialog is silently erroring. Log every interaction:

```python
print(f"nag: {current_temp_k}K", flush=True)        # before sending the dialog
action = send_nag_notification(current_temp_k)
if action == "snooze":
    ...
    set_temperature(current_temp_k)
    print(f"snoozed: ramping to {current_temp_k}K, pausing {SNOOZE_MINUTES} min",
          flush=True)
elif action == "emergency":
    print("emergency -- Night Light disabled until sunrise", flush=True)
else:
    print("dismissed -- no action taken", flush=True)
```

This covers all four outcomes: nag fired, snoozed (with new temp), emergency, dismissed-without-a-button.

**`flush=True` is mandatory.** Python buffers stdout when not attached to a TTY (i.e., under systemd). Without `flush=True`, log lines appear in large bursts only when the buffer fills or the process exits — making live debugging via `journalctl -f` useless.

## Progressive Nag Escalation (snooze duration shrinks per snooze)

A fixed snooze is too gentle for a wind-down tool: a user who keeps hitting Snooze is signalling they need *more* pressure, not the same 5-minute reprieve over and over. Escalate by shrinking the **snooze duration itself** by 1 minute on each snooze, floored at 1 minute, so the nags become progressively more insistent:

- Snooze 1 → pause 5 min, next nag when pause ends
- Snooze 2 → pause 4 min
- Snooze 3 → pause 3 min
- Snooze 4 → pause 2 min
- Snooze 5+ → pause 1 min (floor)

### Collapse into one variable — do not use a separate "interval"

A common first attempt is to keep the snooze pause fixed (`SNOOZE_MINUTES`) and add a second `current_interval` that shrinks — so the nag fires every `current_interval` minutes *after* the snooze ends. This **does not behave as users expect**: the effective gap between nags is `snooze_pause + current_interval`, which starts longer than `SNOOZE_MINUTES` and shrinks unevenly. Worse, the snooze pause always exceeds the shrinking interval, so the interval comparison becomes dead code and the gap is always exactly `SNOOZE_MINUTES`.

**The fix:** drop the separate interval entirely. Make the snooze pause itself the thing that shrinks. The button label (`Snooze N min`) then matches reality: "Snooze N min" means "you get N minutes of peace," and `current_snooze` is the single source of truth.

```python
# Initialize with other per-period trackers:
current_snooze = SNOOZE_MINUTES

# Dialog label reflects reality:
cmd = ["zenity", ..., "--ok-label", f"Snooze {current_snooze} min", ...]

# On snooze: capture, decrement, set pause from the captured value:
if action == "snooze":
    snooze_count += 1
    snoozed_for = current_snooze                    # capture pre-decrement
    snoozed_until = datetime.now() + timedelta(minutes=current_snooze)
    current_snooze = max(1, current_snooze - 1)     # shrink for *next* snooze
    ...
    print(f"snoozed: ramping to {current_temp_k}K, pausing {snoozed_for} min",
          flush=True)
```

When the snooze expires, the daemon re-fires the nag immediately — no separate interval check needed. The gap between nags equals the snooze duration, which shrinks as intended.

### Why pair it with a snooze counter in the dialog

Escalation is more effective when the user can *see* they're being escalated. Showing the snooze count in the dialog body (only when > 0) gives feedback that the nag is tightening because of *their* choices:

```python
def send_nag_notification(temp_k, snooze_count=0, snooze_minutes=None):
    if snooze_minutes is None:
        snooze_minutes = SNOOZE_MINUTES
    msg = NAG_MESSAGES[min(snooze_count, len(NAG_MESSAGES) - 1)]
    text = msg
    if snooze_count > 0:
        text += f"\n\nYou've snoozed {snooze_count} time{'s' if snooze_count != 1 else ''}."
    cmd = [..., "--ok-label", f"Snooze {snooze_minutes} min", ...]
```

The count resets at sunrise (`snooze_count = 0`), so each night starts fresh with no carry-over guilt.

### Reset discipline

`current_snooze`, `snooze_count`, and all other per-period state must reset in **the same place** — the sunrise (`left`) transition, alongside `nag_disabled`, `last_nag_time`, etc. Forgetting any one of them means the escalation carries over into the next night, so a user who snoozed a lot last night starts tonight at 1-minute snoozes. Keep all per-period state reset together in one block.

## Dismiss-Without-Action Fall-Through Bug

When a nag dialog has three outcomes (snooze / emergency / dismiss-without-clicking-a-button), the `else` / dismiss branch must either set a pause or `continue` — otherwise the loop sleeps once and immediately re-fires the nag.

**The bug:** after a dismiss, the code falls through to the bottom of the active-nag block:

```python
if action == "snooze":
    snoozed_until = datetime.now() + timedelta(minutes=current_snooze)
    ...
elif action == "emergency":
    ...
    continue                     # ← emergency skips to next iteration
else:
    print("dismissed -- no action taken", flush=True)
    # ← NO continue, NO snoozed_until
time.sleep(DAEMON_SLEEP)         # ← dismiss hits this sleep
continue
```

On the next iteration `snoozed_until` is still `None` or expired, so the nag fires again immediately — producing an annoying ~5-second re-nag loop until a button is actually clicked.

**Two valid fixes:**

1. Treat dismiss as an implicit snooze (no ramp, but same pause):

   ```python
   else:
       snoozed_until = datetime.now() + timedelta(minutes=current_snooze)
       print("dismissed -- no action taken", flush=True)
   ```

2. Treat dismiss as "ignore, try again in a moment" with an explicit `continue` and skip the bottom sleep:

   ```python
   else:
       print("dismissed -- no action taken", flush=True)
       continue
   ```

Option 1 is usually what users want: dismissing the dialog should still buy them a breathing period, just not a warmer screen. Option 2 is appropriate only if dismiss should be punished aggressively.

### Audit checklist after removing a timing guard

Whenever you remove a rate-limiting condition (e.g. replacing `last_nag_time is None or elapsed >= interval * 60` with a snooze-only gate), audit the `else`/dismiss branch and any remaining assignments to the now-unused variable. If `last_nag_time` is written but never read anywhere, delete it — dead assignments confuse reviewers and mask the real state machine.
