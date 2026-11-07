# Troubleshooting

Every run writes a log:

```text
~/.local/state/ricelin-installer/install-YYYYMMDD-HHMMSS.log
```

The installer prints the last 40 lines on failure. Use `--verbose` to stream the
full output to the terminal as well.

## Exit codes

| Code | Phase | First things to check |
|---:|---|---|
| 10 | Preflight | Distro, root method, base commands, disk space |
| 20 | Network | DNS, proxy, `git ls-remote https://github.com/Gakuseei/Ricelin.git HEAD` |
| 21 | Ricelin base | `~/.local/share/ricelin`, upstream installer output |
| 22 | Packages | `pacman`/`yay`/`paru`, AUR reachability, disk space |
| 23 | NVIDIA | `nvidia-smi`, driver version, X display, `nvidia-settings` |
| 24 | SDDM package | `pacman -S sddm`, `/etc/sddm.conf.d` permissions |
| 25 | SDDM theme | Upstream torii path, `/usr/share/sddm/themes/torii` |
| 26 | Customisation step | The step name in the log |
| 27 | Verification | The blocking item in the report |

## Preflight (10)

- Run as a normal desktop user, not root.
- Install `sudo`, `doas` or `pkexec`.
- Arch family only; `pacman` must exist.
- Install missing commands:

  ```sh
  sudo pacman -S --needed git curl python jq systemd
  ```

- Free at least 3 GiB under `$HOME` (8 GiB recommended with Hermes Desktop).
- Check network:

  ```sh
  GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/Gakuseei/Ricelin.git HEAD
  ```

- NVIDIA GPU present but `nvidia-smi` fails: install the matching driver and
  reboot.
- Dolphin demo present: the installer removes Dolphin and its user config. Back
  it up first.
- Not running Hyprland: files install, but live reloads wait for the next login.

## Base and packages (21, 22)

- Inspect `~/.local/share/ricelin`. If the base is broken, run its installer by
  hand:

  ```sh
  sh ~/.local/share/ricelin/install.sh --sddm
  ```

  The upstream wizard runs in the terminal. If there is no controlling
  terminal (for example a cron job), pass `--quickstart` yourself to accept the
  Quick-profile defaults.

- Check for a stale pacman lock: `ls /var/lib/pacman/db.lck`.
- Refresh mirrors and retry: `sudo pacman -Syu`.
- AUR packages are `zen-browser-bin` and `nvibrant-bin`. If the helper
  bootstrap fails, install `base-devel` and `yay` manually.

## SDDM (24, 25)

```sh
sudo pacman -S --needed sddm
sudo install -d -m 0755 /etc/sddm.conf.d
```

The upstream theme installer is:

```text
~/.local/share/ricelin/configs/sddm/themes/torii/install.sh
```

Black screen or no greeter after reboot:

```sh
systemctl status sddm --no-pager
journalctl -b -u sddm --no-pager | tail -50
```

Use `Ctrl+Alt+F3` for a TTY. To return to a text login:

```sh
sudo systemctl disable --now sddm
```

## NVIDIA (23)

```sh
nvidia-smi -L
nvidia-smi --query-gpu=fan.speed --format=csv,noheader
nvidia-settings -q fans
systemctl status nvidia-fan.service --no-pager -l
journalctl -b -u nvidia-fan.service --no-pager
```

For vibrance:

```sh
nvidia-smi
command -v nvibrant
systemctl --user status nvibrant-75.service
```

## Model routing

Inspect the schedule, route and state:

```sh
~/.local/bin/peak-guard status
~/.local/bin/peak-guard status --json
systemctl --user status ricelin-model-route.timer
cat ~/.local/state/ricelin/model-route/route.json
cat ~/.local/state/ricelin/model-route/free-exhausted-at 2>/dev/null
```

Check the two configs:

```sh
opencode debug config | grep -A4 '"model"'
hermes config get model
```

Common causes:

- the timer is not enabled: `systemctl --user enable --now
  ricelin-model-route.timer`;
- Hermes has no `OPENCODE_GO_API_KEY` in `~/.hermes/.env`, so the free route
  cannot authenticate; add the key and restart the Hermes gateway;
- the free allowance is exhausted: it is shared by every free OpenCode model,
  keyed by IP, and resets at 00:00 UTC. During peak hours `peak-guard` refuses
  paid Go and the free request fails, so wait for the reset;
- a build is caught mid-refactor while peak starts: `peak-guard allow 30m`
  opens an expiring override; `peak-guard deny` closes it;
- OpenCode was updated and no longer accepts `opencode/2.2.5` for the free
  endpoint; update the user agent in `~/.local/bin/ricelin-model-route` and
  `~/.hermes/config.yaml`;
- the holiday calendar behaves unexpectedly: it is **off** by default. Set
  `holidays=on` in `~/.config/ricelin/peakguard.conf` only if OpenCode Go is
  confirmed to honour DeepSeek's Chinese-holiday pricing.

Force one router pass:

```sh
~/.local/bin/ricelin-model-route
```

Remove the router and restore the configs captured on first install:

```sh
systemctl --user disable --now ricelin-model-route.timer
rm -f ~/.local/lib/peakguard.py ~/.local/bin/peak-guard \
      ~/.local/bin/ricelin-model-route \
      ~/.config/systemd/user/ricelin-model-route.service \
      ~/.config/systemd/user/ricelin-model-route.timer
rm -rf ~/.hermes/plugins/peak-guard ~/.config/opencode/plugins/peak-guard
# The first install saved the untouched configs here:
ls ~/.local/state/ricelin/model-route/backup/
```

Restore `backup/config.yaml` over `~/.hermes/config.yaml`, and either restore
`backup/opencode.json` over `~/.config/opencode/opencode.json` or delete
`opencode.json` when `backup/opencode.absent` exists. Disable the Hermes
plugin with `hermes plugins disable peak-guard`.

## Customisation (26)

Read the log; it names the failing command. Common causes:

- stale pacman lock;
- leftover LightDM;
- missing `sddm.service`;
- missing `wallcolors.py`;
- upstream anchors moved after `ricelin update`.

Re-run the customisation layer:

```sh
./install.sh --skip-base --yes
```

## Verification (27)

`./install.sh --check` lists blocking items. Common ones:

- Ricelin managed marker missing;
- SDDM not enabled;
- `lightdm`, `firefox` or `dolphin` still installed;
- vibrance state not `75`.

## Getting help

Open an issue with the `--check` output, exit code, failing step and the last 40
lines of the log. Remove tokens and personal paths first.
