# Changelog

All notable changes to the Ricelin desktop installer are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
