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
- Adds a generated Ricelin skin for the Hermes Desktop default window. HUD and
  Quick Entry are disabled and their controls hidden.
- Renders the Hermes skin from the normal palette pass in `wallcolors.py`; no
  separate Hermes renderer or systemd watcher is installed.
- Embeds the Hermes renderer and desktop plugin directly in `install.sh` and
  removes the separate `integrations/` folder.
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
- Points Hermes Desktop's Chromium log files at `/dev/null` and keeps the
  previous logs beside them as `.pre-ricelin`; the rest of the Hermes log
  directory is untouched.
- Feeds the pill's agent line from Hermes and OpenCode as well as Claude Code,
  and renames the source from "Claude agent" to "AI agent" and the module from
  "Live activity" to "Activity".
- Adds a shared `peakguard.py` schedule plus the `peak-guard` CLI
  (`status`, `status --json`, `check`, `allow`, `deny`, `record`) for the
  weekday 01:00–04:00 and 06:00–10:00 UTC peak windows. The Chinese holiday
  calendar is available but off by default because OpenCode Go's documented
  pricing has no holiday exception.
- Adds a model router that keeps OpenCode and Hermes on DeepSeek V4.1 Flash:
  the free OpenCode model first, OpenCode Go only outside peak, and free again
  after the daily 00:00 UTC reset. It updates non-archived OpenCode sessions,
  adds a `provider.use` deny policy during peak, and moves the Hermes `model`
  block.
- Adds a Hermes `peak-guard` plugin whose `pre_llm_call` hook blocks paid Go
  during peak before any request, and whose `api_request_error` hook records a
  free-quota failure so the router can switch providers.
- Adds an OpenCode `peak-guard` plugin whose `model.request` hooks refuse paid
  Go during peak and refuse an exhausted free bucket during peak.
- Fixes the fish config on non-CachyOS systems by removing the missing CachyOS
  source and keeping `~/.local/bin` on PATH.
- Adds Thunar's "Open Terminal Here" action, opening ghostty in the selected
  folder.
- Removes Ricelin's upstream Discord special workspace.
- Removes rishot: checkout, config, launcher, desktop entry, Print binds and
  the Hyprland `require`.
- Removes every installed LightDM package, file and user, and disables the other
  known display managers before enabling SDDM.
- Creates the installer log directory with mode `0700` and the log file with
  mode `0600`.
- Writes helper scripts, systemd units and hot-reloaded configuration files
  atomically.
- Keeps `nvibrant-bin` installation in the vibrance stage instead of duplicating
  it in the package stage.

### Changed

- The Ricelin base stage now runs `install.sh --sddm` without `--quickstart`,
  so the upstream installer's own wizard asks for the profile, AUR helper,
  GRUB, fish and Brave. `--reinstall-base` still forwards `--reinstall`.

### Fixed

- `final_render` renders the active wallpaper with its saved per-wallpaper
  tone, so a normal installer render no longer clears the pinned Dark tone
  that stage 14 saves for `4.jpg`. The previous revision of the wallcolors
  patch is migrated in place.
- Only a real wallpaper switch (the pill or `wallpaper.sh` passing the key)
  updates the per-wallpaper tone store; plain installer renders leave it alone.
- The `wallcolors.py` hooks for SDDM, KDE, HyprToolkit, the portal scheme and
  the Hermes skin are replaced in place and guarded with an exact marker.
  Re-running the installer no longer moves them, grows blank lines or inserts a
  second `render_kde`/`render_hermes` definition.

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
