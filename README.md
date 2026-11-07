# dots

Self-contained installer for a [Ricelin](https://github.com/Gakuseei/Ricelin)
desktop on Arch-family systems. One Bash file and no external stage files. It
installs the helper scripts and user/system units the desktop needs.

## Requirements

- Arch Linux, EndeavourOS, CachyOS or a close derivative
- Non-root desktop user with `sudo`, `doas` or `pkexec`
- `git`, `curl`, `python3`, `jq`, `systemctl`, `timeout`
- Network access to `github.com` and the AUR
- 3 GiB free under `$HOME` (8 GiB recommended with Hermes Desktop)
- NVIDIA optional; fan and vibrance stages are skipped without a working driver

## Usage

```sh
git clone https://github.com/wflzao/dots.git
cd dots
```

Preview, then install:

```sh
./install.sh --dry-run    # preflight and plan; no changes
./install.sh              # interactive
./install.sh --yes        # non-interactive
```

| Option | Description |
|---|---|
| `-y`, `--yes` | Skip the installer confirmation prompt (Hermes still runs its own interactive setup wizard) |
| `--check`, `--status` | Report installed state; no changes |
| `--dry-run` | Run preflight and print the plan; no changes |
| `--skip-base` | Do not clone or run the upstream installer |
| `--reinstall-base` | Pass `--reinstall` to the upstream installer |
| `--no-nvidia` | Skip fan and vibrance stages |
| `-v`, `--verbose` | Stream step output to the terminal |
| `-h`, `--help` | Show usage |

`--skip-base` and `--reinstall-base` are mutually exclusive.

## Behavior

The installer runs six phases:

1. **Preflight** — distro, privilege method, network, disk, NVIDIA, packages,
   SDDM/theme paths, Dolphin-demo check.
2. **Base** — clone or update `Gakuseei/Ricelin` in `~/.local/share/ricelin`
   and run `install.sh --quickstart --sddm`. Skipped when
   `~/.config/hypr/.ricelin-managed` exists, unless `--reinstall-base`.
3. **Packages** — SDDM, Thunar stack, greeter tools, `nvidia-settings`, Zen
   and OpenCode; bootstraps `yay`/`paru` when needed. `nvibrant-bin` is
   installed by the vibrance stage. Hermes Agent and Hermes Desktop are
   installed from the official bootstrap with their own interactive setup
   wizard: the provider, model, API key, tools, gateway and telemetry choices
   are yours. The installer does not preselect or configure them.
4. **SDDM** — installs the package, creates `/etc/sddm.conf.d`, runs the
   upstream theme installer at `configs/sddm/themes/torii/install.sh`.
5. **Customisation** — system handover, diff-only updater, SDDM palette and
   greeter, fans/vibrance, the live SUPER+I choices (dynamic palette, Sunday
   week start, scheduled 3500 K night light with a 5-minute fade), the bundled
   wallpaper set (`1.png`, `2.jpg`, `3.png`, `4.jpg`) in
   `~/.config/ricelin/wallpapers` with
   `4.jpg` as the default with its matugen tone pinned to Dark while the
   others stay on Auto, native resolution at the highest refresh, the generated
   Ricelin skin for the Hermes Desktop default window, the Claude Code /
   OpenCode / Hermes activity line in the pill, DeepSeek V4.1 Flash routing
   between OpenCode's free model and OpenCode Go, KDE/fish and terminal
   palette, the fish config (no CachyOS source, `~/.local/bin` on PATH), the
   Thunar “Open Terminal Here” action (ghostty), portal colour-scheme sync,
   Zen colours, Thunar, polkit, night-light cursor, wallpaper tone,
   wallpaper-strip centring, lock-screen palette, settings zoom, atomic theme
   writes, the matugen render cache, menus, app glass, adaptive refresh (VRR),
   game-mode opacity, screenshots, UI tweaks, removal of the upstream Discord
   special workspace and rishot, smooth clipboard scrolling, logout.
6. **Verification** — final palette render and blocking-item report.

The installer removes every **LightDM** package and its files/user, removes
**Firefox** and **Dolphin** including their user configuration, disables the
other known display managers, and switches to SDDM, Zen and Thunar. It never
stops the running graphical session. A reboot is required to land on SDDM.

New installs start on `4.jpg` with its dynamic matugen palette forced to
**Dark**. Other wallpapers stay on **Auto** and derive light or dark from the
image. Change the wallpaper from the strip or SUPER+B, and the tone from
SUPER+I > Appearance > Palette; the choice is remembered per wallpaper.

## Model routing

`stage_model_route` installs one schedule module, a `peak-guard` CLI, a Hermes
plugin, an OpenCode plugin and a small user timer. Together they keep both
agents on DeepSeek V4.1 Flash while avoiding the paid Go peak price:

- **Single schedule.** `~/.local/lib/peakguard.py` defines the weekday
  **01:00–04:00 and 06:00–10:00 UTC** peak windows. Go's documented pricing has
  no holiday exception, so the Chinese holiday calendar is shipped but
  **off** by default (`~/.config/ricelin/peakguard.conf`).
- **Free first.** The free OpenCode model
  (`opencode/deepseek-v4.1-flash-free`) is used whenever its daily allowance is
  available. The allowance is shared by all free models, keyed by IP, and
  resets at **00:00 UTC**.
- **Go outside peak.** When the free allowance is exhausted, the router uses
  `opencode-go/deepseek-v4.1-flash` until the next UTC reset.
- **Hard block during peak.** The Hermes plugin returns
  `{"action": "block"}` from `pre_llm_call` — before any inference request — if
  paid Go is selected during peak or the free bucket is exhausted. OpenCode’s
  `model.request` hooks do the same for `opencode-go` and `opencode`, and the
  config also denies `opencode-go` with a `provider.use` policy. A manual
  `/model` switch cannot spend Go credit at peak.
- **Automatic recovery.** The router watches OpenCode’s log and the Hermes
  `api_request_error` hook for the free-quota error, updates the non-archived
  OpenCode sessions, rewrites the OpenCode default and the Hermes `model`
  block, and reloads OpenCode. It runs every minute and is idempotent.
- **Escape hatch.** `peak-guard allow 30m` opens an expiring override for a
  deliberate peak-rate request; `peak-guard deny` closes it. `peak-guard
  status` shows the current route, window and reset.

The free gateway accepts OpenCode clients; Hermes therefore uses the free
route with the same `OPENCODE_GO_API_KEY` from `~/.hermes/.env` and an
`opencode/2.2.5` user agent. This is a local convenience, not an official
integration: if OpenCode tightens the client check, Hermes reports the error
instead of silently spending Go credit. The router is installed as
`~/.local/bin/ricelin-model-route` with the user timer
`ricelin-model-route.timer`. Its state lives in
`~/.local/state/ricelin/model-route/`.

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
| 26 | Customisation step |
| 27 | Verification |

`--check` performs the verification pass without changing state.

## Layout

```text
.
├── install.sh
├── docs/
│   ├── install.md
│   └── troubleshooting.md
└── .github/
    ├── workflows/
    ├── ISSUE_TEMPLATE/
    └── pull_request_template.md
```

Reference scripts used during development are not part of this repository.
`install.sh` is the supported entry point.

## Documentation

- [Install](docs/install.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Wiki](https://github.com/wflzao/dots/wiki)

## License

MIT
