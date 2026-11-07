# Changelog

All notable changes to the Ricelin desktop installer are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Installs OpenCode from the Arch `extra` repository.
- Installs Hermes Agent and builds Hermes Desktop through the official
  bootstrap and runs Hermes's own interactive setup wizard for the provider,
  model, API key, tools, gateway and telemetry.
- Adds a generated Ricelin skin for the Hermes Desktop default window. Its CSS
  is scoped away from the HUD and Quick Entry modes.
- Adds the four Ricelin wallpapers (`1.png`, `2.jpg`, `3.png`, `4.jpg`) to the
  repository and installs them into `~/.config/ricelin/wallpapers`; `4.jpg` is
  the default wallpaper.
- Pins only the default `4.jpg` wallpaper's dynamic matugen palette tone to
  Dark; the other wallpapers stay on Auto.
- Copies the live SUPER+I choices: dynamic palette, Sunday week start, and a
  scheduled 3500 K night light from 19:00 to 06:00.
- Fades the scheduled night light between 6500 K and the chosen temperature
  over 5 minutes instead of switching abruptly at 19:00 and 06:00.
- Moves wallpapers to `~/.config/ricelin/wallpapers`, migrates the saved paths
  and restores the executable bit on the wallpaper helpers so SUPER+B works.
- Pins each active monitor to its native resolution and highest refresh rate
  without hard-coding an output name.
- Rebuilds the terminal ANSI palette with readable, conventional colours and a
  clear selection highlight; fixes KDE selection text and active colours.
- Removes clipboard-history row snapping so wheel scrolling is continuous.
- Adds wallpaper-strip centring and the palette-aware lock-screen scrim.
- Caches matugen palette lookups per tone so one wallpaper render spawns
  matugen once per mode instead of once per caller, and skips rewriting
  `colors.json`/`hypr-colors.lua` when the palette has not changed.
- Enables `misc:vrr = 1` in Hyprland so a static desktop can idle below the
  panel's maximum refresh rate.
- Points Hermes Desktop's Chromium log files at `/dev/null`; the rest of the
  Hermes log directory is untouched.
- Masks unused GVFS phone-volume monitors and, when Flatpak is absent, the
  document/permission portals. `at-spi` stays enabled for accessibility.

### Planned

- Clean Arch/CachyOS/EndeavourOS VM test before the first tagged release.

## [1.0.0] - 2026-11-06

### Added

- Single self-contained `install.sh` covering preflight, the upstream Ricelin
  base, extra packages, SDDM/torii, the Ricelin customisation stages and
  verification.
- Interactive, `--yes`, `--check`, `--dry-run`, `--skip-base`,
  `--reinstall-base`, `--no-nvidia` and `--verbose` modes.
- Arch-family preflight: distro, privilege method, network, disk space,
  NVIDIA state, package and SDDM/theme checks, plus a Dolphin-demo warning.
- SDDM setup in the tested order: package, `/etc/sddm.conf.d`, upstream torii
  theme at `configs/sddm/themes/torii/install.sh`, then the palette-driven
  `ricelin` copy and the greeter Xsetup.
- Thunar stack, Zen Browser, `nvibrant-bin` and `hyprshot`, with AUR helper
  bootstrap through `yay`/`paru`.
- NVIDIA fan control at 75% through an event-driven root helper and sleep hook,
  with no polling timer.
- Digital vibrance at 75%, the corrected pill slider mapping and a login
  service that keeps the value applied.
- System handover to SDDM, Zen and Thunar, removing LightDM, Firefox and
  Dolphin and their user configuration.
- Diff-only Ricelin updater: only upstream-changed files are touched,
  non-overlapping local edits are three-way merged, conflicts are reported and
  the engine pins itself against self-rewrite.
- SDDM palette sync, greeter refresh rate and cursor setup, KDE/fish palette,
  portal colour-scheme sync, Zen wallpaper colours, one-tone terminal palette,
  Thunar theming, polkit palette, night-light cursor, wallpaper tone control,
  settings zoom, atomic theme writes, pretty menus, app glass, game-mode
  opacity, screenshot binds, UI tweaks and logout-to-SDDM.
- Logs under `~/.local/state/ricelin-installer/` and phase-specific exit codes.
- ShellCheck CI, tag-based release workflow, issue forms and a pull request
  template.
- MIT license.
