# auto-grayscale

Automatically make the screen grayscale from **sunset to sunrise**, and return
it to full color during the day. Built for **GNOME on Wayland**.

It needs no external packages: sunrise/sunset are computed locally in Python,
and grayscale is produced with GNOME's accessibility magnifier (1× zoom, no
visible magnification, color saturation set to 0).

## How it works

- `auto-grayscale` is a small Python script. `auto-grayscale apply` computes
  whether it is currently between sunset and sunrise for your location and sets
  the screen to grayscale or color accordingly. It is idempotent.
- A **systemd user timer** runs `apply` every minute, so the switch happens
  within a minute of sunset/sunrise and corrects itself after suspend/resume.
- Grayscale toggles these GNOME settings:
  - `org.gnome.desktop.a11y.applications screen-magnifier-enabled`
  - `org.gnome.desktop.a11y.magnifier color-saturation` (`0.0` = grayscale)
  - plus `mag-factor 1.0`, `lens-mode false`, `screen-position full` so there is
    no actual zoom — only desaturation.

## Configure your location

Edit the top of the `auto-grayscale` script:

```python
LAT = 43.6532     # north-positive
LON = -79.3832    # east-positive (negative = west). This default is Toronto, ON.
SUN_ALTITUDE = -0.833   # standard sunset; use -6 for civil twilight
```

## Install

```sh
./install.sh
```

This installs and starts the user timer. To verify:

```sh
./auto-grayscale status        # today's sun times + current state
systemctl --user list-timers auto-grayscale.timer
```

## Manual control

```sh
./auto-grayscale on       # force grayscale now
./auto-grayscale off      # force full color now
./auto-grayscale times    # print today's sunrise/sunset
./auto-grayscale status   # full status
```

Note: while the timer is enabled it enforces the sunset/sunrise state every
minute, so a manual `on`/`off` will be overridden at the next tick. To take
manual control, stop the timer: `systemctl --user stop auto-grayscale.timer`.

## Uninstall

```sh
./uninstall.sh
```

## Caveats

- This repurposes the GNOME **screen magnifier** to desaturate. If you also use
  the magnifier for actual zoom, this will conflict with it.
- It applies to GNOME's Wayland session. `gammastep`/`redshift` are *not* used:
  they change color *temperature* (warmth), not saturation, and cannot produce
  grayscale. GNOME's built-in Night Light covers the warmth use case separately.
