# auto-grayscale

Automatically **fade** the screen to grayscale around **sunset** and back to full
color around **sunrise**. Built for **GNOME on Wayland**.

It needs no external packages: sunrise/sunset are computed locally in Python, and
grayscale is produced with GNOME's accessibility magnifier (1× zoom, no visible
magnification) by varying its color saturation.

## How it works

- `auto-grayscale` is a small Python script. It maps the current time to a target
  **color saturation** (`1.0` = full color, `0.0` = grayscale), interpolated
  linearly across a transition window centered on sunset and sunrise.
- A **systemd user service** runs `auto-grayscale daemon`, which updates the
  saturation every few seconds while inside a transition window (a smooth fade)
  and sleeps until the next window otherwise. After suspend/resume it simply
  re-reads the clock and corrects.
- Saturation is set via `org.gnome.desktop.a11y.magnifier color-saturation`. The
  magnifier is only enabled while saturation is below `1.0`, and it is switched
  on/off at saturation ~`1.0`, so enabling/disabling it is itself imperceptible.

## Configure

Edit the top of the `auto-grayscale` script:

```python
LAT = 43.6532            # north-positive
LON = -79.3832           # east-positive (negative = west). Default: Toronto, ON.
SUN_ALTITUDE = -0.833    # standard sunset; use -6 for civil twilight
TRANSITION_MINUTES = 15  # length of the fade
ANCHOR = "center"        # "center" | "start" | "end" of the fade vs. the event
```

`ANCHOR` controls where the 15-minute fade sits relative to sunset/sunrise:

- `center` — 50% gray exactly at sunset (fade runs ±7.5 min around it)
- `start`  — full color at sunset, fully gray 15 min later
- `end`    — fully gray exactly at sunset (fade runs in the 15 min before)

## Install

```sh
./install.sh        # installs and starts the user service (re-runnable)
./auto-grayscale status
```

## Manual control

```sh
./auto-grayscale on       # force full grayscale now
./auto-grayscale off      # force full color now
./auto-grayscale apply    # set the correct saturation for right now, once
./auto-grayscale status   # sun times, fade windows, current state
./auto-grayscale times    # today's sunrise/sunset
```

While the service is running it enforces the scheduled saturation, so a manual
`on`/`off` is overridden within a few seconds. To take manual control, stop it:
`systemctl --user stop auto-grayscale.service`.

## Uninstall

```sh
./uninstall.sh
```

## Caveats

- This repurposes the GNOME **screen magnifier** to desaturate. If you also use
  the magnifier for actual zoom, this will conflict with it.
- GNOME/Wayland only. `gammastep`/`redshift` are not used: they change color
  *temperature* (warmth), not saturation, and cannot produce grayscale.
