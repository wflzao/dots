# Install guide

Arch-family systems only. The installer is idempotent: completed steps can be
re-run safely.

## What it changes

- Installs SDDM, the Thunar stack, Zen Browser, OpenCode and NVIDIA tools.
- Installs Hermes Agent and builds Hermes Desktop through the official
  bootstrap with `--skip-setup`. The installer never prompts for a provider,
  model, API key, tools, gateway or telemetry; run `hermes setup` afterwards
  to configure them.
- Clones or updates Ricelin in `~/.local/share/ricelin` and runs
  `install.sh --quickstart --sddm`.
- Installs and themes SDDM with the palette-driven torii/ricelin theme.
- Copies the live SUPER+I choices that differ from stock: dynamic palette,
  Sunday week start, and a scheduled 3500 K night light from 19:00 to 06:00
  that fades in and out over 5 minutes.
- Generates a Ricelin skin for the Hermes Desktop default window and re-renders
  it when the wallpaper palette changes. HUD and Quick Entry are disabled and
  their controls hidden.
- Moves wallpapers from `~/Ricelin/wallpapers` to
  `~/.config/ricelin/wallpapers`, updates the saved paths, installs the bundled
  `1.png`, `2.jpg`, `3.png` and `4.jpg` set, and makes `4.jpg` the default with
  its matugen palette tone set to Dark; the other wallpapers stay on Auto.
- Pins each active monitor to its native resolution and highest refresh rate.
- Rebuilds the terminal's 16 ANSI colours with readable, conventional hues and
  a clear selection highlight; fixes KDE selection text and active colours.
- Makes clipboard history wheel scrolling continuous.
- Restores the executable bit on the wallpaper helpers, fixing SUPER+B.
- Removes **LightDM**, **Firefox** and **Dolphin**, including their user config.
- Makes Zen the default browser and Thunar the folder handler.
- Never stops the running graphical session. Reboot to land on SDDM.

## Requirements

| Item | Detail |
|---|---|
| Distro | Arch Linux, EndeavourOS, CachyOS or a close derivative |
| User | A normal desktop user, not root |
| Privilege | `sudo`, `doas` or `pkexec` |
| Network | `github.com` and the AUR reachable |
| Disk | 3 GiB free under `$HOME` minimum, 8 GiB recommended with Hermes Desktop |
| Commands | `git`, `curl`, `python3`, `jq`, `systemctl`, `timeout` |
| GPU | Optional NVIDIA; fan and vibrance stages skip without one |
| Hermes setup | Interactive wizard during install; choose your provider and key there |

On a minimal Arch install:

```sh
sudo pacman -S --needed git curl python jq systemd
```

## Clone

```sh
git clone https://github.com/wflzao/dots.git
cd dots
```

SSH:

```sh
git clone git@github.com:wflzao/dots.git
cd dots
```

## Install

```sh
./install.sh --dry-run    # preflight and plan; no changes
./install.sh              # interactive
./install.sh --yes        # non-interactive
```

`--dry-run` runs preflight and prints the plan. `sudo -v` is called once at the
start so the privileged phases do not prompt repeatedly.

## Options

| Option | Meaning |
|---|---|
| `-y`, `--yes` | Run without the confirmation prompt. |
| `--check`, `--status` | Report what is installed. Changes nothing. |
| `--dry-run` | Run preflight and print the plan. Changes nothing. |
| `--skip-base` | Never clone or run the upstream Ricelin installer. |
| `--reinstall-base` | Pass `--reinstall` to the upstream Ricelin installer. |
| `--no-nvidia` | Skip the NVIDIA fan and vibrance steps. |
| `-v`, `--verbose` | Stream every step to the terminal as well as the log. |
| `-h`, `--help` | Show help. |

`--skip-base` and `--reinstall-base` are mutually exclusive.

## Logs and exit codes

```text
~/.local/state/ricelin-installer/install-YYYYMMDD-HHMMSS.log
```

| Code | Phase |
|---:|---|
| 10 | Preflight |
| 20 | Network |
| 21 | Ricelin base |
| 22 | Packages |
| 23 | NVIDIA |
| 24 | SDDM package |
| 25 | SDDM theme |
| 26 | A customisation step |
| 27 | Verification |

`--check` runs the verification pass without changing state.

## After install

- Restart Zen once if it was already running.
- Reboot to land on SDDM.
- The bundled wallpapers are in `~/.config/ricelin/wallpapers`; `4.jpg` is the
  default with its tone pinned to Dark, while the other wallpapers use Auto.
  Change the wallpaper from the strip or SUPER+B, and the tone from
  SUPER+I > Appearance > Palette; the choice is remembered per wallpaper.
- Hermes is available as `hermes` and from the **Hermes** desktop launcher.
  The installer skips Hermes's setup wizard. Configure a provider, model and
  API key with `hermes setup` (or `hermes config set OPENCODE_GO_API_KEY <key>`
  for your provider) and restart the gateway with `hermes gateway restart`.
- After `ricelin update`, re-apply the customisation layer:

  ```sh
  ./install.sh --skip-base --yes
  ```

For failures, see [Troubleshooting](troubleshooting.md).
