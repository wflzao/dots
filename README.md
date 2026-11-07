# dots

Self-contained installer for a [Ricelin](https://github.com/Gakuseei/Ricelin)
desktop on Arch-family systems. One Bash file; no generated scripts and no
external stage files.

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
| `-y`, `--yes` | Skip the confirmation prompt |
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
3. **Packages** — SDDM, Thunar stack, greeter tools, `nvidia-settings`, Zen,
   OpenCode, `nvibrant-bin`; bootstraps `yay`/`paru` when needed. Hermes Agent
   and Hermes Desktop are installed from the official bootstrap with their own
   interactive setup wizard: the provider, model, API key, tools, gateway and
   telemetry choices are yours. The installer does not preselect or configure
   them.
4. **SDDM** — installs the package, creates `/etc/sddm.conf.d`, runs the
   upstream theme installer at `configs/sddm/themes/torii/install.sh`.
5. **Customisation** — system handover, diff-only updater, SDDM palette and
   greeter, fans/vibrance, the live SUPER+I choices (dynamic palette, Sunday
   week start, scheduled 3500 K night light with a 5-minute fade), the bundled
   wallpaper set (`1.png`, `2.jpg`, `3.png`, `4.jpg`) in
   `~/.config/ricelin/wallpapers` with
   `4.jpg` as the default with its matugen tone pinned to Dark while the
   others stay on Auto, native resolution at the highest refresh,
   KDE/fish and terminal palette, portal colour-scheme sync, Zen colours,
   Thunar, polkit, night-light cursor, wallpaper tone, wallpaper-strip
   centring, lock-screen palette, settings zoom, atomic theme writes, menus,
   app glass, game-mode opacity, screenshots, UI tweaks, smooth clipboard
   scrolling, logout.
6. **Verification** — final palette render and blocking-item report.

The installer removes **LightDM**, **Firefox** and **Dolphin**, including their
user configuration, and switches to SDDM, Zen and Thunar. It never stops the
running graphical session. A reboot is required to land on SDDM.

New installs start on `4.jpg` with its dynamic matugen palette forced to
**Dark**. Other wallpapers stay on **Auto** and derive light or dark from the
image. Change the wallpaper from the strip or SUPER+B, and the tone from
SUPER+I > Appearance > Palette; the choice is remembered per wallpaper.

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
