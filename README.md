# backdrop

<p align="center">
  <img src="src/icon.svg" alt="backdrop" width="128"/><br/>
  <a href="https://github.com/aensley/backdrop/releases"><img src="https://img.shields.io/github/v/release/aensley/backdrop.svg?logo=gnubash&label=backdrop&logoColor=fff" alt="Version"/></a>
  <a href="https://github.com/aensley/backdrop/blob/main/LICENSE"><img src="https://img.shields.io/github/license/aensley/backdrop.svg" alt="License"/></a>
  <a href="https://github.com/aensley/backdrop/actions/workflows/test.yml"><img src="https://github.com/aensley/backdrop/actions/workflows/test.yml/badge.svg?branch=main"/></a>
  <a href="https://qlty.sh/gh/aensley/projects/backdrop"><img src="https://qlty.sh/gh/aensley/projects/backdrop/maintainability.svg" alt="Maintainability" /></a>
</p>

Set a new desktop wallpaper every day from various sources.

## What it does

backdrop fetches a daily image from one of several curated sources and sets it as your desktop wallpaper. It automatically picks the best display mode based on the image dimensions and your screen aspect ratio.

Run it manually or let a background timer handle it on a schedule.

## Quick Install

### Linux

```bash
curl -fsSL https://ensl.ee/backdrop | bash
```

### Windows

```powershell
iex (iwr 'https://ensl.ee/backdrop-w' -UseBasicParsing).Content
```

## Requirements

### Linux

- A supported desktop environment (see [Desktop Environments](#desktop-environments) below)
- `curl`, `python3` (standard on most distros)
- systemd (for the daily timer)

### Windows

- Windows 10 or later
- PowerShell 5.1 or later (built-in on Windows 10+)

## Desktop Environments

**Windows** uses `SystemParametersInfo` (user32.dll) to set the wallpaper, with fill mode stored in the registry under `HKCU:\Control Panel\Desktop`. No additional tools required.

**Linux** supports the following desktop environments:

| Desktop               | Method                        | Notes                                                                           |
| --------------------- | ----------------------------- | ------------------------------------------------------------------------------- |
| GNOME                 | `gsettings`                   |                                                                                 |
| KDE Plasma            | `qdbus6` or `qdbus`           | Sets the wallpaper and fill mode on all desktops                                |
| KDE Plasma (fallback) | `plasma-apply-wallpaperimage` | Used if qdbus is unavailable; requires Plasma 5.21+, fill mode not configurable |
| Xfce                  | `xfconf-query`                | Sets wallpaper and fill mode on all monitors; open Display settings once first  |
| Cinnamon              | `gsettings`                   |                                                                                 |
| MATE                  | `gsettings`                   |                                                                                 |
| LXQt                  | `pcmanfm-qt`                  |                                                                                 |
| COSMIC                | config file                   | Writes `~/.config/cosmic/com.system76.CosmicBackground/v1/all` (RON format)     |
| Other                 | `gsettings` or `qdbus`        | Tries gsettings first, then qdbus; set `XDG_CURRENT_DESKTOP` if detection fails |

## Installation

Use the [quick install script](#quick-install) or clone the repo and run the installer locally.

### Linux

```bash
git clone https://github.com/aensley/backdrop.git \
  && cd backdrop/src && ./install.sh
```

The installer:

1. Downloads (or uses local) `backdrop.sh`
2. Copies `backdrop` to `/usr/local/bin/`
3. Runs `backdrop enable`, which downloads and installs the systemd unit files and starts the daily timer

**Additional users:** with `backdrop` already installed system-wide, additional users can enable it for their own login with `backdrop enable`. This downloads the matching systemd unit files from GitHub and installs them into `~/.config/systemd/user/`.

### Windows

Clone the repo and run the installer from PowerShell:

```powershell
git clone https://github.com/aensley/backdrop.git
cd backdrop/src
.\install.ps1
```

The installer:

1. Copies `backdrop.psm1` and `backdrop.psd1` to the per-user PowerShell modules directory
2. Runs `backdrop enable`, which registers the scheduled task and applies the wallpaper immediately

The module is auto-imported in every new PowerShell session; no `$PROFILE` changes needed.

## Usage

```
backdrop <command>
```

| Command                         | Description                                                                        |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `status`                        | Show version, active source, last image, and image metadata (default)              |
| `update [--force]`              | Refresh wallpaper from the active source                                           |
| `set <source...> [--force]`     | Switch active source(s) and refresh now; use `all` for all sources                 |
| `set-time <HH:MM>`              | Set the daily run time (24-hour); restarts timer if active                         |
| `set-rotate-interval <minutes>` | Set rotation interval in minutes; 0 to disable                                     |
| `random [--force]`              | Refresh from a randomly chosen source (does not change active)                     |
| `enable`                        | Enable the background timer (Linux: systemd --user timer; Windows: Task Scheduler) |
| `disable`                       | Disable the background timer                                                       |
| `upgrade`                       | Check for and install the latest version from GitHub                               |
| `uninstall`                     | Remove backdrop from this system                                                   |
| `help`                          | Show help                                                                          |

## Sources

One, multiple, or all sources can be active simultaneously.

| Key      | Name                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| `bing`   | Bing Image of the Day<br>https://www.bing.com/                                                                |
| `earth`  | Earth.com Image of the Day<br>https://www.earth.com/gallery/images-of-the-day/                                |
| `apod`   | NASA Astronomy Picture of the Day<br>https://apod.nasa.gov/apod/                                              |
| `eo`     | NASA Earth Observatory Image of the Day<br>https://science.nasa.gov/earth/earth-observatory/image-of-the-day/ |
| `iotd`   | NASA Image of the Day _(default)_<br>https://www.nasa.gov/image-of-the-day/                                   |
| `natgeo` | National Geographic Photo of the Day<br>https://www.nationalgeographic.com/photo-of-the-day/                  |
| `wmc`    | Wikimedia Commons Picture of the Day<br>https://commons.wikimedia.org/wiki/Commons:Picture_of_the_day         |

Switch to a single source at any time:

```bash
backdrop set apod
```

Or enable multiple sources to rotate between them:

```bash
# Enable two or more specific sources
backdrop set iotd apod bing
```

To enable all sources:

```bash
# Enable all sources
backdrop set all
```

The wallpaper updates immediately when you run `set`, and the active source is reflected in `backdrop status`.

## Rotation

With multiple sources enabled, you can rotate between them at a fixed interval. When you set multiple sources, rotation is automatically enabled at 30 minutes:

```bash
# Rotate between three sources every 30 minutes (auto-set default)
backdrop set iotd apod bing

# Rotate through all sources
backdrop set all

# Change the rotation interval (e.g. every 2 hours)
backdrop set-rotate-interval 120

# Disable rotation and go back to a single source
backdrop set iotd
```

When rotation is active, the systemd timer fires at the rotation interval instead of the daily time set by `set-time`. The active source is determined by a time-slot calculation: `slot = (current_minute / interval) % num_sources`, so the same source is always shown for the full duration of its slot.

## Configuration

The config file is created on first run. You can edit it directly or use the `set` / `set-time` commands.

| Platform | Config file                 | Cached images              |
| -------- | --------------------------- | -------------------------- |
| Linux    | `~/.config/backdrop/config` | `~/.local/share/backdrop/` |
| Windows  | `%APPDATA%\backdrop\config` | `%LOCALAPPDATA%\backdrop\` |

| Key                   | Default              | Description                                                                                                      |
| --------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `source`              | `iotd`               | Active wallpaper source(s); space-separated list or `all`                                                        |
| `rotate_interval`     | `0`                  | Minutes between source rotations; 0 to disable (uses `timer_time` for daily updates instead)                     |
| `screen_aspect_ratio` | `1.7778`             | Fallback aspect ratio if auto-detect fails (16:9=1.7778, 16:10=1.6, 21:9=2.3333, 4:3=1.3333)                     |
| `zoom_min_coverage`   | `0.55`               | Crop tolerance: if zoom-filling would keep less than this fraction of the image visible, use scaled mode instead |
| `user_agent`          | `backdrop/1.0 (...)` | HTTP User-Agent sent with all requests                                                                           |
| `timer_time`          | `08:00`              | Time of day to run the daily update (24-hour HH:MM); only applies when `rotate_interval = 0`                     |

## Uninstallation

```
backdrop uninstall
```

To also remove your config and cached wallpapers:

```
backdrop uninstall --purge
```

On Linux this removes the script from `/usr/local/bin` and disables the systemd timer. On Windows it unregisters the scheduled task and removes the PowerShell module.
