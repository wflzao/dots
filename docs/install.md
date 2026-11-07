# Install guide

Arch-family systems only. The installer is idempotent: completed steps can be
re-run safely.

## What it changes

- Installs SDDM, the Thunar stack, Zen Browser, OpenCode and NVIDIA tools.
- Installs Hermes Agent and builds Hermes Desktop through the official
  bootstrap and runs Hermes's own interactive setup wizard. The provider,
  model, API key, tools, gateway and telemetry choices are made in that wizard;
  the installer does not preselect them.
- Clones or updates Ricelin in `~/.local/share/ricelin` and runs
  `install.sh --sddm`, so the upstream wizard chooses the profile, AUR helper,
  GRUB, fish and Brave options.
- Installs and themes SDDM with the palette-driven torii/ricelin theme.
- Copies the live SUPER+I choices that differ from stock: dynamic palette,
  Sunday week start, and a scheduled 3500 K night light from 19:00 to 06:00
  that fades in and out over 5 minutes.
- Generates a Ricelin skin for the Hermes Desktop default window from the
  normal palette pass, so it refreshes whenever `wallcolors.py` runs. HUD and
  Quick Entry are disabled and their controls hidden.
- Moves wallpapers from `~/Ricelin/wallpapers` to
  `~/.config/ricelin/wallpapers`, updates the saved paths, installs the bundled
  `1.png`, `2.jpg`, `3.png` and `4.jpg` set, and makes `4.jpg` the default with
  its matugen palette tone set to Dark; the other wallpapers stay on Auto.
- Pins each active monitor to its native resolution and highest refresh rate.
- Rebuilds the terminal's 16 ANSI colours with readable, conventional hues and
  a clear selection highlight; fixes KDE selection text and active colours.
- Caches matugen palette lookups per tone and skips rewriting palette files
  when the bytes have not changed.
- Enables `misc:vrr = 1` so a static desktop can idle below the panel's maximum
  refresh rate.
- Makes clipboard history wheel scrolling continuous.
- Feeds the pill's agent line from Claude Code, OpenCode and Hermes, and calls
  the source "AI agent" and the module "Activity".
- Routes DeepSeek V4.1 Flash between OpenCode's free model and OpenCode Go:
  free first, Go only outside the weekday 01:00–04:00 and 06:00–10:00 UTC peak
  windows, and free again after the daily 00:00 UTC reset. OpenCode sessions
  and the Hermes `model` block move with the route.
- Fixes the fish config on non-CachyOS systems: removes the missing CachyOS
  source line and keeps `~/.local/bin` on PATH.
- Adds Thunar's “Open Terminal Here” action, opening ghostty in the selected
  folder.
- Removes Ricelin's upstream Discord special workspace and removes rishot,
  its config, launcher, desktop entry, Print binds and Hyprland `require`.
- Restores the executable bit on the wallpaper helpers, fixing SUPER+B.
- Removes every installed **LightDM** package, file and user, disables the other
  known display managers, and removes **Firefox** and **Dolphin**, including
  their user config.
- Makes Zen the default browser and Thunar the folder handler.
- Never stops the running graphical session. Reboot to land on SDDM.

## Model routing

The stage installs:

- `~/.local/lib/peakguard.py` — the single schedule and free/paid route.
- `~/.local/bin/peak-guard` — `status`, `status --json`, `check`, `allow`,
  `deny`, `record`.
- `~/.local/bin/ricelin-model-route` + `ricelin-model-route.timer` — applies the
  route to both tools every minute.
- `~/.hermes/plugins/peak-guard/` — `pre_llm_call` hard block plus
  `api_request_error` free-quota tracking.
- `~/.config/opencode/plugins/peak-guard/` — `model.request` blocks for paid
  Go and for an exhausted free bucket during peak.

| Condition | OpenCode | Hermes |
|---|---|---|
| Free allowance available | `opencode/deepseek-v4.1-flash-free` | free custom endpoint |
| Free exhausted, off-peak | `opencode-go/deepseek-v4.1-flash` | `opencode-go` |
| Free exhausted, peak | free (Go denied) | free (Go blocked) |

Peak hours are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday**. The free
allowance is shared across free models, keyed by IP, and resets at **00:00
UTC**. Exhaustion is learned from OpenCode's log and from the
`peak-guard` Hermes plugin. The router updates non-archived OpenCode sessions,
the OpenCode default model and its `provider.use` policy, and the Hermes
`model` block. State is under `~/.local/state/ricelin/model-route/`.

A manual `/model` switch to paid Go during peak is refused by the Hermes
`pre_llm_call` hook and the OpenCode `model.request` hook, not just by the
default model. `peak-guard allow 30m` opens a deliberate expiring override;
`peak-guard deny` closes it. The Chinese public holiday calendar is available
but **off** by default because OpenCode Go's documented pricing has no holiday
exception; set `holidays=on` in `~/.config/ricelin/peakguard.conf` to follow
DeepSeek's own public pricing.

Hermes reaches the free endpoint with the same `OPENCODE_GO_API_KEY` from
`~/.hermes/.env` and an `opencode/2.2.5` user agent, because the free gateway
only serves OpenCode clients. If the key is missing, configure it during
Hermes setup or run the router with paid routing only.

Restart the Hermes gateway once after install so it loads the new `peak-guard`
plugin.

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
| `-y`, `--yes` | Run without the installer confirmation prompt. Hermes still runs its own interactive setup wizard. |
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

The log directory is mode `0700` and the log file is mode `0600`.

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
  The installer runs Hermes's own setup wizard; if you skipped the key there,
  add it later with `hermes config set OPENCODE_GO_API_KEY <key>` (or the key
  for the provider you chose) and restart the gateway with
  `hermes gateway restart`.
- After `ricelin update`, re-apply the customisation layer:

  ```sh
  ./install.sh --skip-base --yes
  ```

For failures, see [Troubleshooting](troubleshooting.md).
