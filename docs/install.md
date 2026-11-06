# Install guide

Arch-family systems only. The installer is idempotent: completed steps can be
re-run safely.

## What it changes

- Installs SDDM, the Thunar stack, Zen Browser and NVIDIA tools.
- Clones or updates Ricelin in `~/.local/share/ricelin` and runs
  `install.sh --quickstart --sddm`.
- Installs and themes SDDM with the palette-driven torii/ricelin theme.
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
| Disk | 1 GiB free under `$HOME` minimum, 5 GiB recommended |
| Commands | `git`, `curl`, `python3`, `jq`, `systemctl`, `timeout` |
| GPU | Optional NVIDIA; fan and vibrance stages skip without one |

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
- After `ricelin update`, re-apply the customisation layer:

  ```sh
  ./install.sh --skip-base --yes
  ```

For failures, see [Troubleshooting](troubleshooting.md).
