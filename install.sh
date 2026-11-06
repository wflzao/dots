#!/usr/bin/env bash
#
# Ricelin desktop installer — one pass for the whole rice.
#
# This is the complete installer, not just a patch bundle:
#
#   1. Preflight: Arch-family check, root method, network, disk, NVIDIA,
#      packages, SDDM/theme paths and a Dolphin-demo warning.
#   2. Ricelin base: clone/update https://github.com/Gakuseei/Ricelin and run
#      its installer with --quickstart --sddm. Skipped when the managed marker
#      already exists unless --reinstall-base is given.
#   3. Extra packages: SDDM, the Thunar stack, the greeter's xrandr/xrdb,
#      nvidia-settings, Zen and nvibrant-bin. AUR packages go through yay/paru;
#      yay is bootstrapped if the base installer left no helper behind.
#   4. The requested SDDM order: install the package, create
#      /etc/sddm.conf.d, then run the upstream torii theme installer at its
#      real path, configs/sddm/themes/torii/install.sh. (The old guessed path
#      config/sddm/theme/tokii/install.sh does not exist.)
#   5. The tested Ricelin customisation scripts, grouped by dependency:
#        system handover -> updater guard -> SDDM palette/greeter ->
#        fans/vibrance -> palette -> Thunar/polkit -> menus/glass/game mode ->
#        screenshots/UI tweaks -> logout.
#   6. Final palette render and a verification pass.
#
# Usage:
#   ./install.sh                  interactive
#   ./install.sh --yes            non-interactive
#   ./install.sh --check          report only, change nothing
#   ./install.sh --dry-run        preflight + print the plan
#   ./install.sh --skip-base      never touch the Ricelin checkout
#   ./install.sh --reinstall-base
#   ./install.sh --no-nvidia      skip fan/vibrance steps
#   ./install.sh --verbose        stream every step to the terminal
#
# Run as your desktop user, never as root; sudo/doas/pkexec is used only for
# the privileged phases. The running graphical session is never stopped.
# Exit codes: 10 preflight, 20 network, 21 Ricelin base, 22 packages,
# 23 NVIDIA, 24 SDDM package, 25 SDDM theme, 26 a customisation step,
# 27 verification.
#
# This file is self-contained: every stage is a function in this file. It does
# not generate temporary scripts and does not call any external standalone
# scripts.

set -Eeuo pipefail

REPO_URL="https://github.com/Gakuseei/Ricelin.git"
RICELIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ricelin"
THEME_REL="configs/sddm/themes/torii/install.sh"
THEME_DIR="/usr/share/sddm/themes/torii"
SDDM_CONF_DIR="/etc/sddm.conf.d"

ASSUME_YES=0
CHECK_ONLY=0
DRY_RUN=0
SKIP_BASE=0
REINSTALL_BASE=0
NO_NVIDIA=0
VERBOSE=0

STEP=0
TOTAL=27
PF_FAIL=0
PF_WARN=0
PF_CODE=10
HAS_NVIDIA=0
NVIDIA_OK=0
FAN_OK=0
VIBRANT_OK=0
BASE_MANAGED=0
NET_OK=0
ROOT_CMD=""
AUR_HELPER=""
GPU_NAME=""
GPU_DRIVER=""

# ---------------------------------------------------------------- small UI
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    BLUE=$'\033[34m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
else
    B=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

ui_header() {
    printf '\n%sRicelin desktop installer%s\n' "$B" "$RESET"
    printf '%sFull rice, NVIDIA, SDDM and Zen. Arch family only.%s\n' "$DIM" "$RESET"
}

ui_step() {
    printf '\n%s▌ [%d/%d] %s%s\n' "$BLUE" "$STEP" "$TOTAL" "$1" "$RESET"
}
ui_ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
ui_warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
ui_fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
ui_skip() { printf '  %s↷%s %s\n' "$DIM" "$RESET" "$1"; }
ui_plan() { printf '  %s·%s would %s\n' "$DIM" "$RESET" "$1"; }
ui_say()  { printf '%s\n' "$1"; }

# --------------------------------------------------------------- logging
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-installer"
LOG=""
setup_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
    LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG" 2>/dev/null || LOG="${TMPDIR:-/tmp}/ricelin-installer-$$.log"
    printf 'Ricelin installer log: %s\n' "$LOG"
}

# Run one command or function, logging its output. On failure print the tail so
# the terminal keeps the useful part and the full log stays on disk.
run_quiet() {
    local label=$1; shift
    {
        printf '\n===== %s =====\n' "$label"
        printf '$ %s\n' "$*"
    } >>"$LOG" 2>&1

    local rc=0
    if [ "$VERBOSE" = 1 ]; then
        set +e
        "$@" 2>&1 | tee -a "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
    else
        set +e
        "$@" >>"$LOG" 2>&1
        rc=$?
        set -e
    fi

    if [ "$rc" -ne 0 ]; then
        printf '\n%s--- last lines from %s ---%s\n' "$DIM" "$label" "$RESET" >&2
        tail -n 40 "$LOG" >&2 || true
        printf '%s--- end log ---%s\n\n' "$DIM" "$RESET" >&2
    fi
    return "$rc"
}

fail_with() {
    local code=$1 message=$2 hint=$3
    ui_fail "$message"
    printf '\n  %sWhat to do:%s %s\n' "$B" "$RESET" "$hint"
    [ -n "$LOG" ] && printf '  Full log: %s\n' "$LOG"
    printf '  Exit code: %s\n\n' "$code"
    exit "$code"
}

fail_step() {
    local label=$1 rc=$2 code=26 hint="See the log above, fix the reported problem, then re-run."

    case "$label" in
        *"Ricelin base"*)
            code=21
            hint="Check the clone at $RICELIN_DIR and run its installer by hand: sh \"$RICELIN_DIR/install.sh\" --quickstart --sddm" ;;
        *"Packages"*)
            code=22
            hint="Check pacman/yay and the network, then re-run. AUR packages are zen-browser-bin and nvibrant-bin." ;;
        *"SDDM package"*)
            code=24
            hint="Install SDDM by hand with: $ROOT_CMD pacman -S --needed sddm" ;;
        *"torii"*)
            code=25
            hint="The real upstream path is $RICELIN_DIR/$THEME_REL (not configs/sddm/theme/tokii). Verify the checkout is complete and re-run." ;;
        *"NVIDIA fans"*)
            code=23
            hint="Check nvidia-smi, nvidia-settings and a writable X display. The fan helper falls back to the user's Xwayland when SDDM's Xorg is absent." ;;
        *"vibrance"*)
            code=23
            hint="Check that the NVIDIA driver answers nvidia-smi and that yay/paru can install nvibrant-bin." ;;
        *"SDDM palette"*|*"greeter"*|*"Greeter"*)
            code=25
            hint="Make sure the torii theme is installed at $THEME_DIR, then re-run the SDDM steps." ;;
        *"System integration"*)
            code=26
            hint="Check for a pacman lock, leftover LightDM packages, or a missing sddm.service; the log shows the exact command." ;;
        *"Final palette"*)
            code=26
            hint="Run the palette by hand: python3 ~/.config/hypr/scripts/wallcolors.py \"$(cat ~/.local/state/ricelin-wallpaper 2>/dev/null || true)\"" ;;
    esac
    if [ "$rc" -eq 130 ]; then
        hint="Interrupted. Re-run the installer when ready; completed steps are idempotent."
    fi
    fail_with "$code" "Step failed: $label (exit $rc)" "$hint"
}

run_step() {
    local label=$1; shift
    STEP=$((STEP + 1))
    ui_step "$label"
    if [ "$DRY_RUN" = 1 ]; then
        ui_plan "$label"
        return 0
    fi
    if run_quiet "$label" "$@"; then
        ui_ok "$label"
    else
        local rc=$?
        fail_step "$label" "$rc"
    fi
}

skip_step() {
    STEP=$((STEP + 1))
    ui_step "$1"
    ui_skip "$2"
}

as_root() {
    case "$ROOT_CMD" in
        sudo)   sudo "$@" ;;
        doas)   doas "$@" ;;
        pkexec) pkexec "$@" ;;
        *)      return 1 ;;
    esac
}

pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- preflight
pf_ok()   { ui_ok "$1"; }
pf_warn() { PF_WARN=$((PF_WARN + 1)); ui_warn "$1"; }
pf_fail() {
    PF_FAIL=$((PF_FAIL + 1))
    [ "$PF_CODE" = 10 ] && PF_CODE=${2:-10}
    ui_fail "$1"
}

detect_root() {
    if [ "$(id -u)" -eq 0 ]; then
        pf_fail "Run this as your desktop user, not root." 10
        return
    fi
    if command -v sudo >/dev/null 2>&1; then
        ROOT_CMD=sudo
    elif command -v doas >/dev/null 2>&1; then
        ROOT_CMD=doas
    elif command -v pkexec >/dev/null 2>&1; then
        ROOT_CMD=pkexec
    else
        pf_fail "No sudo, doas or pkexec found; the privileged steps cannot run." 10
    fi
}

detect_network() {
    if GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1; then
        NET_OK=1
        pf_ok "Network: github.com reachable"
    else
        NET_OK=0
        if [ "$BASE_MANAGED" = 1 ]; then
            pf_warn "Network: github.com not reachable; the existing base is kept, but AUR installs need it."
        else
            pf_fail "Network: github.com not reachable and the Ricelin base is not installed." 20
        fi
    fi
}

detect_nvidia() {
    if [ "$NO_NVIDIA" = 1 ]; then
        HAS_NVIDIA=0; NVIDIA_OK=0; FAN_OK=0; VIBRANT_OK=0
        pf_warn "NVIDIA: disabled by --no-nvidia; fan and vibrance steps will be skipped."
        return
    fi

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        HAS_NVIDIA=1
        NVIDIA_OK=1
        VIBRANT_OK=1
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
        GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
        fan=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader 2>/dev/null | head -n1 || true)
        case "$fan" in
            *[0-9]*) FAN_OK=1 ;;
            *)       FAN_OK=0 ;;
        esac
        if [ "$FAN_OK" = 1 ]; then
            pf_ok "NVIDIA: ${GPU_NAME:-GPU} on driver ${GPU_DRIVER:-unknown}; fan control available"
        else
            pf_warn "NVIDIA: ${GPU_NAME:-GPU} on driver ${GPU_DRIVER:-unknown}; no controllable fan reported, fan step will be skipped."
        fi
    elif grep -qi '0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
        HAS_NVIDIA=2
        NVIDIA_OK=0
        pf_fail "NVIDIA GPU present, but nvidia-smi does not answer. Install the matching driver (nvidia-open/nvidia) and reboot before running this installer." 23
    else
        HAS_NVIDIA=0; NVIDIA_OK=0; FAN_OK=0; VIBRANT_OK=0
        pf_warn "NVIDIA: no NVIDIA GPU detected; fan and vibrance steps will be skipped."
    fi
}

preflight() {
    printf '\n%sPreflight%s\n' "$B" "$RESET"

    detect_root
    if [ "$ROOT_CMD" = sudo ] && [ "$CHECK_ONLY" = 0 ] && [ "$DRY_RUN" = 0 ]; then
        if ! sudo -v; then
            pf_fail "sudo authentication failed." 10
        fi
    fi

    if ! command -v pacman >/dev/null 2>&1; then
        pf_fail "pacman was not found. This installer targets Arch, EndeavourOS, CachyOS and their derivatives." 10
    else
        pf_ok "Distro: Arch family (pacman present)"
    fi

    local missing_cmd=0
    for c in git curl python3 jq systemctl timeout; do
        if command -v "$c" >/dev/null 2>&1; then
            :
        else
            pf_fail "Required command missing: $c" 10
            missing_cmd=1
        fi
    done
    [ "$missing_cmd" = 0 ] && pf_ok "Base tools: git, curl, python3, jq"

    avail=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    if [ "${avail:-0}" -lt 1048576 ]; then
        pf_fail "Less than 1 GiB free under $HOME; free space before installing." 10
    elif [ "${avail:-0}" -lt 5242880 ]; then
        pf_warn "Only $((avail / 1024)) MiB free under $HOME; the base and Zen need room."
    else
        pf_ok "Disk: $((avail / 1024)) MiB free under $HOME"
    fi

    if [ -f "$HOME/.config/hypr/.ricelin-managed" ]; then
        BASE_MANAGED=1
        pf_ok "Ricelin base: installed (managed marker found)"
    else
        BASE_MANAGED=0
        pf_warn "Ricelin base: not installed; the installer will clone it and run install.sh --quickstart --sddm."
    fi

    detect_network
    detect_nvidia

    local missing=""
    for p in thunar thunar-volman gvfs tumbler xorg-xrandr xorg-xrdb; do
        pkg_installed "$p" || missing="$missing $p"
    done
    [ "$NVIDIA_OK" = 1 ] && ! pkg_installed nvidia-settings && missing="$missing nvidia-settings"
    if [ -n "$missing" ]; then
        pf_warn "Packages to install:${missing}"
    else
        pf_ok "Thunar stack, greeter tools and NVIDIA tools: present"
    fi

    if pkg_installed sddm; then
        pf_ok "SDDM package: installed"
    else
        pf_warn "SDDM package: not installed (will install it)"
    fi
    if [ -f "$THEME_DIR/Main.qml" ]; then
        pf_ok "torii theme: present"
    else
        pf_warn "torii theme: not installed yet"
    fi

    AUR_HELPER=$(command -v yay 2>/dev/null || command -v paru 2>/dev/null || true)
    if [ -n "$AUR_HELPER" ]; then
        pf_ok "AUR helper: $AUR_HELPER"
    else
        pf_warn "AUR helper: none yet; the base installer or this installer will bootstrap yay."
    fi

    if pkg_installed zen-browser-bin || command -v zen-browser >/dev/null 2>&1; then
        pf_ok "Zen Browser: installed"
    else
        pf_warn "Zen Browser: not installed (will install zen-browser-bin)"
    fi

    if [ -f "$RICELIN_DIR/$THEME_REL" ]; then
        pf_ok "Theme installer: $RICELIN_DIR/$THEME_REL"
    elif [ "$BASE_MANAGED" = 1 ]; then
        pf_warn "Theme installer missing from $RICELIN_DIR; the installer will update the checkout."
    fi

    if [ -f "$HOME/.local/share/kio/servicemenus/ricelin-wallpaper.desktop" ] \
        || [ -f "$HOME/.local/share/applications/org.kde.dolphin.desktop" ]; then
        pf_warn "Dolphin demo detected. The system-integration step removes Dolphin and its user config; wipe the demo first if you want to keep it."
    fi

    if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        pf_warn "Not running inside Hyprland; files are installed, but live reloads wait for the next login."
    else
        pf_ok "Session: Hyprland ${HYPRLAND_INSTANCE_SIGNATURE}"
    fi

    if [ "$PF_FAIL" -gt 0 ]; then
        printf '\n%sPreflight failed: %d error(s), %d warning(s).%s\n' "$RED" "$PF_FAIL" "$PF_WARN" "$RESET"
        [ "$CHECK_ONLY" = 1 ] && exit 10
        fail_with "$PF_CODE" "Preflight failed." "Fix the items marked ✗ above, then re-run the installer."
    fi
    if [ "$PF_WARN" -gt 0 ]; then
        printf '\nPreflight: %d warning(s), no blocking errors.\n' "$PF_WARN"
    else
        printf '\nPreflight: all checks passed.\n'
    fi
}

# -------------------------------------------------------------- base + packages
bootstrap_ricelin() {
    if [ -d "$RICELIN_DIR/.git" ]; then
        run_quiet "update Ricelin checkout" git -C "$RICELIN_DIR" pull --ff-only || true
    elif [ -e "$RICELIN_DIR" ]; then
        printf 'Refusing to overwrite %s: it exists but is not a git checkout.\n' "$RICELIN_DIR" >&2
        return 1
    else
        run_quiet "clone Ricelin" git clone --depth 1 "$REPO_URL" "$RICELIN_DIR" || return 1
    fi

    local -a args=(--quickstart --sddm)
    [ "$REINSTALL_BASE" = 1 ] && args=(--reinstall "${args[@]}")
    run_quiet "run Ricelin installer" sh "$RICELIN_DIR/install.sh" "${args[@]}" || return 1
    [ -f "$HOME/.config/hypr/.ricelin-managed" ]
}

ensure_aur_helper() {
    if command -v yay >/dev/null 2>&1; then AUR_HELPER=yay; return 0; fi
    if command -v paru >/dev/null 2>&1; then AUR_HELPER=paru; return 0; fi
    if pkg_installed yay || pkg_installed yay-bin; then AUR_HELPER=yay; return 0; fi

    if run_quiet "install yay from the repo" "$ROOT_CMD" pacman -S --needed --noconfirm yay; then
        AUR_HELPER=yay
        return 0
    fi

    command -v makepkg >/dev/null 2>&1 || \
        run_quiet "install base-devel" "$ROOT_CMD" pacman -S --needed --noconfirm base-devel || true

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ricelin-yay.XXXXXX")
    if run_quiet "clone yay-bin" git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"; then
        if (cd "$tmp/yay-bin" && run_quiet "build yay-bin" makepkg -si --noconfirm); then
            rm -rf "$tmp"
            AUR_HELPER=yay
            return 0
        fi
    fi
    rm -rf "$tmp"
    return 1
}

aur_install() {
    local pkg=$1
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        run_quiet "install $pkg" "$ROOT_CMD" pacman -S --needed --noconfirm "$pkg"
    elif [ -n "$AUR_HELPER" ]; then
        run_quiet "install $pkg (AUR)" "$AUR_HELPER" -S --needed --noconfirm "$pkg"
    else
        printf 'No AUR helper for %s.\n' "$pkg" >&2
        return 1
    fi
}

install_packages() {
    local missing=()
    local p
    for p in thunar thunar-volman gvfs tumbler xorg-xrandr xorg-xrdb; do
        pkg_installed "$p" || missing+=("$p")
    done
    if [ "$NVIDIA_OK" = 1 ] && ! pkg_installed nvidia-settings; then
        missing+=(nvidia-settings)
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        run_quiet "install extra packages" "$ROOT_CMD" pacman -S --needed --noconfirm "${missing[@]}" || return 1
    fi

    local need_aur=0
    if ! pkg_installed zen-browser-bin && ! command -v zen-browser >/dev/null 2>&1; then
        need_aur=1
    fi
    if [ "$VIBRANT_OK" = 1 ] && ! command -v nvibrant >/dev/null 2>&1; then
        need_aur=1
    fi

    if [ "$need_aur" = 1 ]; then
        ensure_aur_helper || {
            printf 'Could not find or bootstrap yay/paru; AUR packages cannot be installed.\n' >&2
            return 1
        }
        if ! pkg_installed zen-browser-bin && ! command -v zen-browser >/dev/null 2>&1; then
            aur_install zen-browser-bin || return 1
        fi
        if [ "$VIBRANT_OK" = 1 ] && ! command -v nvibrant >/dev/null 2>&1; then
            aur_install nvibrant-bin || return 1
        fi
    fi
}

install_sddm() {
    if ! pkg_installed sddm; then
        run_quiet "install sddm" "$ROOT_CMD" pacman -S --needed --noconfirm sddm || return 1
    fi
    run_quiet "create $SDDM_CONF_DIR" "$ROOT_CMD" install -d -m 0755 "$SDDM_CONF_DIR" || return 1
}

install_torii_theme() {
    local installer="$RICELIN_DIR/$THEME_REL"
    if [ ! -f "$installer" ]; then
        installer=$(find "$RICELIN_DIR/configs/sddm" -type f -path '*/themes/*/install.sh' -print -quit 2>/dev/null || true)
    fi
    if [ -z "$installer" ] || [ ! -f "$installer" ]; then
        printf 'SDDM theme installer not found. Expected %s\n' "$RICELIN_DIR/$THEME_REL" >&2
        return 1
    fi
    export SUDO="$ROOT_CMD"
    run_quiet "run torii theme installer" bash "$installer" || {
        unset SUDO
        return 1
    }
    unset SUDO
    [ -f "$THEME_DIR/Main.qml" ]
}

# --------------------------------------------------------------- script phases
apply_sddm_match() {
    run_quiet "SDDM palette root phase" run_root_stage stage_sddm_palette --root || return 1
    run_quiet "SDDM palette user phase" stage_sddm_palette || return 1
}

apply_system_integration() {
    run_quiet "system integration root phase" run_root_stage stage_system_integration --root || return 1
    run_quiet "system integration user phase" stage_system_integration --user || return 1
}

apply_screenshots() {
    run_quiet "screenshot root phase" run_root_stage stage_screenshot_binds --root || true
    run_quiet "screenshot user phase" stage_screenshot_binds || return 1
}

apply_logout() {
    run_quiet "logout root phase" run_root_stage stage_logout --root || return 1
    run_quiet "logout user phase" stage_logout || return 1
}

final_render() {
    local wall
    wall=$(cat "$HOME/.local/state/ricelin-wallpaper" 2>/dev/null || true)
    if [ -n "$wall" ] && [ -f "$wall" ]; then
        python3 "$HOME/.config/hypr/scripts/wallcolors.py" "$wall" "$wall" || return 1
    fi
    if command -v hyprctl >/dev/null 2>&1; then
        hyprctl reload >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------- verification
verify_report() {
    local soft=${1:-0}
    local fatal=0 current theme
    printf '\n%sVerification%s\n' "$B" "$RESET"

    if [ -f "$HOME/.config/hypr/.ricelin-managed" ]; then
        ui_ok "Ricelin base: managed"
    else
        ui_fail "Ricelin base: marker missing"; fatal=$((fatal + 1))
    fi

    if pkg_installed sddm && systemctl is-enabled --quiet sddm 2>/dev/null; then
        ui_ok "SDDM: installed and enabled"
    else
        ui_fail "SDDM: not installed or not enabled"; fatal=$((fatal + 1))
    fi

    theme=$(grep -h '^Current=' "$SDDM_CONF_DIR"/*.conf 2>/dev/null | tail -n1 | cut -d= -f2- || true)
    if [ "$theme" = "ricelin" ] && [ -f /usr/share/sddm/themes/ricelin/Main.qml ]; then
        ui_ok "SDDM theme: ricelin (palette-driven copy of torii)"
    elif [ -f "$THEME_DIR/Main.qml" ]; then
        ui_warn "SDDM theme: ${theme:-unknown}; torii is present"
    else
        ui_fail "SDDM theme: torii/ricelin missing"; fatal=$((fatal + 1))
    fi
    if [ -x /etc/sddm/Xsetup-ricelin.sh ] \
        && grep -q 'Xsetup-ricelin' /etc/sddm.conf.d/20-xsetup.conf 2>/dev/null; then
        ui_ok "SDDM greeter: Ricelin refresh + cursor setup"
    else
        ui_warn "SDDM greeter: Ricelin Xsetup not active"
    fi
    if find /etc/sddm.conf.d -maxdepth 1 -name '*.pre-ricelin' 2>/dev/null | grep -q .; then
        ui_warn "SDDM config: stale backup inside conf.d"
    else
        ui_ok "SDDM config: no stale conf.d backups"
    fi

    for p in lightdm firefox dolphin; do
        if pkg_installed "$p"; then
            ui_fail "$p: still installed"; fatal=$((fatal + 1))
        else
            ui_ok "$p: removed"
        fi
    done

    current=$(xdg-mime query default inode/directory 2>/dev/null || true)
    if [ "$current" = "thunar.desktop" ]; then
        ui_ok "Folder handler: Thunar"
    else
        ui_warn "Folder handler: ${current:-unset} (expected thunar.desktop)"
    fi

    current=$(xdg-settings get default-web-browser 2>/dev/null || true)
    case "$current" in
        *zen*) ui_ok "Default browser: $current" ;;
        *)     ui_warn "Default browser: ${current:-unset} (expected Zen)" ;;
    esac

    if command -v hyprshot >/dev/null 2>&1 || [ -x "$HOME/.local/bin/hyprshot" ]; then
        ui_ok "Screenshot tool: hyprshot"
    else
        ui_warn "Screenshot tool: hyprshot missing"
    fi
    if [ "$(grep -c 'hyprshot -m region' "$HOME/.config/hypr/modules/binds.lua" 2>/dev/null || true)" -ge 1 ]; then
        ui_ok "Screenshot binds: ALT+P / ALT+SHIFT+P"
    else
        ui_warn "Screenshot binds: not found"
    fi

    if [ "$NVIDIA_OK" = 1 ]; then
        local fan
        fan=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader 2>/dev/null | head -n1 | tr -dc '0-9' || true)
        if [ -n "$fan" ] && [ "$fan" -ge 70 ]; then
            ui_ok "GPU fans: ${fan}%"
        else
            ui_warn "GPU fans: ${fan:-unknown}% (expected 75%)"
        fi
        if [ "$(cat "$HOME/.local/state/ricelin/nvibrant-value" 2>/dev/null || true)" = "75" ]; then
            ui_ok "Vibrance state: 75%"
        else
            ui_fail "Vibrance state: $(cat "$HOME/.local/state/ricelin/nvibrant-value" 2>/dev/null || echo missing)"; fatal=$((fatal + 1))
        fi
        if systemctl --user is-enabled --quiet nvibrant-75.service 2>/dev/null; then
            ui_ok "Vibrance login service: enabled"
        else
            ui_warn "Vibrance login service: not enabled"
        fi
        if grep -q 'p >= 50 ? Math.round((p - 50) \* 1023 / 50)' "$HOME/.config/quickshell/pill/Singletons/Devices.qml" 2>/dev/null; then
            ui_ok "Vibrance slider mapping: fixed"
        else
            ui_fail "Vibrance slider mapping: stock/wrong"; fatal=$((fatal + 1))
        fi
    else
        ui_skip "NVIDIA steps: skipped"
    fi

    if [ -f "$HOME/.config/kdeglobals" ] && command -v kreadconfig6 >/dev/null 2>&1; then
        current=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null || true)
        if [ "$current" = "Ricelin" ]; then
            ui_ok "KDE palette: Ricelin"
        else
            ui_warn "KDE palette: ${current:-unset} (expected Ricelin)"
        fi
    else
        ui_warn "KDE palette: kdeglobals or kreadconfig6 missing"
    fi
    if grep -q 'ricelin-fish-palette' "$HOME/.config/fish/torii-greeting.sh" 2>/dev/null; then
        ui_ok "Fish greeting: follows the live palette"
    else
        ui_warn "Fish greeting: palette block not detected"
    fi
    if [ -f "$HOME/.config/hypr/hyprtoolkit.conf" ] \
        && grep -q 'ricelin-hyprtoolkit-palette' "$HOME/.config/hypr/scripts/wallcolors.py" 2>/dev/null; then
        ui_ok "Polkit prompt: follows the wallpaper palette"
    else
        ui_warn "Polkit prompt: hyprtoolkit palette not installed"
    fi
    if [ -x "$HOME/.config/hypr/scripts/logout.sh" ] \
        && [ -x /usr/local/lib/ricelin/logout-vt ] \
        && grep -q 'ricelin-logout' "$HOME/.config/quickshell/pill/Power.qml" 2>/dev/null \
        && sudo -n -l /usr/local/lib/ricelin/logout-vt >/dev/null 2>&1; then
        ui_ok "Logout: returns to SDDM's VT"
    else
        ui_warn "Logout: SDDM VT restore incomplete"
    fi

    current=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)
    case "$current" in
        "'Ricelin"*) ui_ok "GTK theme: $current" ;;
        *)          ui_warn "GTK theme: ${current:-unset} (expected Ricelin-a/b)" ;;
    esac

    if [ -f "$HOME/.cache/ricelin/window-opacity.lua" ] \
        && grep -q 'app-glass' "$HOME/.config/hypr/modules/window_rules.lua" 2>/dev/null; then
        ui_ok "App glass: 90% active / 84% inactive"
    else
        ui_warn "App glass: not detected"
    fi
    if grep -q 'no_hardware_cursors' "$HOME/.config/hypr/modules/input.lua" 2>/dev/null; then
        ui_ok "Night-light cursor: software cursor enabled"
    else
        ui_warn "Night-light cursor: not applied"
    fi
    if jq -e '.appZoom == 1' "$HOME/.local/state/ricelin/flags.json" >/dev/null 2>&1; then
        ui_ok "Settings zoom: 1.0"
    else
        ui_warn "Settings zoom: not 1.0"
    fi

    if [ "$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d \"\')" = "Ricelin" ]; then
        ui_ok "Thunar icons: Ricelin matugen theme"
    else
        ui_warn "Thunar icons: not the Ricelin theme"
    fi
    if xfconf-query -c thunar -p /misc-single-click 2>/dev/null | grep -q false; then
        ui_ok "Thunar: double-click"
    else
        ui_warn "Thunar: not double-click"
    fi
    if grep -q 'background-color: alpha(@accent_bg_color, 0.10)' "$HOME/.config/gtk-3.0/gtk.css" 2>/dev/null; then
        ui_ok "Thunar rubber band: visible accent wash"
    else
        ui_warn "Thunar rubber band: fill not detected"
    fi
    if grep -q 'window.background.csd.popup' "$HOME/.config/gtk-3.0/gtk.css" 2>/dev/null; then
        ui_ok "Thunar menus: single rounded popup surface"
    else
        ui_warn "Thunar menus: popup corner fix not detected"
    fi
    if xfconf-query -c thunar -p /hidden-bookmarks -v 2>/dev/null \
        | grep -q 'recent:///' \
        && xfconf-query -c thunar -p /hidden-bookmarks -v 2>/dev/null | grep -q 'trash:///'; then
        ui_ok "Thunar places: Computer + Home only"
    else
        ui_warn "Thunar places: extra entries not hidden"
    fi
    if xfconf-query -c thunar -p /hidden-devices >/dev/null 2>&1; then
        ui_warn "Thunar devices: hidden-devices is set"
    else
        ui_ok "Thunar devices: all visible"
    fi
    if [ -e "$HOME/.config/gtk-3.0/bookmarks" ]; then
        ui_warn "Thunar bookmarks file: still present"
    else
        ui_ok "Thunar bookmarks file: removed"
    fi
    if [ ! -e /usr/share/gvfs/mounts/network.mount ] \
        && [ -e /etc/pacman.d/hooks/ricelin-gvfs-network.hook ]; then
        ui_ok "Thunar network section: disabled + pinned"
    else
        ui_warn "Thunar network section: not disabled/pinned"
    fi
    if grep -q 'XCURSOR_SIZE.*12' "$HOME/.config/hypr/modules/env.lua" 2>/dev/null; then
        ui_ok "Cursor: 12 px"
    else
        ui_warn "Cursor: not 12 px"
    fi
    if grep -q 'mod .. " + SHIFT + Q".*window.kill' "$HOME/.config/hypr/modules/binds.lua" 2>/dev/null; then
        ui_ok "Window binds: SUPER+Q / SUPER+SHIFT+Q"
    else
        ui_warn "Window binds: not the Ricelin pair"
    fi
    if grep -q 'ricelin-diff-only-update' "$HOME/.config/hypr/scripts/ricelin-update.py" 2>/dev/null; then
        ui_ok "Ricelin updates: diff-only"
    else
        ui_warn "Ricelin updates: upstream wholesale copy"
    fi
    if [ "$(gsettings get org.x.apps.portal color-scheme 2>/dev/null)" =          "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" ]; then
        ui_ok "Portal colour-scheme: in sync"
    else
        ui_warn "Portal colour-scheme: out of sync"
    fi

    if [ "$fatal" -gt 0 ]; then
        printf '\n%sVerification found %d blocking problem(s).%s\n' "$RED" "$fatal" "$RESET"
        [ "$soft" = 1 ] && return 0
        exit 27
    fi
    printf '\n%sVerification passed.%s\n' "$GREEN" "$RESET"
}

# ------------------------------------------------------------------- arguments
usage() {
    cat <<'EOF'
Ricelin desktop installer

Usage: ./install.sh [options]

  -y, --yes             run without the confirmation prompt
      --check           report what is installed; change nothing
      --dry-run         run preflight and print the plan; change nothing
      --skip-base       do not clone or run the Ricelin base installer
      --reinstall-base  pass --reinstall to the Ricelin base installer
      --no-nvidia       skip the fan and vibrance steps
  -v, --verbose         stream every step to the terminal as well as the log
  -h, --help            this help

The installer targets Arch-family systems (Arch, EndeavourOS, CachyOS).
It never stops the running graphical session.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --check|--status) CHECK_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --skip-base) SKIP_BASE=1 ;;
            --reinstall-base) REINSTALL_BASE=1 ;;
            --no-nvidia) NO_NVIDIA=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    if [ "$SKIP_BASE" = 1 ] && [ "$REINSTALL_BASE" = 1 ]; then
        printf -- '--skip-base and --reinstall-base cannot be used together.\n' >&2
        exit 2
    fi
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    if [ ! -t 0 ]; then
        fail_with 10 "No controlling terminal for confirmation." "Re-run with --yes for a non-interactive install."
    fi
    printf '\nThis will install packages, run the Ricelin base installer if needed,\n'
    printf 'apply the rice customisations, and remove LightDM, Firefox and Dolphin.\n'
    printf 'Dolphin demo files, if present, are removed by the system-integration step.\n\n'
    local answer
    read -r -p "Continue? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
    esac
}

run_root_stage() {
    local fn=$1; shift
    local def
    def=$(declare -f "$fn") || return 1
    as_root bash -c "$def
$fn \"\$@\"" bash "$@"
}

# ------------------------------------------------------------------------ main
main() {
    parse_args "$@"
    setup_log
    ui_header
    preflight

    if [ "$CHECK_ONLY" = 1 ]; then
        verify_report 1
        printf '\nCheck complete. No changes made.\n'
        exit 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        printf '\n%sDry run: no files, packages or services will be changed.%s\n' "$DIM" "$RESET"
    else
        confirm
    fi

    # 1. Foundation: base desktop, packages and display-manager files.
    if [ "$SKIP_BASE" = 1 ]; then
        skip_step "Ricelin base" "--skip-base was given"
    elif [ "$BASE_MANAGED" = 1 ] && [ "$REINSTALL_BASE" = 0 ]; then
        skip_step "Ricelin base" "already installed; use --reinstall-base to force"
    else
        run_step "Ricelin base (clone/update + install.sh --quickstart --sddm)" bootstrap_ricelin
    fi
    run_step "Packages (Thunar stack, greeter tools, Zen, nvibrant)" install_packages
    run_step "SDDM package + $SDDM_CONF_DIR" install_sddm
    run_step "torii SDDM theme (configs/sddm/themes/torii)" install_torii_theme

    # 2. System handover and login screen. Settle on one display manager,
    #    browser and file manager before the theme is layered on top.
    run_step "System integration (SDDM, Thunar, remove LightDM/Firefox/Dolphin)" apply_system_integration
    run_step "Diff-only Ricelin updater" stage_diff_only_update
    run_step "SDDM palette copy + Xsetup" apply_sddm_match
    run_step "Greeter refresh rate + cursor" run_root_stage stage_greeter_display --root

    # 3. Hardware. Event-driven: applied once per driver/display start and
    #    after resume, never on a polling timer.
    if [ "$NVIDIA_OK" = 1 ] && [ "$FAN_OK" = 1 ]; then
        run_step "NVIDIA fans 75%" run_root_stage stage_nvidia_fans
    else
        skip_step "NVIDIA fans 75%" "no controllable NVIDIA fan (or --no-nvidia)"
    fi
    if [ "$VIBRANT_OK" = 1 ]; then
        run_step "Digital vibrance 75% + pill mapping" stage_vibrance
    else
        skip_step "Digital vibrance 75%" "no working NVIDIA driver (or --no-nvidia)"
    fi

    # 4. Palette and desktop appearance.
    run_step "KDE/Qt + fish palette" stage_kde_fish_palette
    run_step "Portal colour-scheme sync" stage_portal_scheme
    run_step "Zen wallpaper colours" stage_zen_colors
    run_step "One-tone terminal palette" stage_one_tone_palette
    run_step "Thunar integration" stage_thunar
    run_step "Hyprtoolkit / polkit palette" stage_hyprtoolkit_palette
    run_step "Night-light cursor" stage_nightlight_cursor
    run_step "Wallpaper tone control" stage_wallpaper_tone
    run_step "Settings zoom" stage_settings_zoom
    run_step "Atomic theme writes" stage_atomic_theme_write
    run_step "Pretty menus" stage_pretty_menus
    run_step "App glass" stage_app_glass
    run_step "Game-mode opacity" stage_gamemode_opaque

    # 5. Desktop behaviour.
    run_step "Screenshot binds + hyprshot" apply_screenshots
    run_step "UI tweaks (cursor 12, Q binds, Thunar double-click)" stage_ui_tweaks
    run_step "Logout to SDDM" apply_logout

    # 6. Finalize.
    run_step "Final palette render" final_render

    if [ "$DRY_RUN" = 1 ]; then
        printf '\nDry run complete. No changes were made.\n'
        exit 0
    fi

    verify_report
    printf '\nRestart Zen once if it was already running. Reboot to land on SDDM.\n'
}

# ---------------------------------------------------------------- stage_nvidia_fans
stage_nvidia_fans() (
# Keep the NVIDIA GPU fans at 75%.
#
# NV-CONTROL lets a normal user read fan state but not write it, so this
# installs a small root helper. The setting only has to be applied when the
# NVIDIA X driver starts and after a resume, so there are two event hooks:
#
#   nvidia-fan.service   starts after display-manager.service and restarts
#                        with it
#   systemd sleep hook   replays the setting after resume
#
# There is deliberately no polling timer. Fan control does not drift, so
# querying the GPU every 30 seconds only wastes cycles.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

helper=/usr/local/lib/ricelin/nvidia-fan-set
service=/etc/systemd/system/nvidia-fan.service
timer=/etc/systemd/system/nvidia-fan.timer
sleep_hook=/usr/lib/systemd/system-sleep/ricelin-nvidia-fan

install -d -m 755 /usr/local/lib/ricelin /usr/lib/systemd/system-sleep

cat > "$helper" <<'HELPER'
#!/bin/sh
# Set every fan of GPU 0 to 75%.
#
# Root can reach the SDDM Xorg server through its own Xauthority file. If SDDM
# is not running, fall back to the desktop user's Xwayland (:0 on this machine,
# :1/:2 on older layouts). The service retries a failed start while the X
# server is coming up, so this tries once and exits.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

apply_on() {
    display=$1
    auth=$2
    [ -r "$auth" ] || return 1

    # Not every GPU exposes two fans. Count what this one reports instead of
    # writing fan:1 on a single-fan card and failing the whole service.
    fans=$(XAUTHORITY=$auth DISPLAY=$display /usr/bin/nvidia-settings -c "$display" \
        -q fans 2>/dev/null | grep -c '\[fan:' || true)
    [ "${fans:-0}" -gt 0 ] || return 1

    XAUTHORITY=$auth DISPLAY=$display /usr/bin/nvidia-settings -c "$display" \
        -a "[gpu:0]/GPUFanControlState=1" >/dev/null 2>&1 || return 1

    i=0
    while [ "$i" -lt "$fans" ]; do
        XAUTHORITY=$auth DISPLAY=$display /usr/bin/nvidia-settings -c "$display" \
            -a "[fan:$i]/GPUTargetFanSpeed=75" >/dev/null 2>&1 || return 1
        i=$((i + 1))
    done

    state=$(XAUTHORITY=$auth DISPLAY=$display /usr/bin/nvidia-settings -c "$display" \
        -t -q GPUFanControlState 2>/dev/null || true)
    [ "$state" = "1" ] || return 1

    i=0
    while [ "$i" -lt "$fans" ]; do
        speed=$(XAUTHORITY=$auth DISPLAY=$display /usr/bin/nvidia-settings -c "$display" \
            -t -q "[fan:$i]/GPUTargetFanSpeed" 2>/dev/null || true)
        [ "$speed" = "75" ] || return 1
        i=$((i + 1))
    done
    return 0
}

# sudo does not always export SUDO_UID, so also read the saved environment.
uid="${PKEXEC_UID:-}"
if [ -z "$uid" ]; then
    uid=$(sed -n 's/^SUDO_UID=\([0-9]*\)$/\1/p' /proc/self/environ 2>/dev/null | tr -d '\0')
fi
home=""
if [ -n "$uid" ]; then
    home=$(getent passwd "$uid" | cut -d: -f6)
fi
[ -n "$home" ] || home=/root

try_all() {
    # SDDM's Xorg server. Its auth file is recreated at boot, hence the glob.
    for auth in /run/sddm/xauth_*; do
        [ -e "$auth" ] || continue
        apply_on :0 "$auth" && return 0
    done

    # Fallback for a Wayland-only display manager: the user's Xwayland. The
    # auth file can be empty, but root can still read it.
    for auth in "$home/.Xauthority" /home/*/.Xauthority; do
        for display in :0 :1 :2; do
            apply_on "$display" "$auth" && return 0
        done
    done
    return 1
}

try_all || {
    echo "nvidia-fan-set: no writable X display found" >&2
    exit 1
}
HELPER

chmod 755 "$helper"
chown root:root "$helper"

cat > "$service" <<'UNIT'
[Unit]
Description=Set NVIDIA GPU fans to 75%
After=display-manager.service
PartOf=display-manager.service
StartLimitIntervalSec=60
StartLimitBurst=6

[Service]
Type=oneshot
ExecStart=/usr/local/lib/ricelin/nvidia-fan-set
Restart=on-failure
RestartSec=5
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
UNIT

cat > "$sleep_hook" <<'HOOK'
#!/bin/sh
# Reapply NVIDIA fan control after resume; the driver may reset it.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ "${1:-}" = "post" ] || exit 0
systemctl --no-block restart nvidia-fan.service
HOOK

chmod 644 "$service"
chown root:root "$service"
chmod 755 "$sleep_hook"
chown root:root "$sleep_hook"

# Older installs used a 30-second timer. Remove it so the polling stops.
systemctl disable --now nvidia-fan.timer >/dev/null 2>&1 || true
rm -f "$timer"

systemctl daemon-reload
systemctl enable nvidia-fan.service >/dev/null
if ! systemctl restart nvidia-fan.service; then
    echo "The fan service failed to start. Its log follows:" >&2
    systemctl status nvidia-fan.service --no-pager -l >&2 || true
    exit 1
fi
)

# ---------------------------------------------------------------- stage_zen_colors
stage_zen_colors() (
# Make Zen Browser follow the live Ricelin wallpaper palette.
#
# Writes the user.js preference that enables chrome/userChrome.css and installs
# the stylesheet in every Zen profile that has a prefs.js.  The stylesheet maps
# Zen's chrome colors to GTK system colors, which wallcolors.py rewrites on each
# wallpaper change.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

zen_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/zen"
zen_root="$zen_cfg"
[ -d "$zen_root" ] || zen_root="$HOME/.zen"

# A fresh install has the Zen package but no profile until the browser runs once.
# Create that first profile headlessly here, so the stylesheet is in place before
# the first real launch instead of requiring a "open Zen, then re-run this" step.
if [ ! -d "$zen_root" ] && command -v zen-browser >/dev/null 2>&1; then
    echo "No Zen profile yet; creating one with a headless first run..."
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/ricelin"
    shot="${XDG_CACHE_HOME:-$HOME/.cache}/ricelin/zen-first-run.png"
    timeout 60 env MOZ_HEADLESS=1 zen-browser --headless --screenshot "$shot" about:blank \
        >/dev/null 2>&1 || true
    rm -f "$shot"
    if [ -d "$zen_cfg" ]; then
        zen_root="$zen_cfg"
    elif [ -d "$HOME/.zen" ]; then
        zen_root="$HOME/.zen"
    fi
fi

if [ ! -d "$zen_root" ]; then
    echo "Zen is not installed (looked in ~/.config/zen and ~/.zen); skipping Zen theming."
    exit 0
fi

profiles=$(find "$zen_root" -maxdepth 2 -type f -name prefs.js -printf '%h\n' 2>/dev/null | sort -u)
if [ -z "$profiles" ]; then
    profiles=$(find "$zen_root" -maxdepth 2 -type f -name times.json -printf '%h\n' 2>/dev/null | sort -u)
fi
if [ -z "$profiles" ]; then
    echo "Zen has no profile under $zen_root yet; launch it once and re-run this script."
    exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM

cat > "$tmp" <<'CSS'
/* Ricelin - Zen follows the wallpaper palette through GTK system colors.
 *
 * wallcolors.py regenerates the GTK theme on every wallpaper change and
 * alternates the GTK theme name, which makes Gecko re-resolve these system
 * colors live. No per-wallpaper Zen restart is needed.
 */

:root {
  /* Accent */
  --zen-primary-color: AccentColor !important;
  --zen-colors-border: AccentColor !important;

  /* Window, sidebar and toolbar surfaces (GTK theme_bg_color) */
  --zen-branding-dark: -moz-dialog !important;
  --zen-branding-paper: -moz-dialog !important;
  --zen-branding-bg: -moz-dialog !important;
  --zen-main-browser-background: -moz-dialog !important;
  --zen-main-browser-background-toolbar: -moz-dialog !important;
  --zen-themed-toolbar-bg: -moz-dialog !important;
  --zen-themed-toolbar-bg-transparent: -moz-dialog !important;
  --zen-colors-primary: -moz-dialog !important;
  --zen-colors-tertiary: -moz-dialog !important;

  /* Fields, URL bar and selected surfaces (GTK theme_base_color) */
  --zen-colors-secondary: -moz-field !important;
  --zen-colors-input-bg: -moz-field !important;
  --zen-urlbar-background: -moz-field !important;
  --toolbar-field-background-color: -moz-field !important;
  --toolbar-field-focus-background-color: -moz-field !important;
  --tab-selected-bgcolor: -moz-field !important;

  /* Text (GTK theme_fg_color) */
  --zen-branding-bg-reverse: -moz-dialogtext !important;
  --zen-colors-primary-foreground: -moz-dialogtext !important;
  --toolbox-textcolor: -moz-dialogtext !important;
  --toolbox-textcolor-inactive: -moz-dialogtext !important;
  --toolbar-color: -moz-dialogtext !important;
  --toolbarbutton-icon-fill: -moz-dialogtext !important;
  --toolbar-field-color: -moz-dialogtext !important;
  --toolbar-field-focus-color: -moz-dialogtext !important;
  --tab-selected-textcolor: -moz-dialogtext !important;
  --arrowpanel-color: -moz-dialogtext !important;
  --lwt-sidebar-text-color: -moz-dialogtext !important;
  --newtab-text-primary-color: -moz-dialogtext !important;

  /* Subtle surfaces derived from the text color */
  --zen-colors-hover-bg: color-mix(in srgb, -moz-dialogtext 10%, transparent) !important;
  --zen-colors-border-contrast: color-mix(in srgb, -moz-dialogtext 25%, transparent) !important;
  --zen-dialog-background: color-mix(in srgb, -moz-dialogtext 7%, -moz-dialog) !important;
  /* Panels get the GTK popover surface (popover_bg_color = one step above the
   * window), so Zen's own popups and the right-click menus share a tone. */
  --arrowpanel-background: color-mix(in srgb, -moz-dialogtext 4%, -moz-dialog) !important;
  --arrowpanel-border-color: color-mix(in srgb, -moz-dialogtext 12%, transparent) !important;
  --lwt-sidebar-background-color: -moz-dialog !important;
  --newtab-background-color: -moz-dialog !important;

  /* Tabs and toolbar buttons. Zen derives these washes from the branding
   * colours, which collapse to a near-black block once the chrome is remapped,
   * so pin them to the same soft wash the rest of the chrome uses. */
  --toolbarbutton-background-color-hover: color-mix(in srgb, -moz-dialogtext 8%, transparent) !important;
  --toolbarbutton-background-color-active: color-mix(in srgb, -moz-dialogtext 14%, transparent) !important;
  --tab-background-color-hover: color-mix(in srgb, -moz-dialogtext 8%, transparent) !important;
  --tab-background-color-active: color-mix(in srgb, -moz-dialogtext 14%, transparent) !important;
  --zen-toolbar-element-bg: color-mix(in srgb, -moz-dialogtext 5%, transparent) !important;
  --zen-toolbar-element-bg-hover: color-mix(in srgb, -moz-dialogtext 8%, transparent) !important;
}

/* A hovered or selected tab's label and icon must never paint a background of
 * their own -- Zen marks them with the hover colour and the text then sits on a
 * block instead of the tab strip. */
#tabbrowser-tabs .tabbrowser-tab:hover label,
#tabbrowser-tabs .tabbrowser-tab:hover image,
#tabbrowser-tabs .tabbrowser-tab:hover .tab-label,
#tabbrowser-tabs .tabbrowser-tab[selected] label,
#tabbrowser-tabs .tabbrowser-tab[selected] image,
#tabbrowser-tabs .tabbrowser-tab[selected] .tab-label,
#vertical-tabs .tabbrowser-tab:hover label,
#vertical-tabs .tabbrowser-tab:hover image,
#vertical-tabs .tabbrowser-tab[selected] label,
#vertical-tabs .tabbrowser-tab[selected] image {
  background: transparent !important;
}

/* Tab tooltips: a flat dialog-toned bubble, not a black one. */
tooltip,
#tabbrowser-tab-tooltip,
.tooltip {
  color: -moz-dialogtext !important;
  background-color: -moz-dialog !important;
  border: 1px solid color-mix(in srgb, -moz-dialogtext 22%, -moz-dialog) !important;
}

/* Right-click menus. Three separate mistakes made these look foreign:
 *
 *   1. The visible box is drawn by menupopup::part(content), not by the
 *      menupopup element, so the old background/border/padding on the host
 *      painted a square, padded slab behind the rounded menu.
 *   2. The palette now lives in --panel-background-color / --panel-text-color;
 *      the old --panel-background / --panel-color names are gone.
 *   3. The hovered item is marked with a bare `_moz-menuactive` attribute, not
 *      `_moz-menuactive="true"`, so the hover override never matched and items
 *      fell back to -moz-menuhover, the opaque GTK selected colour (a light
 *      slab against a muted accent).
 *
 * This mirrors the GTK3/GTK4 recipe from 06/14: a frosted popover surface
 * (dialog at 84%, the inactive-window opacity, so Hyprland's popup blur shows
 * through), 12px radius, Inter 10, 7px items and a translucent accent wash for
 * hover. */
menupopup,
panel {
  font-family: Inter, system-ui, sans-serif !important;
  font-size: 10pt !important;
  --panel-background-color: color-mix(in srgb, -moz-dialog 84%, transparent) !important;
  --panel-text-color: -moz-dialogtext !important;
  --panel-border-color: color-mix(in srgb, -moz-dialogtext 12%, transparent) !important;
  --panel-border-radius: 12px !important;
  /* Firefox zeroes the inline padding for menus; put it back. */
  --panel-padding: 3px !important;
  --panel-separator-color: color-mix(in srgb, -moz-dialogtext 12%, transparent) !important;
  /* The popup window is only 8px larger than the menu (Firefox's
   * --panel-box-shadow-margin, set by Zen). A 22px blur shadow gets clipped at
   * that window edge, which left a hard, translucent band all the way round the
   * menu; this shadow fades out inside the margin instead. */
  --panel-box-shadow: 0 2px 6px rgba(0, 0, 0, 0.38) !important;
  --panel-box-shadow-margin: 8px !important;
  --menuitem-border-radius: 6px !important;
  --menuitem-padding-block: 4px !important;
  --menuitem-padding-inline: 8px !important;
}

/* The host itself must stay invisible: the shadow part owns the surface. */
menupopup {
  appearance: none !important;
  background: transparent !important;
  border: 0 !important;
  border-radius: 0 !important;
  padding: 0 !important;
  color: -moz-dialogtext !important;
}
/* The visible fill is the content part. Keeping it under 100% lets the
 * compositor frost whatever is behind the popup; backdrop-filter covers the
 * case where the popup window itself is opaque. */
menupopup::part(content) {
  background-color: var(--panel-background-color) !important;
  backdrop-filter: blur(18px) saturate(115%);
}

menupopup > menuitem,
menupopup > menu {
  color: -moz-dialogtext !important;
  background-color: transparent !important;
}
menupopup > menuitem:is([_moz-menuactive], :hover):not([disabled]),
menupopup > menu:is([_moz-menuactive], :hover):not([disabled]) {
  background-color: color-mix(in srgb, AccentColor 16%, transparent) !important;
  color: -moz-dialogtext !important;
}
menupopup > menuitem[disabled],
menupopup > menu[disabled],
menupopup > menuitem[_moz-menuactive][disabled] {
  color: color-mix(in srgb, -moz-dialogtext 42%, transparent) !important;
  background-color: transparent !important;
}
menupopup .menu-accel {
  color: color-mix(in srgb, -moz-dialogtext 45%, transparent) !important;
}
menupopup > menuseparator {
  margin-inline: 6px !important;
}
menupopup > menuseparator::before {
  border-top-color: color-mix(in srgb, -moz-dialogtext 12%, transparent) !important;
}

/* Zen writes the workspace gradient inline on these elements, so :root alone
 * cannot override them. */
#zen-browser-background,
#zen-toolbar-background {
  --zen-main-browser-background: -moz-dialog !important;
  --zen-main-browser-background-toolbar: -moz-dialog !important;
  --zen-main-browser-background-old: -moz-dialog !important;
  --zen-main-browser-background-toolbar-old: -moz-dialog !important;
  --zen-background-opacity: 1 !important;
}
CSS

pref='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'

while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    mkdir -p "$profile/chrome"
    css="$profile/chrome/userChrome.css"

    if [ -f "$css" ] && ! cmp -s "$tmp" "$css"; then
        # Keep one copy of the pre-Ricelin stylesheet, not a snapshot per run.
        [ -f "$css.pre-ricelin" ] || cp -a "$css" "$css.pre-ricelin"
        rm -f "$css".bak.*
    fi
    if ! cmp -s "$tmp" "$css" 2>/dev/null; then
        cat "$tmp" > "$css"
    fi
    chmod 644 "$css" 2>/dev/null || true

    userjs="$profile/user.js"
    if [ -f "$userjs" ] && grep -qE '^[[:space:]]*user_pref\("toolkit\.legacyUserProfileCustomizations\.stylesheets"' "$userjs"; then
        sed -i -E 's|^[[:space:]]*user_pref\("toolkit\.legacyUserProfileCustomizations\.stylesheets".*|'"$pref"'|' "$userjs"
    else
        {
            [ ! -s "$userjs" ] || printf '\n'
            printf '%s\n' '// Ricelin: load chrome/userChrome.css' "$pref"
        } >> "$userjs"
    fi
    chmod 644 "$userjs" 2>/dev/null || true

    echo "Updated $profile"
done <<EOF
$profiles
EOF

wall=$(cat "$HOME/.local/state/ricelin-wallpaper" 2>/dev/null || true)
if [ -n "$wall" ] && [ -f "$HOME/.config/hypr/scripts/wallcolors.py" ]; then
    python3 "$HOME/.config/hypr/scripts/wallcolors.py" "$wall" >/dev/null 2>&1 || true
    echo "Refreshed the GTK palette from $wall"
fi

echo "Restart Zen to load the stylesheet."
)

# ---------------------------------------------------------------- stage_one_tone_palette
stage_one_tone_palette() (
# One tone for the whole desktop: the terminal follows the same palette, and the
# same light or dark mode, as the GTK apps and Zen.
#
# Two things make that true:
#   wallcolors.py    terminal() builds ghostty's base16 from the pill palette and
#                    the HLS lightness of its surface, instead of matugen's
#                    separate always-dark scheme
#   decoration.lua   blur vibrancy 0.15 (was 0.25) and vibrancy_darkness 0.10
#                    (was 0.15), so translucent windows tint the backdrop less
#
# The terminal engine belongs to this script, not to the Ricelin installer:
# `ricelin update` rewrites wallcolors.py from upstream and drops it, so a run
# after an update re-installs it. Applying twice is a no-op.
#
# Usage:
#   sh installer stage            apply
#   sh installer stage --revert   back to the dark terminal and stronger blur
#
# The revert writes a marker file that wallcolors.py checks, so nothing is lost:
# the older scheme is still in the script and can be switched back on any time.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

wc="$HOME/.config/hypr/scripts/wallcolors.py"
dec="$HOME/.config/hypr/modules/decoration.lua"
marker="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin/terminal-dark"

vibrancy() {
    sed -i -E "s/^([[:space:]]*vibrancy[[:space:]]*=[[:space:]]*)[0-9.]+/\1$1/" "$dec"
    sed -i -E "s/^([[:space:]]*vibrancy_darkness[[:space:]]*=[[:space:]]*)[0-9.]+/\1$2/" "$dec"
}

reload_all() {
    wall=$(cat "$HOME/.local/state/ricelin-wallpaper" 2>/dev/null || true)
    if [ -n "$wall" ] && [ -f "$wall" ]; then
        python3 "$wc" "$wall"
    fi
    hyprctl reload >/dev/null 2>&1 || true
    # Ghostty reloads its config, including the generated colours, on SIGUSR2.
    pkill -USR2 -x ghostty 2>/dev/null || true
}

[ -f "$wc" ] || { echo "$wc is missing" >&2; exit 1; }
[ -f "$dec" ] || { echo "$dec is missing" >&2; exit 1; }

# The engine, kept in its own temp file so the Python that splices it stays
# readable and the heredoc body needs no quoting.
engine=$(mktemp)
trap 'rm -f "$engine"' EXIT HUP INT TERM
cat > "$engine" <<'ENGINE'
def terminal(pill, source_hex):
    """
    Ghostty's base16. By default it follows the same palette and the same light or
    dark mode as the app theme, so the terminal stops living in a tone of its own:
    the surface ramp and the text come from the pill palette, the eight accents
    from matugen in that mode. GTK, Zen and the terminal all take their mode
    from one test, the HLS lightness of the palette's surface.

    A file at STATE/terminal-dark pins the older always-dark matugen scheme
    instead, which is what the Ricelin installer
    --revert toggles.
    """
    if (STATE / "terminal-dark").is_file():
        b = {k: v["dark"]["color"] for k, v in matugen(source_hex)["base16"].items()}
        lines = [
            f'background = {b["base00"]}',
            f'foreground = {b["base07"]}',
            f'cursor-color = {pill["primary"]}',
            f'selection-background = {b["base02"]}',
            f'selection-foreground = {b["base07"]}',
        ]
        lines += [f'palette = {i}={b["base%02x" % i]}' for i in range(16)]
        return "\n".join(lines) + "\n"

    r, g, b = (int(pill["surface"][i:i + 2], 16) / 255 for i in (1, 3, 5))
    mode = "light" if colorsys.rgb_to_hls(r, g, b)[1] > 0.5 else "dark"
    accents = {k: v[mode]["color"] for k, v in matugen(source_hex, mode)["base16"].items()}
    ramp = [pill["surface"], pill["surface_container_low"], pill["surface_container"],
            pill["surface_container_high"], pill["surface_container_highest"],
            pill["outline_variant"], pill["dim"], pill["cream"]]
    lines = [
        f'background = {pill["surface"]}',
        f'foreground = {pill["cream"]}',
        f'cursor-color = {pill["primary"]}',
        f'selection-background = {pill["surface_container_high"]}',
        f'selection-foreground = {pill["cream"]}',
    ]
    lines += [f'palette = {i}={color}' for i, color in enumerate(ramp)]
    lines += [f'palette = {i}={accents["base%02x" % i]}' for i in range(8, 16)]
    return "\n".join(lines) + "\n"


ENGINE

# Each edit is anchored on the upstream text and skipped when already present, so
# a run after `ricelin update` restores the engine and a run on top of itself
# changes nothing.
python3 - "$wc" "$engine" <<'PY'
import os
import sys

path, engine = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
block = open(engine, encoding="utf-8").read()

MATUGEN_OLD = '''def matugen(source_hex):
    out = subprocess.run(
        ["matugen", "color", "hex", source_hex, "-m", "dark", "-j", "hex"],
'''
MATUGEN_NEW = '''def matugen(source_hex, mode="dark"):
    out = subprocess.run(
        ["matugen", "color", "hex", source_hex, "-m", mode, "-j", "hex"],
'''

PUBLISH_OLD = '''    lines = [
        f'background = {b["base00"]}',
        f'foreground = {b["base07"]}',
        f'cursor-color = {pill["primary"]}',
        f'selection-background = {b["base02"]}',
        f'selection-foreground = {b["base07"]}',
    ]
    for i in range(16):
        lines.append(f'palette = {i}={b["base%02x" % i]}')
    (CACHE / "ghostty-colors").write_text("\\n".join(lines) + "\\n")
    return 0
'''

PUBLISH_NEW = r'''    try:
        ghostty = terminal(pill, source_hex)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        ghostty = None
    if ghostty:
        write_if_changed(CACHE / "ghostty-colors", ghostty)
    return 0
'''

ANCHOR = "def render_fastfetch(pill):"

if "def terminal(pill, source_hex):" in text:
    print("wallcolors.py: terminal engine already installed")
else:
    for probe, label in ((MATUGEN_OLD, "matugen()"),
                         (PUBLISH_OLD, "the ghostty block in publish()"),
                         (ANCHOR, "render_fastfetch()")):
        if probe not in text:
            sys.exit(f"wallcolors.py: {label} does not match the expected shape")
    text = text.replace(MATUGEN_OLD, MATUGEN_NEW, 1)
    text = text.replace(PUBLISH_OLD, PUBLISH_NEW, 1)
    text = text.replace(ANCHOR, block + ANCHOR, 1)
    tmp = path + ".05.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    print("wallcolors.py: terminal engine installed")
PY

python3 -m py_compile "$wc"
rm -f "$(dirname "$wc")/__pycache__/wallcolors."*.pyc
rmdir "$(dirname "$wc")/__pycache__" 2>/dev/null || true
echo "wallcolors.py compiles."

if [ "${1:-}" = "--revert" ]; then
    mkdir -p "$(dirname "$marker")"
    : > "$marker"
    vibrancy 0.25 0.15
    reload_all
    echo
    echo "Reverted: the terminal is dark again and the blur is back to vibrancy 0.25."
    exit 0
fi

rm -f "$marker"
vibrancy 0.15 0.10
reload_all
echo
echo "Decorated blur now:"
grep -E 'vibrancy' "$dec"
echo
echo "Terminal palette now:"
grep -E '^(background|foreground) =' "$HOME/.cache/ricelin/ghostty-colors" || true
echo
echo "Run with --revert to switch back."
)

# ---------------------------------------------------------------- stage_thunar
stage_kde_fish_palette() (
# Keep KDE/Qt apps and the fish greeting on the live wallpaper palette.
# This is the embedded copy of 19-kde-fish-palette.sh; see that script for
# the full rationale. It only touches sources under the user's home.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
WC="$CONFIG/hypr/scripts/wallcolors.py"
FISH="$CONFIG/fish/torii-greeting.sh"
KDEGLOBALS="$CONFIG/kdeglobals"
SCHEME="${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes/Ricelin.colors"

[ -f "$WC" ] || { echo "wallcolors.py not found at $WC" >&2; exit 1; }
[ -f "$FISH" ] || { echo "fish greeting not found at $FISH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

mode=${1:-apply}
case "$mode" in
    --revert|-r|revert) mode=revert ;;
    *)                  mode=apply ;;
esac

python3 - "$WC" "$FISH" "$KDEGLOBALS" "$SCHEME" "$mode" <<'PY'
import os
import re
import sys

wc, fish, kdeglobals, scheme, mode = sys.argv[1:6]
apply = mode == "apply"

KDE_HELPER = '''# ricelin-kde-palette
def _kde_rgb(color):
    return "%d,%d,%d" % tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def render_kde(pill):
    """Write the live pill palette into KDE's colour scheme and kdeglobals."""
    import configparser

    kdeglobals = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "kdeglobals"
    scheme = (Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
              / "color-schemes" / "Ricelin.colors")
    r, g, b = (int(pill["surface"][i:i + 2], 16) / 255 for i in (1, 3, 5))
    light = __import__("colorsys").rgb_to_hls(r, g, b)[1] > 0.5
    bg = pill["surface_container"]
    bg_alt = pill["surface_container_low"]
    view = pill["surface"]
    high = pill["surface_container_high"]
    highest = pill["surface_container_highest"]
    fg = pill["cream"]
    dim = pill["outline"]
    faint = pill["dim"]
    accent = pill["primary"]
    accent_alt = pill["primary_container"]
    on_accent = max(pill["surface"], pill["bright"], key=lambda c: contrast(c, accent))
    negative = "#b3261e" if light else "#ffb4ab"
    neutral = "#7a5900" if light else "#e6c36a"
    positive = "#3f6b1f" if light else "#b6d18a"

    sections = {
        "Colors:Window": (bg, bg_alt, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:View": (view, bg_alt, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:Button": (high, bg, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:Selection": (accent, accent_alt, on_accent, on_accent, accent, accent_alt,
                             on_accent, on_accent),
        "Colors:Tooltip": (highest, high, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:Complementary": (bg_alt, view, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:Header": (high, bg, fg, dim, accent, accent_alt, accent, accent_alt),
        "Colors:Menu": (high, bg, fg, dim, accent, accent_alt, accent, accent_alt),
    }

    # kdeglobals is the live database: keep every non-colour group (widget
    # style, icons, file dialog state) and replace only the colour groups.
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    try:
        parser.read(kdeglobals, encoding="utf-8")
    except configparser.Error:
        pass
    for name in list(parser.sections()):
        if name.startswith("Colors:"):
            parser.remove_section(name)
    for name, (background, alternate, foreground, inactive,
               focus, hover, link, visited) in sections.items():
        if not parser.has_section(name):
            parser.add_section(name)
        values = {
            "BackgroundNormal": background,
            "BackgroundAlternate": alternate,
            "ForegroundNormal": foreground,
            "ForegroundInactive": inactive,
            "ForegroundActive": focus,
            "ForegroundLink": link,
            "ForegroundVisited": visited,
            "ForegroundNegative": negative,
            "ForegroundNeutral": neutral,
            "ForegroundPositive": positive,
            "DecorationFocus": focus,
            "DecorationHover": hover,
        }
        for key, value in values.items():
            parser.set(name, key, _kde_rgb(value))
    if not parser.has_section("General"):
        parser.add_section("General")
    parser.set("General", "ColorScheme", "Ricelin")
    if not parser.has_section("WM"):
        parser.add_section("WM")
    parser.set("WM", "activeBackground", _kde_rgb(high))
    parser.set("WM", "activeForeground", _kde_rgb(fg))
    parser.set("WM", "inactiveBackground", _kde_rgb(bg_alt))
    parser.set("WM", "inactiveForeground", _kde_rgb(faint))

    out = []
    for section in parser.sections():
        out.append("[" + section + "]")
        for key, value in parser.items(section):
            out.append(key + "=" + value)
        out.append("")
    write_if_changed(Path(kdeglobals), "\\n".join(out))

    # The same colours as a selectable KDE scheme, so Settings > Colours shows
    # Ricelin instead of an unnamed local override.
    if not parser.has_section("General"):
        parser.add_section("General")
    parser.set("General", "Name", "Ricelin")
    scheme_out = ["[General]", "ColorScheme=Ricelin", "Name=Ricelin", ""]
    for name, (background, alternate, foreground, inactive,
               focus, hover, link, visited) in sections.items():
        scheme_out.append("[" + name + "]")
        scheme_out.append("BackgroundNormal=" + _kde_rgb(background))
        scheme_out.append("BackgroundAlternate=" + _kde_rgb(alternate))
        scheme_out.append("ForegroundNormal=" + _kde_rgb(foreground))
        scheme_out.append("ForegroundInactive=" + _kde_rgb(inactive))
        scheme_out.append("ForegroundActive=" + _kde_rgb(focus))
        scheme_out.append("ForegroundLink=" + _kde_rgb(link))
        scheme_out.append("ForegroundVisited=" + _kde_rgb(visited))
        scheme_out.append("ForegroundNegative=" + _kde_rgb(negative))
        scheme_out.append("ForegroundNeutral=" + _kde_rgb(neutral))
        scheme_out.append("ForegroundPositive=" + _kde_rgb(positive))
        scheme_out.append("DecorationFocus=" + _kde_rgb(focus))
        scheme_out.append("DecorationHover=" + _kde_rgb(hover))
        scheme_out.append("")
    write_if_changed(Path(scheme), "\\n".join(scheme_out))


# ricelin-kde-palette-end

'''

text = open(wc, encoding="utf-8").read()
if apply:
    start = text.find("# ricelin-kde-palette\n")
    if start != -1:
        endmark = text.find("# ricelin-kde-palette-end\n", start)
        if endmark == -1:
            endmark = text.find("\ndef publish(", start)
        else:
            endmark += len("# ricelin-kde-palette-end\n")
        if endmark != -1:
            text = text[:start] + text[endmark:]
    if "\ndef publish(" not in text:
        sys.exit("wallcolors.py did not match the expected layout")
    text = text.replace("\ndef publish(", "\n\n" + KDE_HELPER + "def publish(", 1)
    if "# ricelin-kde-palette\n" not in text:
        sys.exit("could not install the KDE renderer")
    if "    render_kde(pill)\n" not in text:
        text = text.replace("    render_fastfetch(pill)\n",
                            "    render_fastfetch(pill)\n    render_kde(pill)\n", 1)
    if 'if sys.argv[1] == "--kde":' not in text:
        text = text.replace(
            'if sys.argv[1] == "--apps":',
            'if sys.argv[1] == "--kde":\n'
            '        try:\n'
            '            pill = json.loads((CACHE / "colors.json").read_text())\n'
            '        except (OSError, ValueError):\n'
            '            pill = STATIC\n'
            '        render_kde(pill)\n'
            '        return 0\n'
            '    if sys.argv[1] == "--apps":', 1)
else:
    start = text.find("# ricelin-kde-palette\n")
    if start != -1:
        endmark = text.find("# ricelin-kde-palette-end\n", start)
        if endmark == -1:
            endmark = text.find("\ndef publish(", start)
        else:
            endmark += len("# ricelin-kde-palette-end\n")
        if endmark != -1:
            text = text[:start] + text[endmark:]
    text = text.replace("    render_fastfetch(pill)\n    render_kde(pill)\n",
                        "    render_fastfetch(pill)\n")
    text = text.replace(
        'if sys.argv[1] == "--kde":\n'
        '        try:\n'
        '            pill = json.loads((CACHE / "colors.json").read_text())\n'
        '        except (OSError, ValueError):\n'
        '            pill = STATIC\n'
        '        render_kde(pill)\n'
        '        return 0\n'
        '    if sys.argv[1] == "--apps":',
        'if sys.argv[1] == "--apps":', 1)
    if "def render_kde(pill):" in text or "--kde" in text:
        sys.exit("could not fully remove the KDE renderer from wallcolors.py")
tmp = wc + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, wc)

# ---------------------------------------------------------------- fish greeting
FISH_BLOCK_OLD = '''R=$'\\e[38;2;224;86;59m'
RH=$'\\e[38;2;239;106;79m'
D=$'\\e[38;2;51;55;63m'
K=$'\\e[38;2;63;69;80m'
S=$'\\e[38;2;139;145;156m'
T=$'\\e[38;2;196;204;218m'
DIM=$'\\e[38;2;91;102;120m'
G=$'\\e[38;2;91;191;115m'
X=$'\\e[0m'
'''

FISH_BLOCK_NEW = '''# ricelin-fish-palette: read the live wallpaper palette, with the old vermilion
# values as a fallback for the first login before wallcolors has run.
_rgb() { printf '\\e[38;2;%d;%d;%dm' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
_palette="${XDG_CACHE_HOME:-$HOME/.cache}/ricelin/colors.json"
R=$'\\e[38;2;224;86;59m'
RH=$'\\e[38;2;239;106;79m'
D=$'\\e[38;2;51;55;63m'
K=$'\\e[38;2;63;69;80m'
S=$'\\e[38;2;139;145;156m'
T=$'\\e[38;2;196;204;218m'
DIM=$'\\e[38;2;91;102;120m'
G=$'\\e[38;2;91;191;115m'
if [ -r "$_palette" ] && command -v jq >/dev/null 2>&1; then
    _c=$(jq -r '[.primary,.primary,.outline_variant,.outline,.outline,.cream,.dim] | @tsv' "$_palette" 2>/dev/null || true)
    if [ -n "$_c" ]; then
        IFS=$'\\t' read -r _p _ph _d _k _s _t _dim <<< "$_c"
        R=$(_rgb "$_p"); RH=$(_rgb "$_ph"); D=$(_rgb "$_d"); K=$(_rgb "$_k")
        S=$(_rgb "$_s"); T=$(_rgb "$_t"); DIM=$(_rgb "$_dim"); G=$(_rgb "$_p")
    fi
fi
X=$'\\e[0m'
'''

text = open(fish, encoding="utf-8").read()
if apply:
    if "# ricelin-fish-palette" not in text:
        if FISH_BLOCK_OLD not in text:
            sys.exit("fish greeting did not match the expected colour block")
        text = text.replace(FISH_BLOCK_OLD, FISH_BLOCK_NEW, 1)
else:
    start = text.find("# ricelin-fish-palette")
    end = text.find("X=$'\\e[0m'\n", start)
    if start != -1 and end != -1:
        text = text[:start] + FISH_BLOCK_OLD + text[end + len("X=$'\\e[0m'\n"):]
tmp = fish + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, fish)

print(("Applied" if apply else "Reverted") + ": KDE/Qt and fish follow the palette.")
PY

# The temp-file + os.replace write above creates a 0644 file. Fish calls the
# greeting directly, so restore the executable bit or every new shell reports
# "exists but is not an executable file".
chmod 755 "$FISH"

python3 -m py_compile "$WC"
rm -f "$(dirname "$WC")/__pycache__/wallcolors."*.pyc
rmdir "$(dirname "$WC")/__pycache__" 2>/dev/null || true

if [ "$mode" = "apply" ]; then
    python3 "$WC" --kde >/dev/null 2>&1 || true
    echo "KDE scheme: $SCHEME"
    echo "kdeglobals: $KDEGLOBALS"
    echo "fish greeting: $FISH"
else
    rm -f "$SCHEME"
    echo "KDE colours are back under your control; the fish greeting is restored."
fi
)

stage_thunar() (
# Make Thunar match the Ricelin desktop.
#
# Thunar already receives the Ricelin GTK theme, but its chrome stayed stock:
# a menu bar, a plain toolbar, a status bar and default metrics. This script
# gives it the same language the pill and Ricelin Settings use - hairline
# separators instead of bevels, the palette's container ramp for surfaces and a
# restrained accent for selection and focus - through two levers:
#
#   1. Thunar's own settings (xfconf channel "thunar"): client-side headerbar,
#      no menu bar, no status bar, a trimmed toolbar, single-click, and so on.
#   2. A GTK3 user stylesheet at ~/.config/gtk-3.0/gtk.css that maps Thunar's
#      widget classes (.sidebar, .standard-view, path-bar, ...) to the named
#      colours the app theme defines, so it follows the wallpaper unchanged.
#      Selection is a translucent accent wash with no gradient or opaque legacy
#      colour, and the rubber-band rectangle is a hairline outline instead of a
#      solid block.
#   3. Thunar becomes the desktop's folder handler (inode/directory) and the
#      SUPER + E bind opens it instead of Dolphin.
#
# It also aligns the global GTK UI font, since Thunar inherits it. The icon
# theme is deliberately left alone: it is a desktop-wide choice, not Thunar's.
#
# Everything is recorded in ~/.local/state/ricelin/thunar-match.json first, and
# `installer stage --revert` puts the machine back exactly as it was.

set -eu

exec python3 - "$@" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state") / "ricelin"
STATE_FILE = STATE_DIR / "thunar-match.json"
GTK3 = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "gtk-3.0"
GTK_CSS = GTK3 / "gtk.css"
BOOKMARKS = GTK3 / "bookmarks"
SETTINGS_INI = GTK3 / "settings.ini"
INI_BAK = STATE_DIR / "thunar-settings.ini.bak"
BINDS = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "hypr" / "modules" / "binds.lua"
WALLCOLORS = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "hypr" / "scripts" / "wallcolors.py"
ICON_DIR = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share") / "icons" / "Ricelin"
ICON_GEN = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "hypr" / "scripts" / "ricelin-thunar-icons.py"

# The Network row is compiled into Thunar and cannot be hidden with Xfconf.
# Disabling GVfs's network mount makes Thunar omit the whole section. A pacman
# hook keeps it disabled after gvfs upgrades, so a fresh install stays exact.
NETWORK_MOUNT = Path("/usr/share/gvfs/mounts/network.mount")
NETWORK_BACKUP = Path(str(NETWORK_MOUNT) + ".ricelin-disabled")
NETWORK_HOOK = Path("/etc/pacman.d/hooks/ricelin-gvfs-network.hook")
NETWORK_HELPER = Path("/usr/local/lib/ricelin/disable-gvfs-network")

MARK = "/** Ricelin app theme, turn it off in Settings > Appearance */"

NETWORK_HELPER_TEXT = """#!/bin/sh
# Keep the GVfs network mount out of Thunar after gvfs package updates.
set -eu
mount=/usr/share/gvfs/mounts/network.mount
backup=$mount.ricelin-disabled
if [ -e "$mount" ]; then
    if [ ! -e "$backup" ]; then
        mv "$mount" "$backup"
    else
        rm -f "$mount"
    fi
fi
"""

NETWORK_HOOK_TEXT = """[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/share/gvfs/mounts/network.mount

[Action]
Description = Ricelin: keep the GVfs network mount disabled
When = PostTransaction
Exec = /usr/local/lib/ricelin/disable-gvfs-network
"""

ICON_GENERATOR = r'''#!/usr/bin/env python3
"""Write the minimal Ricelin icon set from the live matugen palette."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

primary = sys.argv[1] if len(sys.argv) > 1 else "#5e7c2f"
surface = sys.argv[2] if len(sys.argv) > 2 else "#eef5ff"
root = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "icons" / "Ricelin"
if root.is_dir():
    for old in root.rglob("*-symbolic.svg"):
        old.unlink()

INDEX = """[Icon Theme]
Name=Ricelin
Comment=Minimal matugen-coloured icons for Thunar
Inherits=Qogir-Dark,Papirus-Dark,Adwaita,hicolor
Directories=scalable/places,scalable/actions,scalable/status,scalable/devices,scalable/mimetypes

[scalable/places]
Size=24
Type=Scalable
Context=Places

[scalable/actions]
Size=24
Type=Scalable
Context=Actions

[scalable/status]
Size=24
Type=Scalable
Context=Status

[scalable/devices]
Size=24
Type=Scalable
Context=Devices

[scalable/mimetypes]
Size=24
Type=Scalable
Context=MimeTypes
"""

FOLDER = f"""<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="{primary}"/>
  <path d="M3 10h18" stroke="{surface}" stroke-opacity=".30" stroke-width="1"/>
</svg>
"""

def line(path, width="1.8"):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <path d="{path}" fill="none" stroke="{primary}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""

def dot(cx, cy):
    return f'<circle cx="{cx}" cy="{cy}" r="1.35" fill="{primary}"/>'

HOME = line("M4 11l8-7 8 7v9a1 1 0 0 1-1 1h-5v-6h-4v6H5a1 1 0 0 1-1-1z")
DESKTOP = line("M3 5h18v11H3zM9 20h6M12 16v4")
TRASH = line("M5 7h14l-1 13H6zM9 7V5h6v2M9 11v5M15 11v5")
DRIVE = line("M4 6h16v12H4zM7 14h2M17 14h.1")
NETWORK = line("M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18", "1.5")
UP = line("M6 14l6-6 6 6")
DOWN = line("M6 10l6 6 6-6")
LEFT = line("M14 6l-6 6 6 6")
RIGHT = line("M10 6l6 6-6 6")
SEARCH = line("M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5L21 21")
REFRESH = line("M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5")
CLOSE = line("M6 6l12 12M18 6L6 18")
DOC = line("M6 3h8l4 4v14H6zM14 3v5h5M9 13h6M9 17h6")
IMAGE = line("M4 4h16v16H4zM4 16l5-5 4 4 2-2 5 5M9 9h.1")
CLOCK = line("M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16zM12 8v5l3 2")

def write(rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)

write("index.theme", INDEX)
folder_names = ("folder", "folder-open", "folder-download", "folder-downloads",
                "folder-documents", "folder-pictures", "folder-music", "folder-videos",
                "folder-desktop", "folder-public", "folder-publicshare",
                "folder-template", "folder-templates")
for name in folder_names:
    write(f"scalable/places/{name}.svg", FOLDER)
for name, art in (("user-home", HOME), ("user-desktop", DESKTOP), ("user-trash", TRASH),
                  ("computer", DESKTOP), ("document-open-recent", CLOCK)):
    for ctx in ("places", "devices", "actions", "status", "mimetypes"):
        write(f"scalable/{ctx}/{name}.svg", art)
for name in ("drive-harddisk", "drive-harddisk-usb", "drive-removable-media",
             "media-removable", "media-optical"):
    for ctx in ("places", "devices", "actions", "status", "mimetypes"):
        write(f"scalable/{ctx}/{name}.svg", DRIVE)
for ctx in ("places", "devices", "actions", "status", "mimetypes"):
    write(f"scalable/{ctx}/network-workgroup.svg", NETWORK)
for name, art in (("go-previous", LEFT), ("go-next", RIGHT), ("go-up", UP),
                  ("go-home", HOME), ("system-search", SEARCH), ("edit-find", SEARCH),
                  ("view-refresh", REFRESH), ("pan-down", DOWN), ("window-close", CLOSE)):
    write(f"scalable/actions/{name}.svg", art)
write("scalable/status/view-more.svg",
      f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">{dot(6, 12)}{dot(12, 12)}{dot(18, 12)}</svg>\n')
write("scalable/mimetypes/text-x-generic.svg", DOC)
write("scalable/mimetypes/image-x-generic.svg", IMAGE)

if shutil.which("gtk-update-icon-cache"):
    subprocess.run(["gtk-update-icon-cache", "-f", "-t", str(root)],
                   capture_output=True, check=False)
'''


def save(path: Path, text: str) -> None:
    """Write through a temp file, so a reader never sees a truncated theme."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


SCHEMA = "org.gnome.desktop.interface"
GSETTINGS = {
    "font-name": "Inter 10",
    "monospace-font-name": "JetBrainsMono Nerd Font Mono 11",
    "icon-theme": "Ricelin",
}

# xfconf property -> (type, value). Arrays are ("array", [..]).
XFCONF = {
    "/misc-use-csd":                    ("bool", "true"),
    "/last-menubar-visible":            ("bool", "false"),
    "/last-statusbar-visible":          ("bool", "false"),
    "/last-side-pane":                  ("string", "THUNAR_SIDEPANE_TYPE_SHORTCUTS"),
    "/misc-small-toolbar-icons":        ("bool", "true"),
    "/misc-single-click":               ("bool", "false"),
    "/misc-folders-first":              ("bool", "true"),
    "/misc-folder-item-count":          ("bool", "true"),
    "/misc-thumbnail-draw-frames":      ("bool", "false"),
    "/misc-tree-lines-in-tree-sidepane": ("bool", "false"),
    "/misc-window-title-style":         ("int", "0"),
    "/last-toolbar-visible-buttons":    ("array", ["back", "forward", "open-parent", "location-bar", "search"]),
    # Places: only Computer and the user's home remain. Recent, Desktop and
    # Trash are hidden; the home entry is a built-in default, not a bookmark.
    "/hidden-bookmarks":                ("array", ["recent:///", (HOME / "Desktop").as_uri(), "trash:///"]),
    # All devices must be visible, so this property is cleared on apply.
    "/hidden-devices":                  ("array", None),
}

CSS = MARK + """
/*
 * Thunar chrome, matched to the Ricelin pill and Settings window. The colours
 * are the named colours the app theme regenerates on every wallpaper change
 * (see wallcolors.py), so nothing here is hard-coded to a palette.
 */
@define-color ricelin_hair      alpha(@window_fg_color, 0.12);
@define-color ricelin_hair_soft alpha(@window_fg_color, 0.06);
@define-color ricelin_hover     alpha(@window_fg_color, 0.055);
@define-color ricelin_sel       alpha(@accent_bg_color, 0.16);
@define-color ricelin_sel_edge  alpha(@accent_bg_color, 0.38);

/* The icon view (and a few stock widgets) draw selection from the legacy
 * selected colours, which adw-gtk3 points at the opaque accent -- a solid slab
 * that also collides with the accent-coloured text. Route them through the same
 * translucent wash so every selection in Thunar reads the same. */
@define-color theme_selected_bg_color alpha(@accent_bg_color, 0.16);
@define-color theme_selected_fg_color @window_fg_color;
@define-color theme_selected_bg_color_insensitive alpha(@accent_bg_color, 0.08);
@define-color theme_selected_fg_color_insensitive alpha(@window_fg_color, 0.55);

/* --- headerbar and toolbar ------------------------------------------- */
headerbar,
.titlebar {
    background-color: @headerbar_bg_color;
    background-image: none;
    border-bottom: 1px solid @ricelin_hair;
    box-shadow: none;
    min-height: 36px;
    padding: 0 6px;
}
headerbar:backdrop,
.titlebar:backdrop {
    background-color: @headerbar_backdrop_color;
    border-bottom-color: @ricelin_hair_soft;
}
headerbar entry,
headerbar searchentry {
    border-radius: 8px;
    min-height: 26px;
    padding: 0 12px;
    background-color: @view_bg_color;
    background-image: none;
    border: 1px solid @ricelin_hair;
    box-shadow: none;
    color: @view_fg_color;
}
headerbar entry:focus,
headerbar searchentry:focus {
    border-color: @accent_bg_color;
    box-shadow: none;
}
toolbar {
    background-color: @headerbar_bg_color;
    background-image: none;
    border-bottom: 1px solid @ricelin_hair;
    box-shadow: none;
    padding: 4px 6px;
}
headerbar toolbar {
    background: none;
    border-bottom: none;
}

/* --- buttons on the toolbar and path bar ----------------------------- */
toolbar button,
toolbar button.flat,
.path-bar button {
    border-radius: 7px;
    min-height: 26px;
    min-width: 26px;
    padding: 2px 8px;
    background-color: transparent;
    background-image: none;
    border: 1px solid transparent;
    box-shadow: none;
    color: @headerbar_fg_color;
    -gtk-icon-shadow: none;
}
toolbar button:hover,
.path-bar button:hover {
    background-color: @ricelin_hover;
    border-color: @ricelin_hair_soft;
}
toolbar button:checked,
toolbar button:active,
.path-bar button:checked,
.path-bar button:active {
    background-color: @ricelin_sel;
    border-color: @ricelin_sel_edge;
    color: @accent_color;
}
toolbar button:disabled,
.path-bar button:disabled {
    color: alpha(@headerbar_fg_color, 0.4);
}

/* --- the places sidebar ---------------------------------------------- */
.sidebar {
    background-color: @sidebar_bg_color;
    border-right: 1px solid @ricelin_hair;
    border-top: none;
    border-bottom: none;
    color: @sidebar_fg_color;
}
.sidebar.view:selected,
.sidebar treeview.view:selected,
.sidebar iconview:selected,
.sidebar:selected {
    background-color: @ricelin_sel;
    background-image: none;
    color: @window_fg_color;
}
.sidebar treeview.view:hover,
.sidebar.view:hover {
    background-color: @ricelin_hover;
}
.sidebar header,
.sidebar .frame,
.sidebar scrolledwindow {
    background-color: transparent;
    border: none;
    box-shadow: none;
}

/* --- the file view --------------------------------------------------- */
.standard-view,
.standard-view .view {
    background-color: @view_bg_color;
    color: @view_fg_color;
    border: none;
}
/* Every shape Thunar can draw a selection in: the icon view is the .standard-view
 * element itself, the list view is a treeview.view inside it, and the label of a
 * selected cell is a separate text node. All get the same wash and dark text so
 * the highlight never hides the name. */
.standard-view:selected,
.standard-view.view:selected,
.standard-view iconview:selected,
.standard-view treeview.view:selected,
.standard-view .view:selected,
.standard-view .view:selected:focus,
.standard-view iconview:selected:focus,
.standard-view treeview.view:selected:focus,
.view:selected,
.view:selected:focus,
iconview:selected,
treeview.view:selected,
flowbox flowboxchild:selected,
.view text:selected,
iconview text:selected,
.standard-view .view text:selected,
.standard-view iconview text:selected {
    background-color: @ricelin_sel;
    background-image: none;
    box-shadow: none;
    color: @window_fg_color;
}
.standard-view .view:hover,
.standard-view iconview:hover,
.standard-view treeview.view:hover {
    background-color: @ricelin_hover;
}
.preview-pane {
    background-color: @sidebar_bg_color;
    border: none;
    border-left: 1px solid @ricelin_hair;
}

/* --- status bar and separators --------------------------------------- */
.statusbar {
    background-color: @headerbar_bg_color;
    border-top: 1px solid @ricelin_hair;
    color: alpha(@window_fg_color, 0.62);
}
.sidebar separator,
.standard-view separator {
    background-color: @ricelin_hair;
    min-width: 1px;
    min-height: 1px;
}

/* The drag-selection rectangle is its own popup window. GTK fills it with the
 * opaque selected colour by default; in the Exo icon view that reads as a solid
 * block. Keep a quiet accent wash so the dragged rectangle is visible without
 * hiding the files, and draw a hairline accent outline. The specific
 * .standard-view rule is what makes the border win over the icon view's stock
 * chrome. */
.rubberband,
rubberband,
.rubberband:selected,
rubberband:selected,
.rubberband:backdrop,
rubberband:backdrop,
treeview.view rubberband,
treeview.view rubberband:selected,
iconview.rubberband,
iconview.rubberband:selected,
.standard-view rubberband,
.standard-view.rubberband,
.standard-view .view.rubberband,
.standard-view .view.rubberband:selected {
    background-color: alpha(@accent_bg_color, 0.10);
    background-image: none;
    box-shadow: none;
    border: 1px solid alpha(@accent_bg_color, 0.58);
}

/* --- thin overlay scrollbars ----------------------------------------- */
scrollbar {
    background: none;
    border: none;
}
scrollbar trough {
    background: none;
    border: none;
}
scrollbar slider {
    min-width: 6px;
    min-height: 6px;
    border-radius: 999px;
    background-color: alpha(@window_fg_color, 0.22);
    border: 2px solid transparent;
    background-clip: padding-box;
}
scrollbar slider:hover {
    background-color: alpha(@window_fg_color, 0.34);
}

/* --- context menus and popovers --------------------------------------- */
/* Right-click menus everywhere in GTK: a solid dialog surface in the palette,
 * Inter at the UI size, rounded corners and the same soft hover wash as the
 * rest of the desktop. The menu must stay solid because a glassy window is
 * translucent and the compositor does not blur every popup underneath it. */
menu,
.menu,
.context-menu,
popover,
popover.background,
popover.menu {
    background-color: @popover_bg_color;
    background-image: none;
    color: @window_fg_color;
    border: 1px solid @ricelin_hair;
    border-radius: 12px;
    padding: 3px;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.32);
    font-family: "Inter";
    font-size: 10pt;
}
menuitem,
menuitem > label,
modelbutton,
popover modelbutton,
row.activatable {
    font-family: "Inter";
    font-size: 10pt;
    color: @window_fg_color;
}
menuitem,
modelbutton {
    border-radius: 6px;
    padding: 4px 8px;
    min-height: 20px;
}
menuitem:hover,
menuitem:focus,
modelbutton:hover {
    background-color: @ricelin_sel;
    color: @window_fg_color;
}
menuitem:disabled,
modelbutton:disabled {
    color: alpha(@window_fg_color, 0.42);
}
menu separator,
menu > separator,
popover separator {
    background-color: @ricelin_hair;
    min-height: 1px;
    margin: 4px 6px;
}

/* Right-click menus are separate CSD popup windows. The stock theme paints a
 * square window background plus a 9px decoration outline behind the 12px menu,
 * so the two rounded corners show up separated at the edges. Make the popup
 * window itself the one and only surface: one fill, one border, one radius.
 * The menu node and the decoration become transparent, and no shadow is drawn
 * between them (Hyprland shadows the popup). */
window.background.csd.popup,
window.background.popup {
    background-color: @popover_bg_color;
    background-image: none;
    border: 1px solid @ricelin_hair;
    border-radius: 12px;
}
menu,
.menu,
.context-menu,
.csd menu,
.csd .menu,
.csd .context-menu {
    background-color: transparent;
    background-image: none;
    border: none;
    box-shadow: none;
}
.csd.popup decoration,
.popup decoration,
menu decoration {
    background-color: transparent;
    border: none;
    border-radius: 12px;
    box-shadow: none;
}
"""


def run(cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def gget(key):
    out = run(["gsettings", "get", SCHEMA, key]).stdout.strip()
    return out


def gset(key, value):
    run(["gsettings", "set", SCHEMA, key, value])


def mime_default():
    """The desktop's current folder handler, or None when it is unset."""
    r = run(["xdg-mime", "query", "default", "inode/directory"], check=False)
    value = r.stdout.strip()
    return value or None


def set_default_file_manager(name="thunar.desktop"):
    run(["xdg-mime", "default", name, "inode/directory"], check=False)


def super_e_line():
    """Return (line index, line) for the SUPER + E bind, or (None, None)."""
    if not BINDS.is_file():
        return None, None
    for i, line in enumerate(BINDS.read_text().splitlines()):
        if "hl.bind(" in line and re.search(r'\+ E"', line) and "exec_cmd" in line:
            return i, line
    return None, None


def set_super_e(command="thunar"):
    """Point SUPER + E at Thunar without disturbing the rest of the bind line."""
    idx, line = super_e_line()
    if idx is None:
        return False
    match = re.search(r'(hl\.bind\(.*?exec_cmd\(")([^"]*)(".*)', line)
    if not match or match.group(2) == command:
        return False
    lines = BINDS.read_text().splitlines()
    lines[idx] = match.group(1) + command + match.group(3)
    save(BINDS, "\n".join(lines) + "\n")
    return True


def xf_get(prop, kind=None):
    """Return the value, or None when the property is unset. Arrays become lists."""
    r = run(["xfconf-query", "-c", "thunar", "-p", prop], check=False)
    if r.returncode != 0:
        return None
    out = r.stdout.strip()
    if kind == "array":
        lines = out.splitlines()
        if lines and lines[0].startswith("Value is an array"):
            return [line for line in lines[2:] if line]
        return [line for line in lines[1:] if line] if lines else []
    return out


def xf_set(prop, kind, value):
    run(["xfconf-query", "-c", "thunar", "-p", prop, "-r"], check=False)
    if value is None:
        return
    if kind == "array":
        if not value:
            return
        cmd = ["xfconf-query", "-c", "thunar", "-p", prop]
        for item in value:
            cmd += ["-t", "string", "-s", item]
        # Force an array even when only one item is present.
        run(cmd + ["-a", "--create"])
    else:
        run(["xfconf-query", "-c", "thunar", "-p", prop,
             "-t", kind, "-s", value, "--create"])


def xf_reset(prop):
    run(["xfconf-query", "-c", "thunar", "-p", prop, "-r"], check=False)


def root_cmd():
    for candidate in ("sudo", "doas", "pkexec"):
        if shutil.which(candidate):
            return candidate
    return None


def root_run(args):
    root = root_cmd()
    if root is None:
        raise RuntimeError("sudo, doas or pkexec is required for the GVfs network disable")
    result = subprocess.run([root] + list(args), capture_output=True, text=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(message or f"{root} {' '.join(args)} failed")
    return result


def restart_gvfs():
    if shutil.which("systemctl"):
        subprocess.run(["systemctl", "--user", "restart", "gvfs-daemon.service"],
                       capture_output=True)
    elif shutil.which("pkill"):
        subprocess.run(["pkill", "-x", "gvfsd"], capture_output=True)


def install_system_file(path, text, mode):
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(text)
        tmp = handle.name
    try:
        root_run(["install", "-D", "-m", mode, tmp, str(path)])
    finally:
        Path(tmp).unlink(missing_ok=True)


def disable_gvfs_network():
    """Remove the network:/// scheme so Thunar drops its hardcoded Network row."""
    if not NETWORK_MOUNT.exists() and not NETWORK_BACKUP.exists():
        return
    if NETWORK_MOUNT.exists():
        if NETWORK_BACKUP.exists():
            root_run(["rm", "-f", str(NETWORK_MOUNT)])
        else:
            root_run(["mv", str(NETWORK_MOUNT), str(NETWORK_BACKUP)])
    install_system_file(NETWORK_HELPER, NETWORK_HELPER_TEXT, "755")
    install_system_file(NETWORK_HOOK, NETWORK_HOOK_TEXT, "644")
    restart_gvfs()


def restore_gvfs_network(state):
    root_run(["rm", "-f", str(NETWORK_HOOK), str(NETWORK_HELPER)])
    if NETWORK_BACKUP.exists():
        root_run(["mv", str(NETWORK_BACKUP), str(NETWORK_MOUNT)])
    elif not state.get("gvfs_network", True):
        root_run(["rm", "-f", str(NETWORK_MOUNT)])
    restart_gvfs()


def quit_thunar():
    """Stop Thunar writing its last-* window state back over what we set."""
    if shutil.which("thunar"):
        subprocess.run(["thunar", "-q"], capture_output=True)


def capture():
    """Record the pre-change state once; re-running apply must not clobber it."""
    if STATE_FILE.is_file():
        state = json.loads(STATE_FILE.read_text())
        # Installations created before this script also owned the folder handler
        # and SUPER + E have no keys yet. Backfill the live values, which are
        # still the pre-Ricelin ones on the first run of this version.
        changed = False
        for key, value in (("mime_default", mime_default()),
                           ("super_e", super_e_line()[1])):
            if key not in state:
                state[key] = value
                changed = True
        # New in this version: the sidebar/bookmarks state and the GVfs network
        # switch. Older state files did not manage these keys, so their pre-run
        # value is "unset" for our revert path.
        xfconf_state = state.setdefault("xfconf", {})
        for prop in XFCONF:
            if prop not in xfconf_state:
                xfconf_state[prop] = None
                changed = True
        if "bookmarks" not in state:
            state["bookmarks"] = None
            changed = True
        if "gvfs_network" not in state:
            state["gvfs_network"] = NETWORK_MOUNT.exists() or NETWORK_BACKUP.exists()
            changed = True
        if changed:
            save(STATE_FILE, json.dumps(state, indent=2) + "\n")
        return state
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = {
        "xfconf": {p: xf_get(p, XFCONF[p][0]) for p in XFCONF},
        "gsettings": {k: gget(k) for k in GSETTINGS},
        "gtk_css": GTK_CSS.read_text() if GTK_CSS.is_file() else None,
        "settings_ini": SETTINGS_INI.read_text() if SETTINGS_INI.is_file() else None,
        "bookmarks": BOOKMARKS.read_text() if BOOKMARKS.is_file() else None,
        "gvfs_network": NETWORK_MOUNT.exists() or NETWORK_BACKUP.exists(),
        "mime_default": mime_default(),
        "super_e": super_e_line()[1],
    }
    save(STATE_FILE, json.dumps(state, indent=2) + "\n")
    if SETTINGS_INI.is_file():
        shutil.copy2(SETTINGS_INI, INI_BAK)
    return state


def update_ini():
    """Sync the pieces GTK3 apps read directly, and never pin the theme or cursor.

    `gtk-theme-name` used to be written here, but wallcolors.py alternates the
    theme name between Ricelin-a and Ricelin-b on every palette change. A pinned
    name means any app that still reads settings.ini keeps the previous palette
    after a Light/Dark switch. Leaving the key out makes those apps follow
    gsettings, which is what flips."""
    if not SETTINGS_INI.is_file():
        return
    icon = gget("icon-theme").strip("'")
    cursor = gget("cursor-theme").strip("'")
    cursor_size = gget("cursor-size").strip("'")
    lines = []
    for line in SETTINGS_INI.read_text().splitlines():
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key == "gtk-theme-name":
            continue
        if key == "gtk-icon-theme-name":
            line = "gtk-icon-theme-name=" + icon
        elif key == "gtk-cursor-theme-name":
            line = "gtk-cursor-theme-name=" + cursor
        elif key == "gtk-cursor-theme-size":
            line = "gtk-cursor-theme-size=" + cursor_size
        elif key == "gtk-font-name":
            line = "gtk-font-name=Inter 10"
        lines.append(line)
    save(SETTINGS_INI, "\n".join(lines) + "\n")


def render_icons():
    """Install the generator and write the current palette's icon set."""
    ICON_GEN.parent.mkdir(parents=True, exist_ok=True)
    save(ICON_GEN, ICON_GENERATOR)
    primary, surface = "#5e7c2f", "#eef5ff"
    try:
        pill = json.loads((HOME / ".cache" / "ricelin" / "colors.json").read_text())
        primary, surface = pill["primary"], pill["surface"]
    except (OSError, ValueError, KeyError):
        pass
    try:
        subprocess.run([sys.executable, str(ICON_GEN), primary, surface],
                       capture_output=True, check=False)
    except OSError:
        pass


def hook_wallcolors():
    """Refresh the icons whenever wallcolors renders a new palette."""
    if not WALLCOLORS.is_file():
        return
    text = WALLCOLORS.read_text()
    if "# ricelin-thunar-icons\n" in text:
        return
    func = '''# ricelin-thunar-icons
def render_thunar_icons(pill):
    try:
        subprocess.run([sys.executable, str(Path(__file__).with_name("ricelin-thunar-icons.py")),
                        pill["primary"], pill["surface"]], capture_output=True, check=False)
    except OSError:
        pass

# ricelin-thunar-icons-end
'''
    text = text.replace("\ndef publish(", "\n\n" + func + "def publish(", 1)
    text = text.replace("    render_kde(pill)\n",
                        "    render_kde(pill)\n    render_thunar_icons(pill)\n", 1)
    save(WALLCOLORS, text)


def unhook_wallcolors():
    if not WALLCOLORS.is_file():
        return
    text = WALLCOLORS.read_text()
    start = text.find("# ricelin-thunar-icons\n")
    end = text.find("# ricelin-thunar-icons-end\n", start)
    if start != -1 and end != -1:
        end += len("# ricelin-thunar-icons-end\n")
        text = text[:start] + text[end:]
        text = text.replace("    render_kde(pill)\n    render_thunar_icons(pill)\n",
                            "    render_kde(pill)\n")
        save(WALLCOLORS, text)


def apply():
    quit_thunar()
    state = capture()

    for prop, (kind, value) in XFCONF.items():
        if value is None:
            xf_reset(prop)
        else:
            xf_set(prop, kind, value)
    for key, value in GSETTINGS.items():
        gset(key, value)
    GTK3.mkdir(parents=True, exist_ok=True)
    if BOOKMARKS.is_file():
        BOOKMARKS.unlink()
    save(GTK_CSS, CSS)
    disable_gvfs_network()
    render_icons()
    hook_wallcolors()
    update_ini()
    set_default_file_manager()
    bind_changed = set_super_e("thunar")
    if bind_changed and shutil.which("hyprctl"):
        subprocess.run(["hyprctl", "reload"], capture_output=True)

    print("Thunar is the folder handler and SUPER + E opens it.")
    print("Sidebar: Places = Computer + Home, all devices, no Network section.")
    print("New Thunar windows use a headerbar; open one to see it.")
    print(f"State saved to {STATE_FILE}")


def revert():
    if not STATE_FILE.is_file():
        print("Nothing to revert: no state file at " + str(STATE_FILE), file=sys.stderr)
        sys.exit(1)
    state = json.loads(STATE_FILE.read_text())

    for prop, original in state.get("xfconf", {}).items():
        if original is None:
            xf_reset(prop)
        else:
            xf_set(prop, XFCONF[prop][0], original)
    for key, original in state.get("gsettings", {}).items():
        if original is not None:
            gset(key, original)
    if state.get("bookmarks") is None:
        if BOOKMARKS.is_file():
            BOOKMARKS.unlink()
    else:
        save(BOOKMARKS, state["bookmarks"])
    restore_gvfs_network(state)
    if state.get("mime_default"):
        set_default_file_manager(state["mime_default"])
    if state.get("super_e"):
        idx, _ = super_e_line()
        if idx is not None:
            lines = BINDS.read_text().splitlines()
            lines[idx] = state["super_e"]
            save(BINDS, "\n".join(lines) + "\n")
            if shutil.which("hyprctl"):
                subprocess.run(["hyprctl", "reload"], capture_output=True)

    if state.get("gtk_css") is None:
        if GTK_CSS.is_file() and GTK_CSS.read_text().startswith(MARK):
            GTK_CSS.unlink()
    else:
        save(GTK_CSS, state["gtk_css"])

    if state.get("settings_ini") is None:
        if INI_BAK.is_file():
            INI_BAK.unlink()
    else:
        save(SETTINGS_INI, state["settings_ini"])
        if INI_BAK.is_file():
            INI_BAK.unlink()

    unhook_wallcolors()
    shutil.rmtree(ICON_DIR, ignore_errors=True)
    if ICON_GEN.is_file():
        ICON_GEN.unlink()
    quit_thunar()
    STATE_FILE.unlink()
    print("Thunar settings, sidebar, bookmarks, GTK css, font, folder handler and SUPER + E restored.")


arg = sys.argv[1] if len(sys.argv) > 1 else "apply"
if arg in ("--revert", "-r", "revert"):
    revert()
else:
    apply()
PY
)

# ---------------------------------------------------------------- stage_nightlight_cursor
stage_nightlight_cursor() (
# Make the night light tint the cursor too.
#
# Night light is hyprsunset, which applies a colour transform (CTM) to the
# display output. Hyprland draws the cursor on its own hardware plane, and the
# transform does not reach that plane, so the pointer stayed cool while the rest
# of the screen warmed up. Rendering the cursor in the scene instead puts it
# through the same transform.
#
# That is `cursor:no_hardware_cursors = 1` in ~/.config/hypr/modules/input.lua,
# where 1 forces software cursors and 2 is the default "auto".
#
# `installer stage --revert` removes the setting and restores the default.

set -eu

INPUT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/modules/input.lua"

[ -f "$INPUT" ] || { echo "input.lua not found at $INPUT" >&2; exit 1; }

python3 - "$INPUT" "${1:-apply}" <<'PY'
import os
import sys

path, mode = sys.argv[1], sys.argv[2]
text = open(path).read()


def save(content):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, path)

anchor = '    binds = {\n        scroll_event_delay = 40,\n    },\n})'
block = ('    binds = {\n        scroll_event_delay = 40,\n    },\n'
         '    -- Render the cursor in the scene instead of a hardware plane, so the\n'
         '    -- hyprsunset colour transform reaches it like everything else.\n'
         '    cursor = {\n        no_hardware_cursors = 1,\n    },\n})')

if mode in ("--revert", "-r", "revert"):
    if block in text:
        save(text.replace(block, anchor, 1))
        print("night-light cursor fix removed")
    elif "no_hardware_cursors" in text:
        sys.stderr.write("input.lua has a no_hardware_cursors setting that is not mine; leaving it\n")
    else:
        print("nothing to revert")
else:
    if "no_hardware_cursors" in text:
        print("already applied")
    elif anchor not in text:
        sys.stderr.write("input.lua: anchor not found, skipped\n")
        sys.exit(1)
    else:
        save(text.replace(anchor, block, 1))
        print("night-light cursor fix applied")
PY

if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
fi
)

# ---------------------------------------------------------------- stage_wallpaper_tone
stage_wallpaper_tone() (
# Wallpaper tone: Auto / Light / Dark in Settings > Appearance > Palette, remembered
# per wallpaper.
#
# The dynamic (wallpaper) palette always derived light-or-dark from the image's
# mean lightness. This adds a Tone control on top of that:
#
#   Auto   the existing derivation (mean lightness >= 0.40 is light)
#   Light  forces the light branch, i.e. exactly what Auto produces for a light
#          wallpaper -- the same colours, not a recomputed scheme
#   Dark   the mirror
#
# The choice is remembered for each wallpaper in
# ~/.local/state/ricelin/wallpaper-tone.json (path -> light|dark; Auto is the
# absence of an entry). Switching back to a wallpaper restores its pick; a
# wallpaper never seen before is Auto.
#
# How it hangs together: wallcolors.py records the live flag into the store every
# time it renders a wallpaper, and wallpaper.sh loads the store for the new
# picture before it renders. Picking a tone in Settings changes the flag, which
# re-runs wallcolors (through the pill), which records the store for the current
# wallpaper.
#
# It also prunes wallpaper memory: neither the tone store nor the analysis cache
# (~/.cache/ricelin/analyze-v2.json) keeps entries for wallpapers that have been
# deleted, so neither grows without bound.
#
# Everything downstream (GTK prefer-light/dark, the Ricelin-a/b theme swap, Zen,
# the terminal accents and fastfetch) already reads the resulting surface, so
# forcing the branch is the whole engine change.
#
# `installer stage --revert` removes the store, the flag and every edit.

set -eu

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
WC="$CFG/hypr/scripts/wallcolors.py"
WP="$CFG/hypr/scripts/wallpaper.sh"
FLAGS="$CFG/quickshell/pill/Singletons/Flags.qml"
DEFAULTS="$CFG/quickshell/pill/App/PillDefaults.js"
PAGE="$CFG/quickshell/pill/App/PageAppearance.qml"
PALETTE="$CFG/quickshell/pill/App/PillPalette.qml"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
FLAGSJSON="$STATE/flags.json"
TONESTORE="$STATE/wallpaper-tone.json"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ricelin"
ANALYZE="$CACHE/analyze-v2.json"
RESTART="$CFG/hypr/scripts/ricelin"

for f in "$WC" "$WP" "$FLAGS" "$DEFAULTS" "$PAGE" "$PALETTE"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

case "${1:-apply}" in
    --revert|-r|revert) MODE=revert ;;
    *)                  MODE=apply ;;
esac

result=$(python3 - "$MODE" "$WC" "$WP" "$FLAGS" "$DEFAULTS" "$PAGE" "$PALETTE" <<'PY'
import os
import sys

mode, wc, wp, flags, defaults, page, palette = sys.argv[1:8]
changed = False
original = {}
pending = {}


def edit(path, old, new, label, guard):
    """Stage one exact block replacement; nothing reaches disk until commit().

    Staging is what makes the run all-or-nothing: a missing anchor on the fifth
    edit aborts before the first file is touched, instead of leaving a half
    patched tree behind."""
    global changed
    text = pending.get(path)
    if text is None:
        text = open(path, encoding="utf-8").read()
        original[path] = text
        pending[path] = text
    if guard in text:
        print(f"skip:  {label} (already applied)")
        return
    if old not in text:
        sys.exit(f"anchor not found in {path}: {label}")
    pending[path] = text.replace(old, new, 1)
    changed = True
    print(f"{mode}: {label}")


def commit():
    for path, text in pending.items():
        if text == original.get(path):
            continue
        tmp = path + ".09.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)



# --- wallcolors.py -----------------------------------------------------------
WC_HELPER = '''# ricelin-wallpaper-tone
TONE_STORE = STATE / "wallpaper-tone.json"


def palette_tone():
    return flags().get("paletteTone", "auto")


def palette_light():
    """None lets the wallpaper choose light/dark; True/False pins it from Settings."""
    tone = palette_tone()
    return None if tone == "auto" else tone == "light"


def remember_tone(key, tone):
    """Per-wallpaper memory of the pick; Auto is the absence of an entry. Entries for wallpapers that no longer exist are pruned."""
    if not key:
        return
    try:
        store = json.loads(TONE_STORE.read_text())
        if not isinstance(store, dict):
            store = {}
    except (OSError, ValueError):
        store = {}
    store = {k: v for k, v in store.items() if os.path.isfile(k)}
    if tone in ("light", "dark"):
        store[key] = tone
    else:
        store.pop(key, None)
    tmp = TONE_STORE.with_name(TONE_STORE.name + ".tmp")
    if store:
        tmp.write_text(json.dumps(store, indent=2, sort_keys=True))
        tmp.replace(TONE_STORE)
    else:
        TONE_STORE.unlink(missing_ok=True)
'''

WC_ANCHOR = '''def palette_mode():
    return os.environ.get("RICELIN_PALETTE") or flags().get("paletteMode", "static")
'''

WC_MAIN_OLD = '''    feat = cached_analyze(wallpaper) or NEUTRAL
    return publish(palette(feat, vibrancy=vibrancy()), seed(feat))
'''
WC_MAIN_NEW = '''    feat = cached_analyze(wallpaper) or NEUTRAL
    # ricelin-wallpaper-tone
    key = sys.argv[2] if len(sys.argv) > 2 else wallpaper
    remember_tone(key, palette_tone())
    return publish(palette(feat, palette_light(), vibrancy=vibrancy()), seed(feat))
'''

WC_CACHE_OLD = '''    result = analyze(wallpaper)
    if result:
        seen[wallpaper] = {"v": ANALYZE_VERSION, "mtime": mtime, "features": result}
'''
WC_CACHE_NEW = '''    result = analyze(wallpaper)
    if result:
        # ricelin-wallpaper-tone: drop analyses of wallpapers that are gone.
        seen = {k: v for k, v in seen.items() if os.path.isfile(k)}
        seen[wallpaper] = {"v": ANALYZE_VERSION, "mtime": mtime, "features": result}
'''

if mode == "apply":
    edit(wc, WC_ANCHOR, WC_ANCHOR + "\n" + WC_HELPER, "wallcolors.py helper", "def remember_tone")
    edit(wc, WC_MAIN_OLD, WC_MAIN_NEW, "wallcolors.py call", "remember_tone(key, palette_tone())")
    edit(wc, WC_CACHE_OLD, WC_CACHE_NEW, "wallcolors.py cache prune", "seen.items() if os.path.isfile(k)")
else:
    edit(wc, "\n" + WC_HELPER, "", "wallcolors.py helper", "@@never@@")
    edit(wc, WC_MAIN_NEW, WC_MAIN_OLD, "wallcolors.py call", "@@never@@")
    edit(wc, WC_CACHE_NEW, WC_CACHE_OLD, "wallcolors.py cache prune", "@@never@@")

# --- wallpaper.sh ------------------------------------------------------------
WP_VAR_OLD = '''STILL="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-wallpaper-still.png"
'''
WP_VAR_NEW = WP_VAR_OLD + '''TONE_STORE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin/wallpaper-tone.json"
'''

WP_BLOCK_OLD = """    mkdir -p "$(dirname "$STATE")"
    printf '%s\\n' "$pic" > "$STATE"
    pmode=$(jq -r '.paletteMode // "static"' "$flags_file" 2>/dev/null || echo static)
"""
WP_BLOCK_NEW = """    mkdir -p "$(dirname "$STATE")"
    printf '%s\\n' "$pic" > "$STATE"

    # ricelin-wallpaper-tone: each wallpaper remembers its own Auto/Light/Dark
    # pick, so load it before rendering. wallcolors writes the store from the live
    # flag, so reading the store first keeps this picture's value.
    tone=$(jq -r --arg p "$pic" '.[$p] // "auto"' "$TONE_STORE" 2>/dev/null || echo auto)
    [ -n "$tone" ] || tone=auto
    if jq --indent 4 --arg t "$tone" '.paletteTone = $t' "$flags_file" > "$flags_file.tmp" 2>/dev/null; then
        mv "$flags_file.tmp" "$flags_file"
    else
        rm -f "$flags_file.tmp"
    fi
    pmode=$(jq -r '.paletteMode // "static"' "$flags_file" 2>/dev/null || echo static)
"""

WP_CMD_OLD = '''        python3 "$(dirname "$0")/wallcolors.py" "$show" >>"$WLOG" 2>&1 || true
'''
WP_CMD_NEW = '''        python3 "$(dirname "$0")/wallcolors.py" "$show" "$pic" >>"$WLOG" 2>&1 || true
'''

if mode == "apply":
    edit(wp, WP_VAR_OLD, WP_VAR_NEW, "wallpaper.sh store var", "TONE_STORE=")
    edit(wp, WP_BLOCK_OLD, WP_BLOCK_NEW, "wallpaper.sh load store", "ricelin-wallpaper-tone")
    edit(wp, WP_CMD_OLD, WP_CMD_NEW, "wallpaper.sh tone key", '"$show" "$pic"')
else:
    edit(wp, WP_VAR_NEW, WP_VAR_OLD, "wallpaper.sh store var", "@@never@@")
    edit(wp, WP_BLOCK_NEW, WP_BLOCK_OLD, "wallpaper.sh load store", "@@never@@")
    edit(wp, WP_CMD_NEW, WP_CMD_OLD, "wallpaper.sh tone key", "@@never@@")

# --- Flags.qml ---------------------------------------------------------------
FL_ALIAS_OLD = '''    property alias paletteMode: adapter.paletteMode
'''
FL_ALIAS_NEW = FL_ALIAS_OLD + '''    property alias paletteTone: adapter.paletteTone
'''

FL_PROP_OLD = '''            property string paletteMode: "static"
'''
FL_PROP_NEW = FL_PROP_OLD + '''            /** Auto follows the wallpaper; each wallpaper remembers its own Light or Dark pick. */
            property string paletteTone: "auto"
'''

if mode == "apply":
    edit(flags, FL_ALIAS_OLD, FL_ALIAS_NEW, "Flags.qml alias", "alias paletteTone")
    edit(flags, FL_PROP_OLD, FL_PROP_NEW, "Flags.qml property", 'property string paletteTone')
else:
    edit(flags, FL_ALIAS_NEW, FL_ALIAS_OLD, "Flags.qml alias", "@@never@@")
    edit(flags, FL_PROP_NEW, FL_PROP_OLD, "Flags.qml property", "@@never@@")

# --- PillDefaults.js ---------------------------------------------------------
DF_DEFAULT_OLD = '''    paletteMode: "static",
'''
DF_DEFAULT_NEW = DF_DEFAULT_OLD + '''    paletteTone: "auto",
'''

DF_APPEAR_OLD = '''var appearanceKeys = ["paletteMode", '''
DF_APPEAR_NEW = '''var appearanceKeys = ["paletteMode", "paletteTone", '''

DF_PRESET_OLD = '''var presetKeys = pillKeys.concat(["paletteMode", '''
DF_PRESET_NEW = '''var presetKeys = pillKeys.concat(["paletteMode", "paletteTone", '''

if mode == "apply":
    edit(defaults, DF_DEFAULT_OLD, DF_DEFAULT_NEW, "PillDefaults.js default", 'paletteTone: "auto"')
    edit(defaults, DF_APPEAR_OLD, DF_APPEAR_NEW, "PillDefaults.js appearanceKeys", 'var appearanceKeys = ["paletteMode", "paletteTone"')
    edit(defaults, DF_PRESET_OLD, DF_PRESET_NEW, "PillDefaults.js presetKeys", 'var presetKeys = pillKeys.concat(["paletteMode", "paletteTone"')
else:
    edit(defaults, DF_DEFAULT_NEW, DF_DEFAULT_OLD, "PillDefaults.js default", "@@never@@")
    edit(defaults, DF_APPEAR_NEW, DF_APPEAR_OLD, "PillDefaults.js appearanceKeys", "@@never@@")
    edit(defaults, DF_PRESET_NEW, DF_PRESET_OLD, "PillDefaults.js presetKeys", "@@never@@")

# --- PageAppearance.qml ------------------------------------------------------
PAGE_OLD = '''                value: Flags.paletteMode
                onPicked: (v) => Flags.paletteMode = v
            }
        }
'''
PAGE_NEW = PAGE_OLD + '''
        AppRow {
            visible: page.dynamic
            label: "Tone"
            sub: "Saved for each wallpaper; Auto follows it"
            key: "app.wallpaperTone"

            AppSeg {
                s: page.s
                options: [{ label: "Auto", value: "auto" }, { label: "Light", value: "light" }, { label: "Dark", value: "dark" }]
                value: Flags.paletteTone
                onPicked: (v) => Flags.paletteTone = v
            }
        }
'''

if mode == "apply":
    edit(page, PAGE_OLD, PAGE_NEW, "PageAppearance.qml row", 'key: "app.wallpaperTone"')
else:
    edit(page, PAGE_NEW, PAGE_OLD, "PageAppearance.qml row", "@@never@@")

# --- PillPalette.qml ---------------------------------------------------------
PAL_WALL_OLD = """    readonly property string wallpaper: 'f="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-wallpaper"; pic=$(cat "$f" 2>/dev/null); case "$pic" in *.[Mm][Pp]4|*.[Ww][Ee][Bb][Mm]|*.[Mm][Kk][Vv]|*.[Mm][Oo][Vv]) pic="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-wallpaper-still.png";; esac; '
"""
PAL_WALL_NEW = """    readonly property string wallpaper: 'f="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-wallpaper"; real=$(cat "$f" 2>/dev/null); pic="$real"; case "$pic" in *.[Mm][Pp]4|*.[Ww][Ee][Bb][Mm]|*.[Mm][Kk][Vv]|*.[Mm][Oo][Vv]) pic="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin-wallpaper-still.png";; esac; '
"""

PAL_CMD_OLD = """                Quickshell.execDetached(["sh", "-c", gate + wallpaper + '[ -f "$pic" ] && ' + wc + ' "$pic" >/dev/null 2>&1; ' + ghostty,
                    "sh", "pal", mode]);
"""
PAL_CMD_NEW = """                Quickshell.execDetached(["sh", "-c", gate + wallpaper + '[ -f "$pic" ] && ' + wc + ' "$pic" "$real" >/dev/null 2>&1; ' + ghostty,
                    "sh", "pal", mode]);
"""

PAL_HANDLER_OLD = '''        function onPaletteVibrancyChanged() {
            if (Flags.paletteMode === "dynamic")
                root.schedulePalette();
        }
'''
PAL_HANDLER_NEW = PAL_HANDLER_OLD + '''
        function onPaletteToneChanged() {
            if (Flags.paletteMode === "dynamic")
                root.schedulePalette();
        }
'''

if mode == "apply":
    edit(palette, PAL_WALL_OLD, PAL_WALL_NEW, "PillPalette.qml wallpaper key", 'real=$(cat "$f"')
    edit(palette, PAL_CMD_OLD, PAL_CMD_NEW, "PillPalette.qml tone key", '"$pic" "$real"')
    edit(palette, PAL_HANDLER_OLD, PAL_HANDLER_NEW, "PillPalette.qml handler", "onPaletteToneChanged")
else:
    edit(palette, PAL_WALL_NEW, PAL_WALL_OLD, "PillPalette.qml wallpaper key", "@@never@@")
    edit(palette, PAL_CMD_NEW, PAL_CMD_OLD, "PillPalette.qml tone key", "@@never@@")
    edit(palette, PAL_HANDLER_NEW, PAL_HANDLER_OLD, "PillPalette.qml handler", "@@never@@")

commit()
print("__CHANGED__ " + ("1" if changed else "0"))
PY
)

printf '%s\n' "$result" | grep -v '^__CHANGED__' || true

# Keep flags.json in its own format (jq, UTF-8); only touch it when needed.
flag_changed=0
if [ -f "$FLAGSJSON" ]; then
    if [ "$MODE" = apply ] && ! jq -e 'has("paletteTone")' "$FLAGSJSON" >/dev/null 2>&1; then
        if jq --indent 4 '.paletteTone = "auto"' "$FLAGSJSON" > "$FLAGSJSON.tmp" 2>/dev/null; then
            mv "$FLAGSJSON.tmp" "$FLAGSJSON"; flag_changed=1
            echo "apply: flags.json paletteTone=auto"
        else
            rm -f "$FLAGSJSON.tmp"
        fi
    elif [ "$MODE" = revert ] && jq -e 'has("paletteTone")' "$FLAGSJSON" >/dev/null 2>&1; then
        if jq --indent 4 'del(.paletteTone)' "$FLAGSJSON" > "$FLAGSJSON.tmp" 2>/dev/null; then
            mv "$FLAGSJSON.tmp" "$FLAGSJSON"; flag_changed=1
            echo "revert: flags.json paletteTone removed"
        else
            rm -f "$FLAGSJSON.tmp"
        fi
    fi
fi

if [ "$MODE" = revert ]; then
    rm -f "$TONESTORE"
fi

# Clear analyses of wallpapers that are already gone; the wallcolors.py patch
# keeps the cache trimmed from here on.
if [ "$MODE" = apply ] && [ -f "$ANALYZE" ]; then
    python3 - "$ANALYZE" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    data = json.load(open(p))
except (OSError, ValueError):
    sys.exit(0)
if isinstance(data, dict):
    keep = {k: v for k, v in data.items() if os.path.isfile(k)}
    if keep != data:
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(keep, fh)
        os.replace(tmp, p)
        print(f"apply: analyze cache trimmed {len(data) - len(keep)} stale entries")
PY
fi

if printf '%s\n' "$result" | grep -q '^__CHANGED__ 1$' || [ "$flag_changed" = 1 ]; then
    # The pill singletons are loaded at start-up, so the new control needs a restart.
    # Ask the IPC socket, not pgrep: the running process is `/usr/bin/quickshell`.
    if [ -x "$RESTART" ] && qs -c pill ipc show >/dev/null 2>&1; then
        "$RESTART" restart pill >/dev/null 2>&1 || true
    fi
    if [ "$MODE" = apply ]; then
        echo "Wallpaper tone control installed."
    else
        echo "Wallpaper tone control removed."
    fi
else
    echo "Nothing to do."
fi
)

# ---------------------------------------------------------------- stage_settings_zoom
stage_settings_zoom() (
# Make Ricelin Settings (SUPER + I) read at the same size as the rest of the
# desktop.
#
# Every size in the Settings window -- text, spacing and the window itself -- is
# multiplied by Flags.appZoom, which ships at 0.85. That is 15% smaller than the
# pill and the GTK apps (Inter 10), so the Settings looked undersized next to
# everything else. This sets it to 1, the size the layout is designed at.
#
# Both the live flag and the two source defaults are updated: a reset or a
# `ricelin update` that restores Flags.qml keeps the Settings at 1.0.
#
# The window stays adjustable in-app: Ctrl + wheel, or Ctrl + -/+/0.
#
# `installer stage --revert` puts it back to the shipped 0.85 in both
# places. Set SETTINGS_ZOOM to another value to apply that instead.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
FLAGSJSON="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin/flags.json"
FLAGS_QML="$CONFIG/quickshell/pill/Singletons/Flags.qml"
APPWINDOW="$CONFIG/quickshell/pill/App/AppWindow.qml"
SHIPPED=0.85

[ -f "$FLAGSJSON" ] || { echo "No flags file at $FLAGSJSON" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

case "${1:-apply}" in
    --revert|-r|revert) zoom="$SHIPPED" ;;
    *)                  zoom="${SETTINGS_ZOOM:-1}" ;;
esac

case "$zoom" in
    ''|*[!0-9.]*) echo "Not a number: $zoom" >&2; exit 1 ;;
esac

# The live value is what this session uses.
old=$(jq -r '.appZoom // empty' "$FLAGSJSON")
if [ "$old" != "$zoom" ]; then
    jq --indent 4 --argjson z "$zoom" '.appZoom = $z' "$FLAGSJSON" > "$FLAGSJSON.tmp" && mv "$FLAGSJSON.tmp" "$FLAGSJSON"
    echo "Settings zoom set to $zoom (was ${old:-unset})."
else
    echo "Settings zoom is already $zoom."
fi

# The source value is what the next fresh flag store starts from. The patterns
# match only the two declarations this script owns.
python3 - "$FLAGS_QML" "$APPWINDOW" "$zoom" <<'PY'
import os
import re
import sys

flags, appwindow, zoom = sys.argv[1], sys.argv[2], sys.argv[3]
patterns = [
    (flags, r"(property real appZoom:\s*)[0-9.]+", r"\g<1>" + zoom),
    (appwindow, r"(Flags\.appZoom > 0 \? Flags\.appZoom :\s*)[0-9.]+", r"\g<1>" + zoom),
]
changed = []
for path, pattern, repl in patterns:
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        print(f"warning: {path} is missing; only the live flag changed", file=sys.stderr)
        continue
    out, n = re.subn(pattern, repl, text, count=1)
    if n and out != text:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(out)
        os.replace(tmp, path)
        changed.append(path)
if changed:
    print("Source defaults updated: " + ", ".join(changed))
PY
)

# ---------------------------------------------------------------- stage_atomic_theme_write
stage_atomic_theme_write() (
# Make the app-theme writes atomic so a tone change cannot leave GTK apps "stock".
#
# wallcolors.py rewrites the Ricelin-a / Ricelin-b stylesheets in place and then
# flips the GTK theme name to make running apps reload. An in-place
# `path.write_text()` truncates the file before writing, so an app that reloads
# during that window reads an empty or half-written stylesheet. GTK then falls
# back to the default Adwaita look (a plain grey, stock-looking Thunar) and
# caches that result until the app is restarted.
#
# This replaces the write with a temp file plus `os.replace`, which is atomic:
# readers see either the old complete file or the new complete file, never a
# partial one.
#
# Usage:
#   sh installer stage            patch wallcolors.py
#   sh installer stage --revert   restore the in-place write

set -eu
PY=/usr/bin/python3
SCRIPT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/wallcolors.py"

[ -f "$SCRIPT" ] || { echo "wallcolors.py not found at $SCRIPT" >&2; exit 1; }

"$PY" - "$SCRIPT" "${1:-apply}" <<'PY'
import os
import sys

path, mode = sys.argv[1], sys.argv[2]
src = open(path).read()


def save(text):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)

OLD = """    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return True
"""

NEW = """    path.parent.mkdir(parents=True, exist_ok=True)
    # ricelin-atomic-theme-write: running apps reload this file the moment the
    # theme name flips, so never let them read a truncated file.
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)
    return True
"""

MARK = "ricelin-atomic-theme-write"

if mode in ("--revert", "-r", "revert"):
    if MARK not in src:
        print("Already in-place; nothing to revert.")
        sys.exit(0)
    src = src.replace(NEW, OLD)
    save(src)
    print("Restored the in-place write.")
    sys.exit(0)

if MARK in src:
    print("Already atomic; nothing to do.")
    sys.exit(0)
if OLD not in src:
    print("Could not find the write_if_changed body; wallcolors.py changed.", file=sys.stderr)
    sys.exit(1)
if "\nimport os" not in src and "\nimport os," not in src:
    print("os is not imported in wallcolors.py; refusing to patch.", file=sys.stderr)
    sys.exit(1)
save(src.replace(OLD, NEW))
print("Patched write_if_changed to write atomically.")
PY

"$PY" -m py_compile "$SCRIPT" && echo "wallcolors.py compiles."
rm -f "$(dirname "$SCRIPT")/__pycache__/wallcolors."*.pyc
rmdir "$(dirname "$SCRIPT")/__pycache__" 2>/dev/null || true
rm -f "$(dirname "$SCRIPT")"/wallcolors.py.tmp 2>/dev/null || true
)

# ---------------------------------------------------------------- stage_pretty_menus
stage_pretty_menus() (
# Make right-click menus look like the rest of the desktop.
#
# Three separate things made menus feel foreign:
#
#   1. Hyprland's popup blur was off. App windows are glassy (90% opaque), so a
#      menu popup was a see-through box with no frost behind it. Turning on
#      `decoration:blur:popups` blurs the surface underneath the menu.
#   2. GTK3 and GTK4 both carried a stale `gtk-theme-name=Arc-Dark` pin in their
#      settings.ini. XSettings usually wins, but the pin still overrides
#      gsettings in apps that read only settings.ini, so they could fall back to
#      stock colours. It is removed from both so they follow the live Ricelin
#      theme. The menu/popover rules are also applied to GTK4.
#   3. The document font was "Adwaita Sans 12" while the UI font is Inter 10, so
#      text that resolves through the document font did not match.
#
# GTK3 menu styling still comes from installer stage; this script only
# removes the stale GTK3 theme pin.
#
# Usage:
#   sh installer stage            apply
#   sh installer stage --revert   restore the previous state

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
DECOR="$CONFIG/hypr/modules/decoration.lua"
GTK4="$CONFIG/gtk-4.0"
GTK4_CSS="$GTK4/gtk.css"
GTK4_INI="$GTK4/settings.ini"
GTK3="$CONFIG/gtk-3.0"
GTK3_INI="$GTK3/settings.ini"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin/pretty-menus.json"
MARK="/* ricelin-menus */"

CSS_BLOCK=$(cat <<CSS

$MARK
/* Solid menus in GTK4: same surface, radius and font as GTK3. The fill stays
 * opaque so a translucent window never shows page content through a menu. */
popover.background,
popover.menu,
popover,
menu {
    background-color: @window_bg_color;
    color: @view_fg_color;
    border: 1px solid alpha(@view_fg_color, 0.12);
    border-radius: 12px;
    padding: 3px;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.32);
    font-family: "Inter";
    font-size: 10pt;
}
popover.menu modelbutton,
popover modelbutton,
modelbutton,
menuitem {
    font-family: "Inter";
    font-size: 10pt;
    color: @view_fg_color;
    border-radius: 6px;
    padding: 4px 8px;
    min-height: 20px;
}
popover.menu modelbutton:hover,
popover modelbutton:hover,
modelbutton:hover,
menuitem:hover {
    background-color: alpha(@accent_bg_color, 0.18);
    color: @view_fg_color;
}
CSS
)

mkdir -p "$GTK4" "$GTK3" "$(dirname "$STATE")"

save_state() {
    py=$(command -v python3 || true)
    [ -n "$py" ] || return 0
    "$py" - "$STATE" "$GTK4_INI" "$GTK3_INI" <<'PY'
import json, os, sys, subprocess
state_file, gtk4_ini, gtk3_ini = sys.argv[1], sys.argv[2], sys.argv[3]
state = {}
if os.path.exists(state_file):
    try:
        state = json.load(open(state_file))
    except (OSError, ValueError):
        state = {}
if not isinstance(state, dict):
    state = {}
doc = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "document-font-name"],
                     capture_output=True, text=True).stdout.strip().strip("'")
if doc:
    state.setdefault("document_font", doc)
# Backfill the GTK3 backup on installations where an older run saved only GTK4.
for key, ini in (("gtk4_ini", gtk4_ini), ("gtk3_ini", gtk3_ini)):
    if key not in state:
        try:
            state[key] = open(ini).read()
        except OSError:
            state[key] = None
tmp = state_file + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, state_file)
PY
}

apply_lua() {
    py=$(command -v python3 || true)
    [ -n "$py" ] || { echo "python3 is required." >&2; exit 1; }
    "$py" - "$DECOR" <<'PY'
import os, re, sys
path = sys.argv[1]
src = open(path).read()
if "popups" in src:
    src = re.sub(r"(\n\s*)popups\s*=\s*false", r"\1popups = true", src)
    if "popups = true" not in src:
        # "popups" appears somewhere, but not as the key this script sets: refuse
        # rather than report success without doing anything.
        sys.exit("decoration.lua mentions popups but not as a false/true blur key")
else:
    m = re.search(r"(blur\s*=\s*\{)", src)
    if not m:
        sys.exit("could not find the blur block in decoration.lua")
    src = src[:m.end()] + "\n        popups = true," + src[m.end():]
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(src)
os.replace(tmp, path)
PY
}

apply_gtk4() {
    py=$(command -v python3 || true)
    "$py" - "$GTK4_CSS" "$MARK" "$CSS_BLOCK" <<'PY'
import os, sys
path, mark, block = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path).read()
except OSError:
    text = ""
body = block.strip("\n")
head = text.split(mark)[0].rstrip() if mark in text else text.rstrip()
out = (head + "\n\n" if head else "") + body + "\n"
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(out)
os.replace(tmp, path)
PY
}

apply_ini() {
    py=$(command -v python3 || true)
    [ -n "$py" ] || return 0
    for ini in "$GTK4_INI" "$GTK3_INI"; do
        [ -f "$ini" ] || continue
        "$py" - "$ini" <<'PY'
import os, sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if not l.strip().startswith("gtk-theme-name=")]
out = "\n".join(lines).strip()
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(out + "\n" if out else "")
os.replace(tmp, path)
PY
    done
}

if [ "${1:-apply}" = "--revert" ] || [ "${1:-}" = "-r" ] || [ "${1:-}" = "revert" ]; then
    py=$(command -v python3 || true)
    [ -n "$py" ] || { echo "python3 is required." >&2; exit 1; }
    "$py" - "$DECOR" <<'PY'
import os, sys
path = sys.argv[1]
src = open(path).read().replace("        popups = true,\n", "")
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(src)
os.replace(tmp, path)
PY
    "$py" - "$GTK4_CSS" "$MARK" <<'PY'
import os, sys
path, mark = sys.argv[1], sys.argv[2]
try:
    text = open(path).read()
except OSError:
    sys.exit(0)
if mark in text:
    head = text.split(mark)[0].rstrip()
    if head:
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(head + "\n")
        os.replace(tmp, path)
    else:
        # It held nothing but this block, so removing the block removes the file.
        os.unlink(path)
PY
    if [ -f "$STATE" ]; then
        "$py" - "$STATE" "$GTK4_INI" "$GTK3_INI" <<'PY'
import json, os, subprocess, sys
state = json.load(open(sys.argv[1]))
doc = state.get("document_font")
if doc:
    subprocess.run(["gsettings", "set", "org.gnome.desktop.interface", "document-font-name", doc])
for key, ini in (("gtk4_ini", sys.argv[2]), ("gtk3_ini", sys.argv[3])):
    old = state.get(key)
    if old is not None:
        tmp = ini + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(old)
        os.replace(tmp, ini)
PY
        rm -f "$STATE"
    fi
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
    echo "Reverted: popup blur off, GTK4 menu rules removed, GTK theme pins and font restored."
    exit 0
fi

save_state
apply_lua
apply_gtk4
apply_ini
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.interface document-font-name "Inter 10" >/dev/null 2>&1 || true
fi
if command -v hyprctl >/dev/null 2>&1; then
    # Hyprland 0.57's Lua config has no `keyword` request; decoration.lua above
    # is the source of truth and reload applies it.
    hyprctl reload >/dev/null 2>&1 || true
fi

echo "Menus: popup blur on, GTK3/GTK4 follow the palette, document font is Inter."
)

# ---------------------------------------------------------------- stage_app_glass
stage_app_glass() (
# App transparency ("Glass"): every window gets the compositor's transparency and
# blur, with a list of window classes that stay solid.
#
# The feature is three moving parts:
#
#   ~/.config/quickshell/pill/Singletons/Glass.qml
#       Renders the rules Hyprland reads into
#       ~/.cache/ricelin/window-opacity.lua. It watches the three flags, debounces
#       a burst, writes the file atomically and reloads Hyprland once.
#
#   ~/.config/hypr/modules/window_rules.lua
#       Reads that file at start-up and turns it into one blanket opacity rule
#       plus one rule per exception class. The cache file is the interface because
#       a Lua config cannot read JSON.
#
#   Settings > Windows > Transparency
#       The on/off switch, the opacity slider and the exception list.
#
# The AppGroup in PageWindows also disables the older "Opacity" group while the
# feature is on: those two sliders write decoration.lua, and a window rule always
# wins over a decoration default, so leaving them live would mean two controls for
# one value with only one of them doing anything.
#
# `--revert` removes all of it and puts the Opacity group back in charge.
# Applying twice is a no-op.

set -eu

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
QML="$CFG/quickshell/pill"
HYPR="$CFG/hypr/modules"
GHOSTTY="$CFG/ghostty/config"
RESTART="$CFG/hypr/scripts/ricelin"

for f in "$QML/shell.qml" "$QML/Singletons/Flags.qml" "$QML/Singletons/Theme.qml" \
         "$QML/Singletons/qmldir" "$QML/App/AppWindow.qml" "$QML/App/PageWindows.qml" \
         "$QML/App/searchDesktop.js" "$HYPR/window_rules.lua"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

case "${1:-apply}" in
    --revert|-r|revert) MODE=revert ;;
    *)                  MODE=apply ;;
esac

glass_changed=0
if [ "$MODE" = apply ]; then
cat > "$QML/Singletons/Glass.qml.20.tmp" <<'GLASS_EOF'
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Renders the window-opacity rules Hyprland reads, from the App transparency flags.
 * One rule covers every window; the exception classes get a later rule that puts
 * them back to fully opaque, since the last matching rule wins.
 *
 * The cache file is the interface because window_rules.lua cannot read JSON.
 */
Singleton {
    id: root

    readonly property string path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/ricelin/window-opacity.lua"

    function render() {
        const solid = Math.max(0.5, Math.min(1, Number(Flags.glassOpacity) || 0.9));
        const idle = Math.max(0.5, solid - 0.06);
        const list = Flags.glassExcept || [];

        let out = "return {\n";
        out += "    enabled = " + (Flags.glassApps === true && Flags.gameMode !== true ? "true" : "false") + ",\n";
        out += '    opacity = "' + solid.toFixed(2) + " override " + idle.toFixed(2) + ' override",\n';
        out += list.length > 0 ? "    exceptions = {\n" : "    exceptions = {},\n";
        for (let i = 0; i < list.length; i++) {
            const cls = String(list[i]).replace(/["\\]/g, "");
            if (cls.length > 0)
                out += '        "' + cls + '",\n';
        }
        if (list.length > 0)
            out += "    },\n";
        return out + "}\n";
    }

    function push() {
        writer.put(render());
    }

    /** One write and one reload per burst, so dragging the opacity slider is not a reload storm. */
    Timer {
        id: debounce
        interval: 250
        onTriggered: root.push()
    }

    Connections {
        target: Flags
        function onGlassAppsChanged() { debounce.restart() }
        function onGlassOpacityChanged() { debounce.restart() }
        function onGlassExceptChanged() { debounce.restart() }
    }

    FileView {
        id: writer
        path: root.path
        preload: false
        atomicWrites: true
        printErrors: false

        property string queued: ""
        property bool busy: false
        property bool more: false

        function put(t) {
            if (busy) {
                queued = t;
                more = true;
                return;
            }
            busy = true;
            setText(t);
        }

        function settle() {
            busy = false;
            if (more) {
                more = false;
                put(queued);
            } else {
                reloadProc.running = true;
            }
        }

        onSaved: Qt.callLater(settle)
        onSaveFailed: Qt.callLater(settle)
    }

    Process {
        id: reloadProc
        command: ["hyprctl", "reload"]
    }
}
GLASS_EOF
# Written when it differs, not only when absent: the renderer had doubled
# newline escapes, and a tree that already carries the broken file has to heal.
if cmp -s "$QML/Singletons/Glass.qml.20.tmp" "$QML/Singletons/Glass.qml"; then
    rm -f "$QML/Singletons/Glass.qml.20.tmp"
else
    mv "$QML/Singletons/Glass.qml.20.tmp" "$QML/Singletons/Glass.qml"
    glass_changed=1
fi
fi

out=$(python3 - "$MODE" "$QML" "$HYPR" "$GHOSTTY" <<'PY'
import os
import sys

mode, qml_root, hypr_root, ghostty_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
qml, hypr = __import__("pathlib").Path(qml_root), __import__("pathlib").Path(hypr_root)
ghostty = __import__("pathlib").Path(ghostty_path)

page_group = r"""    AppGroup {
        title: "Transparency"
        hint: "App windows frost the desktop behind them"

        AppRow {
            label: "App transparency"
            sub: "Compositor transparency and blur on every app window"
            key: "windows.glassApps"
            clickable: true
            onClicked: glassToggle.flip()
            AppToggle {
                id: glassToggle
                checked: Flags.glassApps
                onToggled: (on) => Flags.glassApps = on
            }
        }
        AppRow {
            label: "Window opacity"
            sub: "How solid an app window is; inactive windows sit slightly under it"
            key: "windows.glassOpacity"
            enabled: Flags.glassApps
            opacity: enabled ? 1 : 0.45
            AppSlider {
                from: 50; to: 100; step: 5; unit: "%"
                value: Math.round(Flags.glassOpacity * 100)
                onMoved: (v) => Flags.glassOpacity = v / 100
            }
        }

        Item {
            width: parent.width
            height: exceptions.implicitHeight

            Column {
                id: exceptions
                width: parent.width
                topPadding: 6 * page.s
                spacing: 2 * page.s

                Text {
                    x: 12 * page.s
                    visible: (Flags.glassExcept || []).length > 0
                    text: "Stay solid"
                    color: Theme.textFaint
                    font.family: Theme.font
                    font.pixelSize: 12 * page.s
                    font.weight: Font.DemiBold
                }

                Repeater {
                    model: Flags.glassExcept || []

                    Rectangle {
                        id: exRow
                        required property var modelData
                        required property int index
                        width: exceptions.width
                        height: 38 * page.s
                        radius: 8 * page.s
                        color: exHover.hovered ? Theme.frameBg : "transparent"

                        Text {
                            x: 12 * page.s
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 60 * page.s
                            text: exRow.modelData
                            color: Theme.subtle
                            elide: Text.ElideRight
                            font.family: "JetBrains Mono"
                            font.pixelSize: 11.5 * page.s
                        }
                        AppButton {
                            anchors.right: parent.right
                            anchors.rightMargin: 8 * page.s
                            anchors.verticalCenter: parent.verticalCenter
                            small: true
                            kind: "ghost"
                            icon: "close"
                            onClicked: page.removeGlassExcept(exRow.index)
                        }
                        HoverHandler { id: exHover }
                    }
                }

                Item {
                    width: parent.width
                    height: 40 * page.s

                    AppField {
                        id: exField
                        x: 12 * page.s
                        anchors.verticalCenter: parent.verticalCenter
                        fieldWidth: 240
                        placeholder: "Window class, e.g. mpv"
                        onAccepted: (t) => {
                            page.addGlassExcept(t);
                            exField.text = "";
                        }
                    }
                    AppButton {
                        anchors.left: exField.right
                        anchors.leftMargin: 8 * page.s
                        anchors.verticalCenter: parent.verticalCenter
                        small: true
                        text: "Add"
                        enabled: exField.text.trim().length > 0
                        onClicked: {
                            page.addGlassExcept(exField.text);
                            exField.text = "";
                        }
                    }
                }
            }
        }
    }

"""
page_funcs = r"""    /** Window classes that skip the app transparency; Glass rewrites the rules and reloads. */
    function addGlassExcept(name) {
        const v = String(name || "").trim();
        if (v.length === 0)
            return;
        const list = (Flags.glassExcept || []).slice();
        if (list.indexOf(v) >= 0)
            return;
        list.push(v);
        Flags.glassExcept = list;
    }

    function removeGlassExcept(index) {
        const list = (Flags.glassExcept || []).slice();
        if (index < 0 || index >= list.length)
            return;
        list.splice(index, 1);
        Flags.glassExcept = list;
    }

"""
flag_aliases = r"""    property alias glassApps: adapter.glassApps
    property alias glassOpacity: adapter.glassOpacity
    property alias glassExcept: adapter.glassExcept
"""
flag_props = r"""            /** Every app window gets the compositor's transparency and blur; the classes in glassExcept stay solid. */
            property bool glassApps: true
            /** Active-window opacity for those app windows; inactive windows sit 0.06 under it. */
            property real glassOpacity: 0.90
            /** Window classes kept fully opaque. Ricelin Settings is a control panel, not app content. */
            property var glassExcept: ["org.quickshell"]
"""
theme_block = r"""    /**
     * App-window surfaces for Ricelin Settings, matching what GTK named colors give
     * every other app: a headerbar-ish top over a view-like body. The card ramp
     * above is deeper than apps use, so the window read as bluer than they are.
     */
    readonly property color winTop:   dyn ? Dyn.surfaceContainerLow : "#2e231b"
    readonly property color winBot:   dyn ? Dyn.surface : "#221813"
"""
rules_block = r"""local home = os.getenv("HOME")

-- App transparency: every window gets the compositor's blur and transparency,
-- then the exception classes are put back to opaque. The cache is written by the
-- pill's Glass singleton, so Settings owns the list. Rules are matched in order
-- and the last match wins, hence the exceptions after the blanket rule.
local ok, glass = pcall(dofile, home .. "/.cache/ricelin/window-opacity.lua")
if ok and type(glass) == "table" and glass.enabled then
    hl.window_rule({
        name    = "app-glass",
        match   = { class = ".*" },
        opacity = glass.opacity,
    })
    for i, cls in ipairs(glass.exceptions or {}) do
        hl.window_rule({
            name    = "app-glass-off-" .. i,
            match   = { class = cls },
            opacity = "1.0 override 1.0 override",
        })
    end
end

"""
search_rows = r"""    { page: "windows", tab: "", group: "Transparency", label: "App transparency", sub: "Compositor transparency and blur on every app window", keywords: "transparency transparent glass blur frosted app windows opaque", key: "windows.glassApps", advanced: false },
    { page: "windows", tab: "", group: "Transparency", label: "Window opacity", sub: "How solid an app window is", keywords: "opacity transparency alpha solid glass app window", key: "windows.glassOpacity", advanced: false },
"""

EDITS = [
    (qml / "Singletons/qmldir",
     'singleton Agents Agents.qml\n',
     'singleton Agents Agents.qml\nsingleton Glass Glass.qml\n'),

    (qml / "Singletons/Flags.qml",
     '    property alias appZoom: adapter.appZoom\n',
     '    property alias appZoom: adapter.appZoom\n' + flag_aliases),

    (qml / "Singletons/Flags.qml",
     '            property real appZoom: 0.85\n',
     '            property real appZoom: 0.85\n' + flag_props),

    (qml / "Singletons/Theme.qml",
     '    readonly property color border:',
     theme_block + '    readonly property color border:'),

    (qml / "App/AppWindow.qml",
     '    color: Theme.cardBot\n',
     '    color: Theme.winBot\n'),

    (qml / "App/AppWindow.qml",
     '    readonly property color barBg: Qt.rgba(Theme.cardTop.r * 0.86 + Theme.cardBot.r * 0.14,\n'
     '                                           Theme.cardTop.g * 0.86 + Theme.cardBot.g * 0.14,\n'
     '                                           Theme.cardTop.b * 0.86 + Theme.cardBot.b * 0.14, 1)\n',
     '    readonly property color barBg: Qt.rgba(Theme.winTop.r * 0.86 + Theme.winBot.r * 0.14,\n'
     '                                           Theme.winTop.g * 0.86 + Theme.winBot.g * 0.14,\n'
     '                                           Theme.winTop.b * 0.86 + Theme.winBot.b * 0.14, 1)\n'),

    (qml / "App/AppWindow.qml",
     '                GradientStop { position: 0.0; color: Theme.cardTop }\n'
     '                GradientStop { position: 1.0; color: Theme.cardBot }\n',
     '                GradientStop { position: 0.0; color: Theme.winTop }\n'
     '                GradientStop { position: 1.0; color: Theme.winBot }\n'),

    (qml / "App/PageWindows.qml",
     '    function reset() {',
     page_funcs + '    function reset() {'),

    (qml / "App/PageWindows.qml",
     '    AppGroup {\n        title: "Opacity"',
     page_group + '    AppGroup {\n        title: "Opacity"'),

    (qml / "App/PageWindows.qml",
     '        title: "Opacity"\n        hint: "Changes show right away"',
     '        title: "Opacity"\n        hint: Flags.glassApps ? "App transparency controls these while it is on" : "Changes show right away"'),

    (qml / "App/PageWindows.qml",
     '            key: "windows.opacityActive"\n            AppSlider {',
     '            key: "windows.opacityActive"\n            enabled: !Flags.glassApps\n            opacity: enabled ? 1 : 0.45\n            AppSlider {'),

    (qml / "App/PageWindows.qml",
     '            key: "windows.opacityInactive"\n            AppSlider {',
     '            key: "windows.opacityInactive"\n            enabled: !Flags.glassApps\n            opacity: enabled ? 1 : 0.45\n            AppSlider {'),

    (qml / "App/searchDesktop.js",
     'key: "windows.blurNoise", advanced: true },\n',
     'key: "windows.blurNoise", advanced: true },\n' + search_rows),

    (qml / "shell.qml",
     '        Devices.detect();\n',
     '        Devices.detect();\n        Glass.push();\n'),

    (ghostty,
     'background-opacity = 0.85\n',
     '# The compositor owns window transparency now (Transparency group in Settings), so\n'
     '# the terminal does not stack its own opacity on top of that rule.\n'
     'background-opacity = 1\n'),

    (hypr / "window_rules.lua",
     'hl.window_rule({\n    name           = "suppress-maximize",',
     rules_block + 'hl.window_rule({\n    name           = "suppress-maximize",'),
]

# 12-settings-zoom may already have changed the shipped zoom, so anchor the
# glass flag block on whichever declaration is live instead of the old 0.85.
_flags = qml / "Singletons/Flags.qml"
_flags_text = _flags.read_text(encoding="utf-8")
for _i, (_p, _b, _a) in enumerate(EDITS):
    if _p == _flags and _b == '            property real appZoom: 0.85\n':
        for _candidate in ('            property real appZoom: 1\n',
                           '            property real appZoom: 1.0\n',
                           '            property real appZoom: 0.85\n'):
            if _candidate in _flags_text:
                EDITS[_i] = (_p, _candidate, _candidate + flag_props)
                break

# Ghostty is optional: without its config there is no terminal opacity to drop.
if not ghostty.exists():
    EDITS = [e for e in EDITS if e[0] != ghostty]


texts, changed = {}, {}

for path, before, after in EDITS:
    text = texts.get(path)
    if text is None:
        text = path.read_text(encoding="utf-8")
    if mode == "apply":
        if after in text:
            continue
        if text.count(before) != 1:
            sys.exit(f"anchor not unique in {path}: {before.splitlines()[0][:60]}")
        texts[path] = text.replace(before, after, 1)
    else:
        if after not in text:
            continue
        texts[path] = text.replace(after, before, 1)
    changed[path] = True

for path, text in texts.items():
    if not changed.get(path):
        continue
    tmp = path.with_name(path.name + ".20.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    print(f"{mode}: {path}")

print("__CHANGED__", 1 if changed else 0)
PY
)
printf '%s\n' "$out" | grep -v '^__CHANGED__' || true


git_removed=0
if [ "$MODE" = revert ]; then
    rm -f "$QML/Singletons/Glass.qml"
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/ricelin/window-opacity.lua"
    git_removed=1
fi

if printf '%s
' "$out" | grep -q '^__CHANGED__ 1$' || [ "$git_removed" = 1 ] || [ "$glass_changed" = 1 ]; then
    # The rules file is read at start-up, so a reload is what makes the change live.
    hyprctl reload >/dev/null 2>&1 || echo "note: hyprctl reload failed" >&2
    if [ -x "$RESTART" ] && qs -c pill ipc show >/dev/null 2>&1; then
        "$RESTART" restart pill >/dev/null 2>&1 || true
    fi
    if [ "$MODE" = apply ]; then
        echo "App transparency installed: Settings > Windows > Transparency."
    else
        echo "App transparency removed."
    fi
else
    echo "Nothing to do."
fi
)

# ---------------------------------------------------------------- stage_gamemode_opaque
stage_gamemode_opaque() (
# Game mode (SUPER + G) takes every bit of window transparency away.
#
# Two layers of transparency have to go, and they work differently:
#
#   window rules    every app carries the 0.90 opacity rule from 20. A rule
#                   cannot be removed at runtime, so this flips the pill's rule
#                   file to `enabled = false` and reloads Hyprland once.
#   decoration      active/inactive opacity are forced to 1.00 for the duration
#                   and put back from the snapshot.
#
# The reload is also why the strip runs after it: a reload re-reads the config
# file, which would otherwise put the eye-candy straight back.
#
# `gamemode.sh on|off` stays the interface, so the pill (GameMode.qml) and any
# keybind keep calling the same thing. The pill's renderer already writes
# `enabled = false` while `Flags.gameMode` is on (20 owns that guard), so
# touching the opacity slider mid-game cannot bring the frost back.
#
# `--revert` restores the upstream `gamemode.sh` byte for byte. Applying twice is
# a no-op. Run 20 first: without its rule file there is nothing to disable.

set -eu

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
GAMEMODE="$CFG/hypr/scripts/gamemode.sh"

[ -f "$GAMEMODE" ] || { echo "missing: $GAMEMODE" >&2; exit 1; }

case "${1:-apply}" in
    --revert|-r|revert) MODE=revert ;;
    *)                  MODE=apply ;;
esac

if [ "$MODE" = apply ]; then
    cat > "$GAMEMODE.21.tmp" <<'GAMEMODE_NEW_EOF'
#!/usr/bin/env bash
#
# Game mode visual strip for Hyprland. `on` snapshots the current decoration and
# animation values, then strips them live through hl.config eval (no reload, so no
# flicker). `off` pushes the snapshot back the same way. The snapshot lives in a
# file so a pill restart mid-game-mode can still restore; if it is ever missing,
# `off` falls back to a full reload.
#
# Transparency is the exception: a window rule cannot be removed at runtime, so
# `on` writes the pill's rule file with `enabled = false` and reloads once before
# stripping. Without that reload every app keeps the 0.90 opacity rule and game
# mode is only half opaque.
#
set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
snap="$state/gamemode-snapshot.json"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/ricelin"
opacity="$cache/window-opacity.lua"
opacity_snap="$state/gamemode-opacity.lua"
mkdir -p "$state"

getint() { hyprctl getoption "$1" -j | jq -r '.int'; }
getbool() { hyprctl getoption "$1" -j | jq -r '.bool'; }
getfloat() { hyprctl getoption "$1" -j | jq -r '.float'; }
getgap() { hyprctl getoption "$1" -j | jq -r '.css' | awk '{ print $1 }'; }

strip() {
	hyprctl eval 'hl.config({ general = { gaps_in = 0, gaps_out = 0, border_size = 0 }, decoration = { rounding = 0, blur = { enabled = false }, shadow = { enabled = false }, active_opacity = 1.0, inactive_opacity = 1.0 }, animations = { enabled = false } })' >/dev/null
}

# The pill writes this file; keep the user's copy so `off` can put it back exactly.
disable_opacity() {
	[ -f "$opacity" ] || return 0
	[ -f "$opacity_snap" ] || cp -f "$opacity" "$opacity_snap"
	sed -i 's/^\([[:space:]]*\)enabled = true,/\1enabled = false,/' "$opacity"
}

restore_opacity() {
	[ -f "$opacity_snap" ] || return 0
	cp -f "$opacity_snap" "$opacity"
	rm -f "$opacity_snap"
}

case "${1:-}" in
	on)
		if [ ! -f "$snap" ]; then
			jq -n \
				--arg gi "$(getgap general:gaps_in)" \
				--arg go "$(getgap general:gaps_out)" \
				--arg bs "$(getint general:border_size)" \
				--arg rd "$(getint decoration:rounding)" \
				--arg bl "$(getbool decoration:blur:enabled)" \
				--arg sh "$(getbool decoration:shadow:enabled)" \
				--arg an "$(getbool animations:enabled)" \
				--arg ao "$(getfloat decoration:active_opacity)" \
				--arg io "$(getfloat decoration:inactive_opacity)" \
				'{gaps_in:$gi, gaps_out:$go, border_size:$bs, rounding:$rd, blur:$bl, shadow:$sh, anim:$an, op_active:$ao, op_inactive:$io}' >"$snap"
		fi
		if [ -f "$opacity" ]; then
			disable_opacity
			# A reload is the only way to drop a window rule; strip afterwards or
			# the reload puts the eye-candy back.
			hyprctl reload >/dev/null
		fi
		strip
		;;
	off)
		if [ -f "$opacity_snap" ]; then
			restore_opacity
			hyprctl reload >/dev/null
		fi
		if [ -f "$snap" ]; then
			gi=$(jq -r '.gaps_in' "$snap"); go=$(jq -r '.gaps_out' "$snap")
			bs=$(jq -r '.border_size' "$snap"); rd=$(jq -r '.rounding' "$snap")
			bl=$(jq -r '.blur' "$snap"); sh=$(jq -r '.shadow' "$snap"); an=$(jq -r '.anim' "$snap")
			ao=$(jq -r '.op_active // 1.0' "$snap"); io=$(jq -r '.op_inactive // 1.0' "$snap")
			hyprctl eval "hl.config({ general = { gaps_in = $gi, gaps_out = $go, border_size = $bs }, decoration = { rounding = $rd, blur = { enabled = $bl }, shadow = { enabled = $sh }, active_opacity = $ao, inactive_opacity = $io }, animations = { enabled = $an } })" >/dev/null
			rm -f "$snap"
		elif [ ! -f "$opacity_snap" ]; then
			hyprctl reload >/dev/null
		fi
		;;
	*)
		echo "usage: gamemode.sh on|off" >&2
		exit 1
		;;
esac
GAMEMODE_NEW_EOF
else
    cat > "$GAMEMODE.21.tmp" <<'GAMEMODE_UPSTREAM_EOF'
#!/usr/bin/env bash
#
# Game mode visual strip for Hyprland. `on` snapshots the current decoration and
# animation values, then strips them live through hl.config eval (no reload, so no
# flicker). `off` pushes the snapshot back the same way. The snapshot lives in a
# file so a pill restart mid-game-mode can still restore; if it is ever missing,
# `off` falls back to a full reload.
#
set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
snap="$state/gamemode-snapshot.json"
mkdir -p "$state"

getint() { hyprctl getoption "$1" -j | jq -r '.int'; }
getbool() { hyprctl getoption "$1" -j | jq -r '.bool'; }
getgap() { hyprctl getoption "$1" -j | jq -r '.css' | awk '{ print $1 }'; }

strip() {
	hyprctl eval 'hl.config({ general = { gaps_in = 0, gaps_out = 0, border_size = 0 }, decoration = { rounding = 0, blur = { enabled = false }, shadow = { enabled = false } }, animations = { enabled = false } })' >/dev/null
}

case "${1:-}" in
	on)
		if [ ! -f "$snap" ]; then
			jq -n \
				--arg gi "$(getgap general:gaps_in)" \
				--arg go "$(getgap general:gaps_out)" \
				--arg bs "$(getint general:border_size)" \
				--arg rd "$(getint decoration:rounding)" \
				--arg bl "$(getbool decoration:blur:enabled)" \
				--arg sh "$(getbool decoration:shadow:enabled)" \
				--arg an "$(getbool animations:enabled)" \
				'{gaps_in:$gi, gaps_out:$go, border_size:$bs, rounding:$rd, blur:$bl, shadow:$sh, anim:$an}' >"$snap"
		fi
		strip
		;;
	off)
		if [ -f "$snap" ]; then
			gi=$(jq -r '.gaps_in' "$snap"); go=$(jq -r '.gaps_out' "$snap")
			bs=$(jq -r '.border_size' "$snap"); rd=$(jq -r '.rounding' "$snap")
			bl=$(jq -r '.blur' "$snap"); sh=$(jq -r '.shadow' "$snap"); an=$(jq -r '.anim' "$snap")
			hyprctl eval "hl.config({ general = { gaps_in = $gi, gaps_out = $go, border_size = $bs }, decoration = { rounding = $rd, blur = { enabled = $bl }, shadow = { enabled = $sh } }, animations = { enabled = $an } })" >/dev/null
			rm -f "$snap"
		else
			hyprctl reload >/dev/null
		fi
		;;
	*)
		echo "usage: gamemode.sh on|off" >&2
		exit 1
		;;
esac
GAMEMODE_UPSTREAM_EOF
fi

if cmp -s "$GAMEMODE.21.tmp" "$GAMEMODE"; then
    rm -f "$GAMEMODE.21.tmp"
    echo "gamemode.sh already $MODE"
else
    chmod 755 "$GAMEMODE.21.tmp"
    mv "$GAMEMODE.21.tmp" "$GAMEMODE"
    echo "$MODE: $GAMEMODE"
fi

if [ "$MODE" = apply ]; then
    echo "Game mode now drops window transparency."
else
    echo "Game mode restored to the upstream strip."
fi
)

# ---------------------------------------------------------------- stage_system_integration
stage_sddm_palette() (
# Install the palette-driven Ricelin SDDM theme and hook it into wallcolors.py.
# This is the embedded copy of 15-sddm-match.sh; the root phase copies torii and
# the user phase patches the QML and the palette renderer.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

THEME_NAME=ricelin
THEME_DIR="/usr/share/sddm/themes/$THEME_NAME"
SOURCE_THEME=/usr/share/sddm/themes/torii
CONF=/etc/sddm.conf.d/15-sddm-ricelin.conf
MARKER="$THEME_DIR/.ricelin-sddm"
WALLCOLORS="$HOME/.config/hypr/scripts/wallcolors.py"

target_user() {
    user=${PKEXEC_UID:-${SUDO_USER:-${DOAS_USER:-}}}
    [ -n "$user" ] || user=$(id -un)
    printf '%s\n' "$user"
}

# ---------------------------------------------------------------- root phase
if [ "${1:-}" = "--root" ]; then
    user=$(target_user)
    group=$(id -gn "$user")
    if [ ! -f "$SOURCE_THEME/Main.qml" ]; then
        echo "Stock SDDM theme $SOURCE_THEME is missing." >&2
        exit 1
    fi

    if [ ! -f "$MARKER" ]; then
        rm -rf "$THEME_DIR"
        install -d -m 755 "$THEME_DIR"
        cp -a "$SOURCE_THEME"/. "$THEME_DIR"/
        : > "$MARKER"
    fi

    # The stock video/poster are unused: theme.conf always points at the live
    # wallpaper copy, so drop 37 MB of dead assets from our private copy.
    rm -f "$THEME_DIR/assets/bg.mp4" "$THEME_DIR/assets/bg_poster.jpg"

    # The greeter runs as the sddm user and only needs to read; the desktop user
    # owns the copy so wallcolors.py can refresh it without another password.
    chown -R "$user:$group" "$THEME_DIR"
    chmod 755 "$THEME_DIR"

    install -d -m 755 /etc/sddm.conf.d
    cat > "$CONF" <<CONF
[Theme]
Current=$THEME_NAME
CONF
    chmod 644 "$CONF"
    echo "Installed the palette-driven SDDM theme at $THEME_DIR."
    exit 0
fi

# The root phase must have installed the theme and its drop-in first.
if [ ! -f "$MARKER" ] || [ ! -f "$CONF" ]; then
    echo "The SDDM theme root phase did not run." >&2
    exit 1
fi

# Every colour the torii QML hardcoded becomes a theme.conf key. This runs on
# every apply (not just first install) so effect colours added later also reach
# existing installs; each replacement is a no-op once applied.
if [ -f "$THEME_DIR/Main.qml" ]; then
    python3 - "$THEME_DIR/Main.qml" <<'PY'
import os
import re
import sys
p = sys.argv[1]
text = open(p).read()


def save(content):
    """Write through a temp file: a truncated QML or palette file breaks the greeter."""
    tmp = p + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, p)




def swap(old, new):
    global text
    if old in text:
        text = text.replace(old, new, 1)


old = '''    readonly property color verm: cfg("accent", "#c0442b")
    readonly property color vermDeep: "#a3371f"
    readonly property color vermGlow: Qt.rgba(192 / 255, 68 / 255, 43 / 255, 0.9)
    readonly property color cream: "#e6d6cb"
    readonly property color brightWhite: "#fff6f0"
    readonly property color dim: "#aeb3bd"
    readonly property color hairStrong: Qt.rgba(150 / 255, 172 / 255, 212 / 255, 0.32)
    readonly property color emberBase: "#1D120E"'''
new = '''    // ricelin-sddm: palette-driven, rewritten by 15-sddm-match.sh
    readonly property bool bgIsVideo: /\\.(mp4|webm|mkv|mov)$/i.test("" + cfg("background", ""))
    readonly property color verm: cfg("accent", "#c0442b")
    readonly property color vermDeep: cfg("accent_deep", "#a3371f")
    readonly property color vermGlow: Qt.rgba(verm.r, verm.g, verm.b, 0.9)
    readonly property color cream: cfg("cream", "#e6d6cb")
    readonly property color brightWhite: cfg("bright", "#fff6f0")
    readonly property color dim: cfg("dim", "#aeb3bd")
    readonly property color hair: cfg("hair", "#96acd4")
    readonly property color hairStrong: Qt.rgba(hair.r, hair.g, hair.b, 0.32)
    readonly property color surfaceHigh: cfg("surface_high", "#3a2a22")
    readonly property color ember: cfg("ember", "#ffcf7a")
    readonly property color petalA: cfg("petal_a", "#e0879b")
    readonly property color petalB: cfg("petal_b", "#d76f86")
    readonly property color emberBase: cfg("base", "#1D120E")'''
swap(old, new)

swap('''        source: Qt.resolvedUrl(root.cfg("background", "assets/bg.mp4"))''',
     '''        source: root.bgIsVideo ? Qt.resolvedUrl(root.cfg("background", "assets/bg.mp4")) : ""''')
swap('''        Component.onCompleted: bgPlayer.play()''',
     '''        Component.onCompleted: if (root.bgIsVideo) bgPlayer.play()''')
swap('''        source: Qt.resolvedUrl("assets/bg_poster.jpg")''',
     '''        source: Qt.resolvedUrl(root.cfg("poster", "assets/bg_poster.jpg"))''')

# The avatar ring, focus ring and pill/dropdown fills were still warm torii
# reds and browns.
swap('GradientStop { position: 0.0; color: "#3a2a22" }',
     'GradientStop { position: 0.0; color: root.surfaceHigh }')
swap('GradientStop { position: 1.0; color: "#1d120e" }',
     'GradientStop { position: 1.0; color: root.emberBase }')
swap('border.color: Qt.rgba(192 / 255, 68 / 255, 43 / 255, 0.45)',
     'border.color: Qt.rgba(root.verm.r, root.verm.g, root.verm.b, 0.45)')
swap('color: Qt.rgba(18 / 255, 11 / 255, 8 / 255, 0.5)',
     'color: Qt.rgba(root.emberBase.r, root.emberBase.g, root.emberBase.b, 0.5)')
swap('color: Qt.rgba(18 / 255, 11 / 255, 8 / 255, 0.92)',
     'color: Qt.rgba(root.emberBase.r, root.emberBase.g, root.emberBase.b, 0.92)')
swap('Qt.rgba(192 / 255, 68 / 255, 43 / 255, 0.16)',
     'Qt.rgba(root.verm.r, root.verm.g, root.verm.b, 0.16)')

# The wallpaper is shown exactly as rendered: drop the full-screen gradient
# scrim and the drifting ember/petal particles. These regexes are no-ops once
# the blocks are gone, so re-runs and already-cleaned themes stay valid.
text = re.sub(r'\n    Rectangle \{\n        anchors\.fill: parent\n        z: -900\n        gradient: Gradient \{.*?\n    \}\n',
              '\n', text, count=1, flags=re.S)
text = re.sub(r'\n    Item \{\n        id: embers\n.*?(?=\n    Item \{\n        id: topLeft\n)',
              '', text, count=1, flags=re.S)

save(text)
PY
    echo "Patched the theme QML to read its palette from theme.conf."
fi

# wallcolors.py owns the renderer so every wallpaper change refreshes the
# greeter with the same colours the desktop just got. The block is replaced on
# re-runs, so a tweak here reaches an already-installed system.
if [ -f "$WALLCOLORS" ]; then
    python3 - "$WALLCOLORS" <<'PY'
import os
import sys
p = sys.argv[1]
text = open(p).read()


def save(content):
    """Write through a temp file: a truncated QML or palette file breaks the greeter."""
    tmp = p + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, p)


func = '''# ricelin-sddm-match
def render_sddm(pill):
    """Mirror the live palette and wallpaper into the SDDM theme copy."""
    theme = Path("/usr/share/sddm/themes/ricelin")
    if not (theme / ".ricelin-sddm").is_file() or not os.access(theme, os.W_OK):
        return
    base = STATE.parent
    try:
        wallpaper = Path((base / "ricelin-wallpaper").read_text().strip())
    except OSError:
        return
    if not wallpaper.is_file():
        return
    still = base / "ricelin-wallpaper-still.png"
    if wallpaper.suffix.lower() in {".mp4", ".webm", ".mkv", ".mov"} and still.is_file():
        wallpaper = still
    assets = theme / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    dest = assets / "sddm-wallpaper.jpg"
    try:
        subprocess.run(["magick", str(wallpaper), "-auto-orient",
                        "-resize", "2560x2560>", "-background", pill["surface"],
                        "-alpha", "remove", "-alpha", "off",
                        "-quality", "92", str(dest)],
                       check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        dest = assets / ("sddm-wallpaper" + wallpaper.suffix.lower())
        shutil.copyfile(wallpaper, dest)
    for old in assets.glob("sddm-wallpaper.*"):
        if old != dest:
            old.unlink(missing_ok=True)

    conf = theme / "theme.conf"
    try:
        scale = next((ln.split("=", 1)[1].strip() for ln in conf.read_text().splitlines()
                      if ln.startswith("scale=")), "1.0")
    except OSError:
        scale = "1.0"
    rel = "assets/" + dest.name
    write_if_changed(conf, "\\n".join([
        "[General]",
        "background=" + rel,
        "poster=" + rel,
        "accent=" + pill["primary"],
        "accent_deep=" + pill["primary_container"],
        "cream=" + pill["cream"],
        "bright=" + pill["bright"],
        "dim=" + pill["dim"],
        "hair=" + pill["outline"],
        "base=" + pill["surface"],
        "surface_high=" + pill["surface_container_high"],
        "ember=" + pill["bright"],
        "petal_a=" + pill["subtle"],
        "petal_b=" + pill["dim"],
        "scale=" + scale,
        "",
    ]))


# ricelin-sddm-match-end
'''
start = text.find("# ricelin-sddm-match\n")
end = text.find("# ricelin-sddm-match-end\n", start)
if end != -1:
    end += len("# ricelin-sddm-match-end\n")
else:
    end = text.find("\ndef publish(", start)
if start != -1 and end != -1:
    text = text[:start] + text[end:]
if "\ndef publish(" not in text:
    sys.exit("wallcolors.py did not match the expected layout")
text = text.replace("\ndef publish(", "\n\n" + func + "def publish(", 1)
if "    render_sddm(pill)\n" not in text:
    text = text.replace("    render_fastfetch(pill)\n",
                        "    render_fastfetch(pill)\n    render_sddm(pill)\n", 1)
if 'if sys.argv[1] == "--sddm":' not in text:
    text = text.replace('if sys.argv[1] == "--apps":',
                        'if sys.argv[1] == "--sddm":\n'
                        '        try:\n'
                        '            pill = json.loads((CACHE / "colors.json").read_text())\n'
                        '        except (OSError, ValueError):\n'
                        '            pill = STATIC\n'
                        '        render_sddm(pill)\n'
                        '        return 0\n'
                        '    if sys.argv[1] == "--apps":', 1)
save(text)
PY
    echo "Hooked the SDDM renderer into wallcolors.py."
fi

# Render immediately from the palette already on disk for the current wallpaper.
if [ -f "$WALLCOLORS" ]; then
    python3 "$WALLCOLORS" --sddm
fi

echo "SDDM now follows the desktop palette (visible from the next login)."
)

stage_greeter_display() (
# Keep SDDM's greeter on the desktop panel's native mode and cursor.
#
# SDDM reads every file in /etc/sddm.conf.d, not just *.conf, so the backup of
# the previous drop-in must live outside that directory. The old .pre-ricelin
# file was being read after 20-xsetup.conf and silently restored Xsetup-torii;
# migrate it out of the way on existing installs.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

XSETUP=/etc/sddm/Xsetup-ricelin.sh
CONF=/etc/sddm.conf.d/20-xsetup.conf
BACKUP=/etc/sddm/20-xsetup.conf.pre-ricelin
OLD_BACKUP=/etc/sddm.conf.d/20-xsetup.conf.pre-ricelin
MARK=ricelin-greeter-display

target_user() {
    user=${PKEXEC_UID:-${SUDO_USER:-${DOAS_USER:-}}}
    [ -n "$user" ] || user=$(id -un)
    printf '%s\n' "$user"
}

user=$(target_user)
home=$(getent passwd "$user" | cut -d: -f6)
if [ -z "$home" ] || [ ! -d "$home" ]; then
    echo "No home directory for $user." >&2
    exit 1
fi
env_lua="$home/.config/hypr/modules/env.lua"

install -d -m 755 /etc/sddm /etc/sddm.conf.d

# SDDM loads every regular file in conf.d, so a *.pre-ricelin backup there
# overrides the active drop-in. Move it somewhere SDDM never reads.
if [ -f "$OLD_BACKUP" ]; then
    if [ ! -f "$BACKUP" ]; then
        mv -f "$OLD_BACKUP" "$BACKUP"
    else
        rm -f "$OLD_BACKUP"
    fi
fi

# Keep the drop-in as it was before this stage first touched it.
if [ ! -f "$BACKUP" ] && [ -f "$CONF" ] && ! grep -q "$MARK" "$CONF" 2>/dev/null; then
    cp -a "$CONF" "$BACKUP"
fi

cat > "$XSETUP" <<'XSETUP_EOF'
#!/bin/sh
# Generated by ricelin-setup/16-greeter-display.sh. Re-run that script instead
# of editing this file; it is regenerated on every install.
#
# Run by SDDM on the greeter's own X server, before sddm-greeter starts. Puts
# the panel back on the resolution/refresh and pointer the desktop session was
# using, so logging out does not drop to 60 Hz or a different cursor.

env_lua='@ENV_LUA@'

# --- refresh: native resolution, highest rate the panel offers --------------
out=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$out" ]; then
    res=$(xrandr 2>/dev/null | awk -v o="$out" '$1==o && $2=="connected" {
        for (i=3; i<=NF; i++)
            if ($i ~ /^[0-9]+x[0-9]+\+/) { sub(/\+.*/, "", $i); print $i; exit }
    }')
    rate=$(xrandr 2>/dev/null | awk -v o="$out" -v r="$res" '
        $1==o && $2=="connected" { inside=1; next }
        /^[^ \t]/ { inside=0 }
        inside && $1==r {
            for (i=2; i<=NF; i++) {
                g=$i; gsub(/[*+]/, "", g)
                if (g ~ /^[0-9]+(\.[0-9]+)?$/) { v=g+0; if (v>max) max=v }
            }
        }
        END { if (max) printf "%.2f\n", max }')
    if [ -n "$res" ] && [ -n "$rate" ]; then
        xrandr --output "$out" --mode "$res" --rate "$rate" --primary >/dev/null 2>&1 || true
    fi
fi

# --- pointer: same theme and size the Hyprland session will use -------------
theme=Adwaita
size=24
if [ -r "$env_lua" ]; then
    t=$(sed -n 's/.*XCURSOR_THEME"[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p' "$env_lua" | tail -n 1)
    s=$(sed -n 's/.*XCURSOR_SIZE"[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p' "$env_lua" | tail -n 1)
    [ -n "$t" ] && theme=$t
    case $s in ''|*[!0-9]*) ;; *) size=$s ;; esac
fi
# The greeter runs as the sddm user, which cannot read a theme kept under
# ~/.local/share/icons; only offer names it can load.
[ -f "/usr/share/icons/$theme/cursors/left_ptr" ] || theme=Adwaita
xrdb -nocpp -merge >/dev/null 2>&1 <<EOF
Xcursor.theme: $theme
Xcursor.size: $size
EOF
XSETUP_EOF
chmod 755 "$XSETUP"
sed -i "s|@ENV_LUA@|$env_lua|" "$XSETUP"

cat > "$CONF" <<CONF
# $MARK
[X11]
DisplayCommand=$XSETUP
CONF
chmod 644 "$CONF"

echo "Greeter display installed: $XSETUP on the native mode at its highest refresh, cursor from $env_lua."
)

stage_system_integration() (
# Finish the display-manager, browser and file-manager handover, and keep the
# night light up.
#
# Four loose ends from the desktop setup:
#
#   display manager  SDDM was installed but LightDM was still enabled and owned
#                    display-manager.service. This removes every LightDM package,
#                    config file, user and runtime directory, then enables SDDM
#                    and points display-manager.service at it. The running
#                    LightDM session is left alone; SDDM takes over on reboot.
#
#   browser          Firefox was still installed next to Zen. This removes the
#                    package, both profile trees and every MIME association that
#                    still names it, then makes zen.desktop the default browser.
#
#   file manager     Dolphin was still installed next to Thunar even though
#                    Thunar is the themed handler. This removes the package,
#                    its config/cache and every MIME association that still
#                    names it, then leaves thunar.desktop as the folder handler.
#
#   night light      hyprsunset hit systemd's start limit after a crash loop.
#                    A user drop-in removes the limit and restarts it forever.
#
# Usage:
#   sh installer stage            apply
#   sh installer stage --check    report only
#
# No display manager is stopped or restarted here.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

self=$(readlink -f "$0")
mode=${1:-apply}

# ------------------------------------------------------------------ user phase
if [ "${1:-}" = "--user" ]; then
    config="${XDG_CONFIG_HOME:-$HOME/.config}"
    override="$config/systemd/user/hyprsunset.service.d/override.conf"

    mkdir -p "$(dirname "$override")"
    cat > "$override" <<'UNIT'
# Keep the night light alive: a crash must not leave the session permanently
# cool for the rest of the day.
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=2
UNIT

    systemctl --user daemon-reload
    systemctl --user enable hyprsunset.service >/dev/null 2>&1 || true
    systemctl --user reset-failed hyprsunset.service >/dev/null 2>&1 || true
    systemctl --user restart hyprsunset.service >/dev/null 2>&1 || true

    # Firefox profile and cache trees. The package is removed in the root phase.
    rm -rf "$HOME/.mozilla" "$HOME/.cache/mozilla" "$HOME/.config/mozilla"
    rm -rf "$HOME/.var/app/org.mozilla.firefox" "$HOME/.var/app/org.mozilla.firefoxpwa"
    find "$HOME/.local/share/applications" -maxdepth 1 \( -iname '*firefox*.desktop' -o -iname '*mozilla*.desktop' \) -delete 2>/dev/null || true
    find "$HOME/.local/share/icons" -maxdepth 2 -iname 'firefox*' -exec rm -rf {} + 2>/dev/null || true

    # Dolphin's per-user state and the demo it shipped with. The package itself
    # is removed in the root phase.
    rm -rf "$HOME/.config/dolphinrc" "$HOME/.config/dolphinrc.bak"
    rm -rf "$HOME/.config/session/dolphin_dolphin_dolphin"
    rm -rf "$HOME/.local/share/dolphin" "$HOME/.cache/dolphin"
    rm -rf "$HOME/.local/share/kxmlgui5/dolphin"
    rm -rf "$HOME/.local/state/dolphinstaterc" "$HOME/.local/state/UserFeedback.org.kde.dolphin"
    # The demo also edited KDE's file-dialog places. Drop that file only when
    # the demo is actually present, so a normal user's places survive.
    if [ -d "$HOME/.local/share/ricelin-dolphin-demo" ] \
        || [ -f "$HOME/.local/share/kio/servicemenus/ricelin-wallpaper.desktop" ]; then
        rm -f "$HOME/.local/share/user-places.xbel" \
              "$HOME/.local/share/user-places.xbel.bak" \
              "$HOME/.local/share/user-places.xbel.tbcache"
    fi
    rm -rf "$HOME/.local/share/ricelin-dolphin-demo"
    rm -f "$HOME/.local/share/kio/servicemenus/ricelin-wallpaper.desktop"
    rmdir "$HOME/.local/share/kio/servicemenus" 2>/dev/null || true
    find "$HOME/.local/share/applications" -maxdepth 1 -iname '*dolphin*.desktop' -delete 2>/dev/null || true

    # Scrub stale Firefox and Dolphin associations, then make the replacements
    # explicit defaults.
    for f in "$HOME/.config/mimeapps.list" "$HOME/.local/share/applications/mimeapps.list"; do
        [ -f "$f" ] || continue
        python3 - "$f" <<'PY'
import os
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="ignore").read()
out = "\n".join(line for line in text.splitlines()
                if "firefox" not in line.lower()
                and "dolphin" not in line.lower()) + "\n"
if out != text:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(out)
    os.replace(tmp, path)
PY
    done
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

    zen=$(find /usr/share/applications "$HOME/.local/share/applications" \
        -maxdepth 1 -iname 'zen*.desktop' -printf '%f\n' 2>/dev/null | head -n1)
    [ -n "$zen" ] && xdg-settings set default-web-browser "$zen" >/dev/null 2>&1 || true
    xdg-mime default thunar.desktop inode/directory >/dev/null 2>&1 || true

    echo "User side: hyprsunset override installed, Firefox and Dolphin profiles and MIME entries removed, Zen and Thunar are the defaults."
    exit 0
fi

if [ "$mode" = "--check" ]; then
    echo "Display manager:"
    readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo "  (none)"
    systemctl is-enabled sddm 2>/dev/null || true
    echo "LightDM packages:"
    pacman -Q lightdm lightdm-slick-greeter eos-lightdm-slick-theme 2>/dev/null || echo "  none installed"
    echo "Firefox packages:"
    pacman -Q firefox 2>/dev/null || echo "  none installed"
    echo "File managers:"
    pacman -Q dolphin thunar 2>/dev/null || true
    echo -n "  folder handler: "; xdg-mime query default inode/directory 2>/dev/null || true
    echo "Night light:"
    systemctl --user cat hyprsunset.service >/dev/null 2>&1 && systemctl --user is-active hyprsunset 2>/dev/null || true
    exit 0
fi

if [ "$mode" = "--root" ]; then
    # Remove LightDM first so enabling SDDM can take display-manager.service.
    systemctl disable lightdm.service >/dev/null 2>&1 || true
    if pacman -Q lightdm >/dev/null 2>&1 || pacman -Q lightdm-slick-greeter >/dev/null 2>&1 \
        || pacman -Q eos-lightdm-slick-theme >/dev/null 2>&1; then
        pacman -Rns --noconfirm lightdm lightdm-slick-greeter eos-lightdm-slick-theme
    fi

    rm -rf /etc/lightdm /var/lib/lightdm /var/log/lightdm /var/cache/lightdm /run/lightdm
    rm -rf /var/lib/lightdm-data /run/lightdm.pid /run/systemd/units/invocation:lightdm.service
    rm -f /var/cache/pacman/pkg/*lightdm*.pkg.tar.zst /var/cache/pacman/pkg/*lightdm*.pkg.tar.zst.sig
    rm -rf /usr/share/lightdm /usr/lib/lightdm /usr/share/xgreeters/lightdm* 2>/dev/null || true
    rm -f /etc/pam.d/lightdm /etc/pam.d/lightdm-greeter /etc/pam.d/lightdm-autologin 2>/dev/null || true
    find /usr/share/icons -maxdepth 4 \( -iname 'lightdm-settings.svg' -o -iname 'lightdm-gtk-greeter-settings.svg' \) -delete 2>/dev/null || true
    userdel lightdm >/dev/null 2>&1 || true
    groupdel lightdm >/dev/null 2>&1 || true

    # Only replace the symlink if it is still LightDM's.
    if readlink -f /etc/systemd/system/display-manager.service 2>/dev/null | grep -q lightdm; then
        rm -f /etc/systemd/system/display-manager.service
    fi
    systemctl enable sddm.service
    systemctl set-default graphical.target >/dev/null

    # Firefox and its system-wide leftovers.
    for pkg in firefox firefox-developer-edition firefox-esr; do
        if pacman -Q "$pkg" >/dev/null 2>&1; then
            pacman -Rns --noconfirm "$pkg"
        fi
    done
    rm -rf /usr/lib/firefox /usr/share/firefox /usr/lib/firefox-developer-edition 2>/dev/null || true
    rm -f /usr/share/applications/firefox.desktop /usr/share/applications/firefox-esr.desktop 2>/dev/null || true
    rm -f /var/cache/pacman/pkg/*firefox*.pkg.tar.zst /var/cache/pacman/pkg/*firefox*.pkg.tar.zst.sig

    # Dolphin and its now-unneeded dependencies. Shared KDE Frameworks
    # packages stay because pacman only removes unrequired orphans.
    if pacman -Q dolphin >/dev/null 2>&1; then
        pacman -Rns --noconfirm dolphin || \
            echo "Dolphin is still installed; check its package dependencies." >&2
    fi
    rm -f /usr/share/applications/org.kde.dolphin.desktop /usr/share/applications/dolphin.desktop 2>/dev/null || true
    rm -rf /usr/share/dolphin /usr/lib/dolphin 2>/dev/null || true
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

    find /etc /var /usr -iname '*lightdm*' -not -path '/var/lib/pacman/*' -not -path '/usr/share/doc/*' \
        -print 2>/dev/null | head -n 20 | sed 's/^/  leftover: /'

    echo "Root side: LightDM removed, SDDM enabled, Firefox and Dolphin removed."
    exit 0
fi

# --------------------------------------------------------------- dispatch
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo "$self" --root
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$self" --root
    else
        echo "Run as root to remove the packages and enable SDDM." >&2
        exit 1
    fi
    exec "$self" --user
fi

"$self" --root
echo "Run the user phase as your desktop user: sh $self --user"
)

# ---------------------------------------------------------------- stage_screenshot_binds
stage_screenshot_binds() (
# Add the two screenshot keybinds and install hyprshot.
#
#   ALT + P         select a region and copy it to the clipboard
#   ALT + SHIFT + P select a region and save it to Pictures/Screenshots
#
# hyprshot is the Hyprland screenshot tool (the distro package is called
# hyprshot; it is unrelated to the Python video "hypershot" uploader). The
# package lives in the extra repository. This script installs it system-wide
# when run as root, and otherwise puts the upstream script in ~/.local/bin.
#
# The binds call hyprshot directly, with no wrapper scripts. Each command
# prefixes ~/.local/bin to PATH so it works whether hyprshot came from the
# package or from the user copy, since Hyprland's exec environment does not
# always include ~/.local/bin.
#
# The binds are plain `hl.bind` lines in hypr/modules/binds.lua, so Ricelin
# Settings > Keybinds parses them like every other bind and lets them be
# renamed, re-keyed or deleted there.
#
# Usage:
#   sh installer stage            apply (binds + user hyprshot)
#   sh installer stage --root     install the distro package
#   sh installer stage --revert   remove the binds

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
BINDS="$CONFIG/hypr/modules/binds.lua"
COPY="$CONFIG/hypr/scripts/screenshot-copy.sh"
SAVE="$CONFIG/hypr/scripts/screenshot-save.sh"
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
HYPRSHOT="$LOCAL_BIN/hyprshot"
MARK="-- ricelin-screenshot-binds"

COPY_BIND='hl.bind("ALT + P",         hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" hyprshot -m region --clipboard-only")) -- screenshot copy'
SAVE_BIND='hl.bind("ALT + SHIFT + P", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" HYPRSHOT_DIR=\"$HOME/Pictures/Screenshots\" hyprshot -m region")) -- screenshot save'

mode=${1:-apply}
case "$mode" in
    --revert|-r|revert) mode=revert ;;
    --root)             mode=root ;;
    *)                  mode=apply ;;
esac

reload_hypr() {
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
}

install_package() {
    command -v pacman >/dev/null 2>&1 || return 1
    pacman -S --needed --noconfirm hyprshot
}

install_user_copy() {
    if command -v hyprshot >/dev/null 2>&1; then
        echo "hyprshot: $(command -v hyprshot)"
        return 0
    fi
    if [ -x "$HYPRSHOT" ]; then
        echo "hyprshot: $HYPRSHOT"
        return 0
    fi

    mkdir -p "$LOCAL_BIN"
    tmp="$HYPRSHOT.tmp"
    url_base="https://raw.githubusercontent.com/Gustash/hyprshot"

    # The project has no v1.3.0 tag; try it first anyway so a future tag pins
    # cleanly, then fall back to the maintained branch.
    for ref in v1.3.0 master; do
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$url_base/$ref/hyprshot" -o "$tmp" 2>/dev/null || continue
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$tmp" "$url_base/$ref/hyprshot" 2>/dev/null || continue
        else
            echo "curl or wget is required to install hyprshot." >&2
            return 1
        fi
        [ -s "$tmp" ] && grep -q 'Hyprshot is an utility' "$tmp" && break
        rm -f "$tmp"
    done

    [ -s "$tmp" ] || {
        echo "Could not download hyprshot; install the extra/hyprshot package." >&2
        return 1
    }
    chmod 755 "$tmp"
    mv -f "$tmp" "$HYPRSHOT"
    echo "hyprshot: $HYPRSHOT"
}

strip_binds() {
    [ -f "$BINDS" ] || return 0
    python3 - "$BINDS" "$MARK" <<'PY'
import os
import sys
path, mark = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
out = [line for line in lines
       if mark not in line
       and "screenshot-copy.sh" not in line
       and "screenshot-save.sh" not in line
       and "hyprshot -m region" not in line]
if out != lines:
    text = "\n".join(out).rstrip("\n") + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
PY
}

write_binds() {
    [ -f "$BINDS" ] || { echo "binds.lua not found at $BINDS" >&2; exit 1; }
    if grep -q 'hyprshot -m region --clipboard-only' "$BINDS" &&
       grep -q 'HYPRSHOT_DIR=.*hyprshot -m region' "$BINDS" &&
       ! grep -q 'screenshot-copy.sh\|screenshot-save.sh' "$BINDS"; then
        echo "Screenshot binds already present."
        return 0
    fi
    # Replace older wrapper binds (and any partial direct binds) in place.
    strip_binds
    {
        printf '\n%s\n' "$MARK"
        printf '%s\n' "$COPY_BIND"
        printf '%s\n' "$SAVE_BIND"
    } >> "$BINDS"
    echo "Added ALT + P and ALT + SHIFT + P to $BINDS."
}

remove_binds() {
    strip_binds
    echo "Removed the screenshot binds."
}

case "$mode" in
    root)
        if install_package; then
            echo "Root side: hyprshot installed from extra."
        else
            echo "Root side: package install unavailable; the user phase will install a local copy." >&2
        fi
        exit 0
        ;;
    revert)
        remove_binds
        rm -f "$COPY" "$SAVE"
        reload_hypr
        echo "Reverted: ALT + P / ALT + SHIFT + P removed."
        exit 0
        ;;
esac

mkdir -p "$STATE" "$HOME/Pictures/Screenshots"
# Clean up wrappers left by the previous version of this script.
rm -f "$COPY" "$SAVE"
install_user_copy || true
write_binds
reload_hypr

echo "Screenshots: ALT + P copies a region, ALT + SHIFT + P saves one to Pictures/Screenshots."
)

# ---------------------------------------------------------------- stage_vibrance
stage_vibrance() (
# Install nvibrant and set NVIDIA digital vibrance to 75%.
#
# nvibrant is the Wayland-capable Digital Vibrance tool (AUR package
# nvibrant-bin). Its raw scale is -1024..1023, but it is not the NVIDIA
# 0..100% slider: raw 0 is the driver default, which NVIDIA labels 50%;
# raw 1023 is 100% and raw -1024 is 0%. The mapping is asymmetric, so
# 75% is raw 512. Treating the raw scale as 0..100% writes 767, which
# NVIDIA reports as about 87%.
#
# nvibrant has no read-only query: a no-argument run resets every output to 0.
# The helper therefore discovers connected outputs from /sys/class/drm and
# passes one value per physical port (DVID, HDMI, DP-1, DP-2), avoiding a reset
# flash and keeping the login service from clearing the setting.
#
# The value is applied now and again at login by a systemd user service,
# because a driver reload or reboot resets the display attribute.
#
# Usage:
#   sh installer stage            install if needed, apply, install the service
#   sh installer stage --check    report only
#   sh installer stage --revert   remove the service and reset vibrance to 0

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
STATE="$STATE_DIR/nvibrant-value"
QML="$CONFIG/quickshell/pill/Singletons/Devices.qml"
HELPER="$LOCAL_BIN/ricelin-nvibrant"
UNIT_DIR="$CONFIG/systemd/user"
UNIT="$UNIT_DIR/nvibrant-75.service"
VALUE=512
PERCENT=75

mode=${1:-apply}
case "$mode" in
    --check|-c|check)    mode=check ;;
    --revert|-r|revert)  mode=revert ;;
    --root)              mode=root ;;
    *)                   mode=apply ;;
esac

install_package() {
    command -v nvibrant >/dev/null 2>&1 && return 0
    if command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm nvibrant-bin
    elif command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm nvibrant-bin
    else
        echo "nvibrant is missing; install the AUR package nvibrant-bin." >&2
        return 1
    fi
}

write_helper() {
    mkdir -p "$LOCAL_BIN"
cat > "$HELPER" <<'SH'
#!/bin/sh
# Apply the Ricelin digital-vibrance level to every connected NVIDIA output.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VALUE=${RICELIN_VIBRANCE_VALUE:-512}

command -v nvibrant >/dev/null 2>&1 || exit 0

# nvibrant's physical port order on this GPU is DVID, HDMI, DP-1, DP-2.
# A missing sysfs node is treated as disconnected (0); only a connected port
# receives the requested value. This never runs nvibrant without arguments.
connected() {
    for status in /sys/class/drm/card*-$1/status; do
        [ -e "$status" ] || continue
        [ "$(cat "$status" 2>/dev/null)" = connected ] && return 0
    done
    return 1
}

dvid=0; hdmi=0; dp1=0; dp2=0
connected 'DVI-*'    && dvid=$VALUE
connected 'HDMI-A-*' && hdmi=$VALUE
connected 'DP-1'     && dp1=$VALUE
connected 'DP-2'     && dp2=$VALUE

[ "$dvid$hdmi$dp1$dp2" = "0000" ] && exit 0
exec nvibrant "$dvid" "$hdmi" "$dp1" "$dp2"
SH
    chmod 755 "$HELPER"
}

write_service() {
    mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<'UNIT'
[Unit]
Description=Apply 75% NVIDIA digital vibrance
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=%h/.local/bin/ricelin-nvibrant
RemainAfterExit=yes

[Install]
WantedBy=default.target
UNIT
}

enable_service() {
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now nvibrant-75.service
}

# Upstream's slider conversion is wrong: it treats nvibrant's -1024..1023 raw
# scale as if 0 were 0%, so the pill shows 75% while applying raw 767 (~87%).
# Patch the QML to the same asymmetric mapping the helper uses. The patch is
# marker-free and idempotent; if the anchor moves, fail loudly instead of
# leaving the slider disagreeing with the applied value.
patch_pill() {
    [ -f "$QML" ] || {
        echo "Devices.qml not found at $QML; cannot fix the vibrance slider." >&2
        return 1
    }
    python3 - "$QML" <<'PY'
import os
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old_doc = """    /**
     * nvibrant ignores extra connector slots, so every slot gets the same value instead of guessing which ones are lit.
     */"""
new_doc = """    /**
     * nvibrant ignores extra connector slots, so every slot gets the same value instead of guessing which ones are lit.
     *
     * nvibrant's raw scale is -1024..1023. NVIDIA's 0..100% slider treats 0 raw
     * as 50%, 1023 as 100% and -1024 as 0%, so 75% is raw 512. Using the raw
     * scale directly (pct * 1023 / 100) would apply 767 and read back as ~87%.
     */"""
old_code = "        var raw = Math.round(Math.max(0, Math.min(100, pct)) * 1023 / 100);"
new_code = """        var p = Math.max(0, Math.min(100, pct));
        var raw = p >= 50 ? Math.round((p - 50) * 1023 / 50)
                          : Math.round((p - 50) * 1024 / 50);"""

if new_code in text:
    print("vibrance slider already maps NVIDIA's scale")
    raise SystemExit(0)
if old_code not in text:
    raise SystemExit("could not find the vibrance conversion in " + path)
if old_doc in text:
    text = text.replace(old_doc, new_doc, 1)
text = text.replace(old_code, new_code, 1)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, path)
print("vibrance slider patched")
PY
}

# The pill owns the displayed vibrance: it restores this file at startup. Write
# 75 so the number in the mixer matches the value applied here. If the pill is
# already running under its watchdog, restart it to pick the file up; without a
# watchdog we leave it alone and the next login will show the new value.
sync_pill() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" > "$STATE"
    command -v qs >/dev/null 2>&1 || return 0
    qs -c pill ipc show >/dev/null 2>&1 || return 0
    pgrep -f "$HOME/.config/hypr/scripts/watchdog.sh pill" >/dev/null 2>&1 || return 0
    qs -c pill kill >/dev/null 2>&1 || true
}

connector_status() {
    for d in /sys/class/drm/card*-*; do
        [ -e "$d/status" ] || continue
        printf '  %s %s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)"
    done | sort
}

show_status() {
    echo "vibrance: ${PERCENT}% (raw $VALUE)"
    printf 'pill state: %s\n' "$(cat "$STATE" 2>/dev/null || echo missing)"
    if [ -f "$QML" ] && grep -q 'p >= 50 ? Math.round((p - 50) \* 1023 / 50)' "$QML"; then
        echo "pill mapping: fixed"
    else
        echo "pill mapping: stock (wrong)"
    fi
    if command -v nvibrant >/dev/null 2>&1; then
        echo "nvibrant: $(command -v nvibrant)"
    else
        echo "nvibrant: not installed"
    fi
    echo "connectors:"
    connector_status
    if systemctl --user is-enabled nvibrant-75.service >/dev/null 2>&1; then
        echo "login service: enabled"
    else
        echo "login service: not enabled"
    fi
}

case "$mode" in
    root)
        # yay refuses to run as root; the package is a user/AUR step.
        echo "Root side: nvibrant is installed by the user phase through yay/paru."
        exit 0
        ;;
    check)
        show_status
        exit 0
        ;;
    revert)
        systemctl --user disable --now nvibrant-75.service >/dev/null 2>&1 || true
        rm -f "$UNIT" "$HELPER"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        command -v nvibrant >/dev/null 2>&1 && nvibrant 0 0 0 0 >/dev/null 2>&1 || true
        # Raw 0 is the driver default, which reads as 50% on NVIDIA's slider.
        sync_pill 50
        echo "Reverted: vibrance reset to the driver default and the login service removed."
        exit 0
        ;;
esac

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi >/dev/null 2>&1 || {
        echo "NVIDIA driver is not responding; skipping vibrance." >&2
        exit 0
    }
fi

install_package
write_helper
write_service
enable_service
"$HELPER" || true
patch_pill
sync_pill "$PERCENT"

echo "Digital vibrance: ${PERCENT}% (raw $VALUE), pill slider and state synced, re-applied by nvibrant-75.service at login."
)

# ---------------------------------------------------------------- stage_ui_tweaks
stage_logout() (
# Return to SDDM instead of leaving the display on a black tty.
#
# Hyprland exits on tty1, but SDDM's X11 greeter lives on another VT. On some
# NVIDIA setups logind does not switch back after the compositor exits, so the
# user is stranded on a black console with a blinking cursor. A transient
# system unit queues chvt after the session tears down; it has to be created
# before Hyprland exits or it is killed with the session.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
USER_HELPER="$CONFIG/hypr/scripts/logout.sh"
POWER="$CONFIG/quickshell/pill/Power.qml"
ROOT_HELPER=/usr/local/lib/ricelin/logout-vt
SUDOERS=/etc/sudoers.d/ricelin-chvt
RESTART="$CONFIG/hypr/scripts/ricelin"

target_user() {
    user=${PKEXEC_UID:-${SUDO_USER:-${DOAS_USER:-}}}
    [ -n "$user" ] || user=$(id -un)
    printf '%s\n' "$user"
}

if [ "${1:-}" = "--root" ]; then
    user=$(target_user)
    install -d -m 755 /usr/local/lib/ricelin /etc/sudoers.d

    cat > "$ROOT_HELPER" <<'HELPER'
#!/bin/sh
# Ricelin: after Hyprland exits, put the display back on SDDM's greeter VT.
#
# SDDM runs its X11 greeter on a different VT from the Wayland session. On
# some NVIDIA setups logind does not switch back after the compositor exits,
# leaving the user on a black tty with a blinking cursor. Queue a chvt from a
# transient system unit so it survives the session teardown.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

vt=$(ps -o args= -C Xorg 2>/dev/null | awk '
    /-auth \/run\/sddm/ {
        for (i = 1; i <= NF; i++)
            if ($i ~ /^vt[0-9]+$/) { sub(/^vt/, "", $i); print $i; exit }
    }')
case "${vt:-}" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$vt" -ge 1 ] && [ "$vt" -le 63 ] || exit 0
command -v systemd-run >/dev/null 2>&1 || exit 0
exec systemd-run --collect --quiet --on-active=1 /usr/bin/chvt "$vt"
HELPER
    chmod 755 "$ROOT_HELPER"

    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# Ricelin: return to SDDM's VT after logging out of Hyprland.
$user ALL=(root) NOPASSWD: $ROOT_HELPER
EOF
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "Invalid sudoers rule." >&2; exit 1; }
    fi
    install -m 440 "$tmp" "$SUDOERS"
    rm -f "$tmp"
    echo "Logout helper installed: $ROOT_HELPER"
    exit 0
fi

mkdir -p "$(dirname "$USER_HELPER")"
cat > "$USER_HELPER" <<'HELPER'
#!/bin/sh
# Log out of Hyprland and hand the display back to SDDM.
#
# The compositor exits on tty1 while SDDM's X11 greeter lives on another VT.
# The root helper queues a chvt in a transient system unit; it must be started
# before Hyprland exits so it is not killed with the session.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/local/lib/ricelin/logout-vt >/dev/null 2>&1 || true
    fi
fi
exec hyprctl dispatch 'hl.dsp.exit()'
HELPER
chmod 755 "$USER_HELPER"

if [ ! -f "$POWER" ]; then
    echo "Power.qml not found at $POWER" >&2
    exit 1
fi

python3 - "$POWER" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = '        { key: "logout",   glyph: "logout",   label: "log out",   confirm: true,  dispatch: "hl.dsp.exit()", argv: [] },'
new = ('        // ricelin-logout: the helper restores SDDM\'s greeter VT after Hyprland exits.\n'
       '        { key: "logout",   glyph: "logout",   label: "log out",   confirm: true,  dispatch: "",             argv: [Quickshell.env("HOME") + "/.config/hypr/scripts/logout.sh"] },')
if new not in text:
    if old not in text:
        sys.exit("Power.qml logout action did not match the expected layout")
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text.replace(old, new, 1))
    tmp.replace(path)
PY

echo "Pill logout now uses $USER_HELPER."
if [ -x "$RESTART" ] && qs -c pill ipc show >/dev/null 2>&1; then
    "$RESTART" restart pill >/dev/null 2>&1 || true
fi
)

stage_ui_tweaks() (
# Match the remaining desktop tweaks: 12 px cursor, SUPER+Q close,
# SUPER+SHIFT+Q kill, and Thunar in double-click mode.
#
# Usage:
#   sh installer stage            apply
#   sh installer stage --revert   restore 24 px cursor, SUPER+W / CTRL+SHIFT+W,
#                                 and Thunar single-click

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
INPUT="$CONFIG/hypr/modules/input.lua"
ENVFILE="$CONFIG/hypr/modules/env.lua"
AUTOSTART="$CONFIG/hypr/modules/autostart.lua"
BINDS="$CONFIG/hypr/modules/binds.lua"
CURSOR_THEME="Bibata-Modern-Ice"

mode=${1:-apply}
size=12
single=false
case "$mode" in
    --revert|-r|revert)
        mode=revert
        size=24
        single=true
        ;;
    *) mode=apply ;;
esac

for f in "$ENVFILE" "$AUTOSTART" "$BINDS"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

python3 - "$ENVFILE" "$AUTOSTART" "$BINDS" "$mode" "$size" <<'PY'
import os
import re
import sys

envfile, autostart, binds, mode, size = sys.argv[1:6]


def save(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def sub(path, pattern, repl):
    text = open(path, encoding="utf-8").read()
    out = re.sub(pattern, repl, text, count=1)
    if out != text:
        save(path, out)


sub(envfile, r'(hl\.env\("XCURSOR_SIZE",\s*)"[^"]*"', rf'\g<1>"{size}"')
sub(envfile, r'(hl\.env\("HYPRCURSOR_SIZE",\s*)"[^"]*"', rf'\g<1>"{size}"')
sub(autostart, r'(hyprctl setcursor [^ ]+ )\d+', rf'\g<1>{size}')

text = open(binds, encoding="utf-8").read()
if mode == "apply":
    text = re.sub(r'^hl\.bind\(mod \.\. " \+ W",(\s*)hl\.dsp\.window\.kill\(\)\)',
                  r'hl.bind(mod .. " + SHIFT + Q",\1hl.dsp.window.kill())', text, count=1, flags=re.M)
    text = re.sub(r'^hl\.bind\("CTRL \+ SHIFT \+ W",(\s*)hl\.dsp\.window\.close\(\)\)',
                  r'hl.bind(mod .. " + Q",\1hl.dsp.window.close())', text, count=1, flags=re.M)
else:
    text = re.sub(r'^hl\.bind\(mod \.\. " \+ SHIFT \+ Q",(\s*)hl\.dsp\.window\.kill\(\)\)',
                  r'hl.bind(mod .. " + W",\1hl.dsp.window.kill())', text, count=1, flags=re.M)
    text = re.sub(r'^hl\.bind\(mod \.\. " \+ Q",(\s*)hl\.dsp\.window\.close\(\)\)',
                  r'hl.bind("CTRL + SHIFT + W",\1hl.dsp.window.close())', text, count=1, flags=re.M)
save(binds, text)
PY

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.interface cursor-size "$size" 2>/dev/null || true
fi

if command -v xfconf-query >/dev/null 2>&1; then
    xfconf-query -c thunar -p /misc-single-click -s "$single" 2>/dev/null || true
    command -v thunar >/dev/null 2>&1 && thunar -q >/dev/null 2>&1 || true
fi

if command -v hyprctl >/dev/null 2>&1; then
    hyprctl setcursor "$CURSOR_THEME" "$size" >/dev/null 2>&1 || true
    hyprctl reload >/dev/null 2>&1 || true
fi

if [ "$mode" = revert ]; then
    echo "Reverted: cursor 24, SUPER+W close / CTRL+SHIFT+W kill, Thunar single-click."
else
    echo "Applied: cursor 12, SUPER+Q close / SUPER+SHIFT+Q kill, Thunar double-click."
fi
)

# ---------------------------------------------------------------- stage_portal_scheme
stage_hyprtoolkit_palette() (
# Make hyprpolkitagent's authentication popup follow the desktop palette.
#
# hyprpolkitagent draws its password dialog with hyprtoolkit. hyprtoolkit reads
# ~/.config/hypr/hyprtoolkit.conf for colours, rounding and fonts; the agent
# itself has no colour settings. The file is rewritten by wallcolors.py on every
# palette change, in place so the agent's inotify watch stays alive.

set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
WALLCOLORS="$CONFIG/hypr/scripts/wallcolors.py"
CONF="$CONFIG/hypr/hyprtoolkit.conf"

[ -f "$WALLCOLORS" ] || {
    echo "wallcolors.py not found at $WALLCOLORS" >&2
    exit 1
}

python3 - "$WALLCOLORS" <<'PY'
import os
import sys

p = sys.argv[1]
text = open(p).read()

func = '''# ricelin-hyprtoolkit-palette
def _hyprtoolkit_color(color):
    return "0xFF" + color.lstrip("#").upper()


def render_hyprtoolkit(pill):
    """Write the hyprtoolkit palette used by hyprpolkitagent's prompt."""
    conf = (Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
            / "hypr" / "hyprtoolkit.conf")
    icons = (Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
             / "icons" / "Ricelin")
    text = "\\n".join([
        "# Ricelin: hyprtoolkit palette, used by hyprpolkitagent's authentication dialog.",
        "background = " + _hyprtoolkit_color(pill["surface"]),
        "base = " + _hyprtoolkit_color(pill["surface_container_low"]),
        "text = " + _hyprtoolkit_color(pill["cream"]),
        "alternate_base = " + _hyprtoolkit_color(pill["surface_container_high"]),
        "bright_text = " + _hyprtoolkit_color(pill["bright"]),
        "link_text = " + _hyprtoolkit_color(pill["primary"]),
        "accent = " + _hyprtoolkit_color(pill["primary"]),
        "accent_secondary = " + _hyprtoolkit_color(
            pill.get("primary_container", pill.get("outline_variant", pill["primary"]))),
        "rounding_large = 12",
        "rounding_small = 6",
        "font_family = Inter",
        "font_family_monospace = JetBrainsMono Nerd Font",
        "icon_theme = " + ("Ricelin" if icons.is_dir() else ""),
        "",
    ])
    try:
        if conf.read_text() == text:
            return
    except OSError:
        pass
    conf.parent.mkdir(parents=True, exist_ok=True)
    # Write in place: hyprtoolkit watches the inode, and an atomic replace would
    # drop the watch, leaving the next prompt on the old palette.
    conf.write_text(text)


# ricelin-hyprtoolkit-palette-end
'''

start = text.find("# ricelin-hyprtoolkit-palette\n")
if start != -1:
    end = text.find("# ricelin-hyprtoolkit-palette-end\n", start)
    if end == -1:
        sys.exit("hyprtoolkit palette block is not terminated")
    end += len("# ricelin-hyprtoolkit-palette-end\n")
    text = text[:start] + text[end:]

if "\ndef publish(" not in text:
    sys.exit("wallcolors.py did not match the expected layout")
text = text.replace("\ndef publish(", "\n\n" + func + "def publish(", 1)

if "    render_hyprtoolkit(pill)\n" not in text:
    text = text.replace("    render_kde(pill)\n",
                        "    render_kde(pill)\n    render_hyprtoolkit(pill)\n", 1)

if 'if sys.argv[1] == "--hyprtoolkit":' not in text:
    text = text.replace('if sys.argv[1] == "--apps":',
                        'if sys.argv[1] == "--hyprtoolkit":\n'
                        '        try:\n'
                        '            pill = json.loads((CACHE / "colors.json").read_text())\n'
                        '        except (OSError, ValueError):\n'
                        '            pill = STATIC\n'
                        '        render_hyprtoolkit(pill)\n'
                        '        return 0\n'
                        '    if sys.argv[1] == "--apps":', 1)

tmp = p + ".tmp"
with open(tmp, "w") as fh:
    fh.write(text)
os.replace(tmp, p)
PY

# Render from the palette already on disk so the first prompt is already themed.
python3 "$WALLCOLORS" --hyprtoolkit

# An agent started before this config existed has no watch on it. Restart once;
# later palette changes are written in place and picked up without a restart.
if systemctl --user is-active --quiet hyprpolkitagent.service 2>/dev/null; then
    systemctl --user restart hyprpolkitagent.service >/dev/null 2>&1 || true
fi

echo "Polkit prompt: follows the wallpaper palette."
)

stage_portal_scheme() (
set -eu
WALLCOLORS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/wallcolors.py"
[ -f "$WALLCOLORS" ] || exit 0
python3 - "$WALLCOLORS" <<'PY'
import os
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = "# ricelin-portal-scheme\n"
call = '''    # ricelin-portal-scheme: Firefox/Zen and Electron apps follow this portal key live.
    try:
        subprocess.run(["gsettings", "set", "org.x.apps.portal", "color-scheme", scheme],
                       capture_output=True)
    except OSError:
        pass

'''
if "gset(\"color-scheme\", scheme)" not in text:
    raise SystemExit("wallcolors.py: set_scheme anchor not found")
if marker not in text:
    old = "    gset(\"color-scheme\", scheme)\n"
    new = "    gset(\"color-scheme\", scheme)\n\n" + call
    text = text.replace(old, new, 1)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    print("portal colour-scheme hook installed")
else:
    print("portal colour-scheme hook already present")
PY
python3 - <<'PY'
import colorsys
import json
import subprocess
from pathlib import Path

try:
    pill = json.loads((Path.home() / ".cache" / "ricelin" / "colors.json").read_text())
    surface = pill["surface"]
    r, g, b = (int(surface[i:i + 2], 16) / 255 for i in (1, 3, 5))
    light = colorsys.rgb_to_hls(r, g, b)[1] > 0.5
except Exception:
    light = False
scheme = "prefer-light" if light else "prefer-dark"
for schema in ("org.x.apps.portal", "org.gnome.desktop.interface"):
    subprocess.run(["gsettings", "set", schema, "color-scheme", scheme],
                   capture_output=True, check=False)
print("portal colour-scheme:", scheme)
PY
)

# ---------------------------------------------------------------- stage_diff_only_update
stage_diff_only_update() (
# installer stage — make `ricelin update` touch only what upstream changed.
#
# The engine redeployed every upstream file on every apply, so even a one-commit
# update rewrote all of ~/.config/quickshell and hypr/scripts and reverted every
# local edit (leaving a .bak beside each). This replaces that pass with a
# base..head diff: a file upstream did not change is not opened at all, and a file
# upstream did change is three-way merged against the base it was last reconciled
# to, so a local edit in another region survives. An overlapping edit is reported
# as a conflict and the live file is left exactly as the user has it.
#
# The engine is pinned against its own update (NEVER_REWRITE): otherwise the first
# apply would drop this fork back to upstream's wholesale copy and every later
# update would revert local edits again. So this is the one script that does NOT
# need re-running after `ricelin update`.
#
#   sh installer stage              apply (idempotent)
#   sh installer stage --revert     put upstream's engine back, byte for byte
#   sh installer stage --selftest   run the scenario matrix in a temp tree
set -eu

ENGINE="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/ricelin-update.py"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ricelin"
BACKUP="$STATE/24-diff-only-update"
MARKER="ricelin-diff-only-update"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "24-diff-only-update: $*" >&2; exit 1; }

[ -f "$ENGINE" ] || die "update engine not found ($ENGINE)"

marker_present() { grep -q "$MARKER" "$ENGINE" 2>/dev/null; }

# ── selftest ─────────────────────────────────────────────────────────────────
# Runs the installed engine against a throwaway git remote and a throwaway config
# root, and asserts the exact behaviour an update has to have. Kept here so the
# claim can be re-proven after any upstream change to the engine.
if [ "${1:-}" = "--selftest" ]; then
    marker_present || die "engine is not patched; run without --selftest first"
    ENGINE="$ENGINE" python3 - <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path

ENGINE = Path(os.environ["ENGINE"])
root = Path(tempfile.mkdtemp(prefix="ricelin-24-selftest-"))
up, cfg, state, data = root / "upstream", root / "config", root / "state", root / "data"
fails = []

def check(cond, label):
    print(("PASS  " if cond else "FAIL  ") + label)
    if not cond:
        fails.append(label)

def g(*args):
    return subprocess.run(["git", *args], cwd=up, check=True,
                          capture_output=True, text=True).stdout

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def engine(mode, extra=()):
    env = dict(os.environ,
               XDG_CONFIG_HOME=str(root / "xdg-config"),
               XDG_DATA_HOME=str(data),
               XDG_STATE_HOME=str(state),
               PYTHONDONTWRITEBYTECODE="1")
    r = subprocess.run([sys.executable, str(ENGINE), mode,
                        "--config-root", str(cfg), "--remote", str(up), *extra],
                       capture_output=True, text=True, env=env)
    try:
        return json.loads(r.stdout)
    except ValueError:
        print(r.stdout, r.stderr, file=sys.stderr)
        raise

base_files = {
    "quickshell/pill/A.qml": "".join(f"alpha{i}\n" for i in range(1, 11)),
    "quickshell/pill/B.qml": "".join(f"bravo{i}\n" for i in range(1, 31)),
    "quickshell/pill/C.qml": "charlie1\ncharlie2\ncharlie3\n",
    "quickshell/pill/E.qml": "echo1\n",
    "ghostty/config": "theme=one\n",
    "hypr/scripts/ricelin-update.py": "upstream engine v1\n",
    "hypr/modules/binds.lua": "binds v1\n",
}
(up / "configs").mkdir(parents=True)
for rel, text in base_files.items():
    write(up / "configs" / rel, text)
g("init", "-q", "-b", "main")
g("config", "user.email", "selftest@local")
g("config", "user.name", "selftest")
g("add", "-A")
g("commit", "-qm", "base")
c1 = g("rev-parse", "HEAD").strip()

# The live tree as the user has it: two local edits that upstream also touches,
# one local edit upstream leaves alone, a deleted-elsewhere file, a fork of the
# engine, and a plain untouched file.
live = dict(base_files)
live["quickshell/pill/A.qml"] = live["quickshell/pill/A.qml"].replace("alpha3", "ALPHA3 local")
b = live["quickshell/pill/B.qml"].splitlines(True)
b[2] = "BRAVO3 local\n"
live["quickshell/pill/B.qml"] = "".join(b)
c = live["quickshell/pill/C.qml"].splitlines(True)
c[1] = "CHARLIE2 local\n"
live["quickshell/pill/C.qml"] = "".join(c)
live["hypr/scripts/ricelin-update.py"] = "local fork of the engine\n"

for rel, text in live.items():
    write(cfg / rel, text)

# Upstream's next commit: B's far end, C's edited line, ghostty, a new file, a
# deletion, the engine, and (for A) nothing.
new = dict(base_files)
b = new["quickshell/pill/B.qml"].splitlines(True)
b[24] = "BRAVO25 upstream\n"
b.append("bravo31 upstream\n")
new["quickshell/pill/B.qml"] = "".join(b)
c = new["quickshell/pill/C.qml"].splitlines(True)
c[1] = "charlie2 UPSTREAM\n"
new["quickshell/pill/C.qml"] = "".join(c)
new["ghostty/config"] = "theme=two\n"
new["quickshell/pill/D.qml"] = "delta new\n"
new["hypr/scripts/ricelin-update.py"] = "upstream engine v2\n"
del new["quickshell/pill/E.qml"]
for rel, text in new.items():
    write(up / "configs" / rel, text)
(up / "configs" / "quickshell" / "pill" / "E.qml").unlink()
g("add", "-A")
g("commit", "-qm", "next")

write(state / "ricelin" / "update.json", json.dumps({"syncedSha": c1, "modules": {}}))

before = {p.relative_to(cfg): p.read_bytes() for p in cfg.rglob("*") if p.is_file()}
chk = engine("check")
after = {p.relative_to(cfg): p.read_bytes() for p in cfg.rglob("*") if p.is_file()}
check(before == after, "check writes nothing")
check(chk["behind"] == 1 and chk["codeChanged"] is True, "check reports one commit and pending code")
check(chk["conflicts"] == ["quickshell/pill/C.qml"], "check predicts the overlapping edit")

out = engine("apply")
check(out["status"] == "ok" and out["applied"] is True, "apply succeeds")
check(out["conflicts"] == ["quickshell/pill/C.qml"], "conflict list is exactly the overlapping file")
check(out["restartNeeded"] is True, "restart requested for changed shell files")

check((cfg / "quickshell/pill/A.qml").read_text().count("ALPHA3 local") == 1,
      "untouched upstream file keeps its local edit")
check(not (cfg / "quickshell/pill/A.qml.bak").exists(),
      "untouched upstream file gets no .bak")
check("BRAVO3 local" in (cfg / "quickshell/pill/B.qml").read_text()
      and "BRAVO25 upstream" in (cfg / "quickshell/pill/B.qml").read_text(),
      "non-overlapping edit merges both sides")
check((cfg / "quickshell/pill/B.qml.bak").read_text().count("BRAVO3 local") == 1,
      "merge keeps the pre-merge copy as .bak")
check((cfg / "quickshell/pill/C.qml").read_text().count("CHARLIE2 local") == 1,
      "overlapping edit leaves the live file untouched")
check((cfg / "ghostty/config").read_text() == "theme=two\n",
      "unmodified upstream file takes the new content")
check((cfg / "quickshell/pill/D.qml").read_text() == "delta new\n",
      "new upstream file is created")
check((cfg / "quickshell/pill/E.qml").exists(),
      "file dropped upstream is not deleted locally")
check((cfg / "hypr/scripts/ricelin-update.py").read_text() == "local fork of the engine\n",
      "engine never rewrites itself")

second = engine("apply")
check(second["codeChanged"] is False, "second apply writes nothing")
check(second["conflicts"] == ["quickshell/pill/C.qml"],
      "unresolved conflict stays reported")

print(f"\n{root}")
print("SELFTEST " + ("PASSED" if not fails else f"FAILED ({len(fails)})"))
sys.exit(1 if fails else 0)
PY
    exit $?
fi

# ── revert ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--revert" ]; then
    marker_present || { say "already upstream, nothing to revert"; exit 0; }
    snap="$BACKUP/ricelin-update.py"
    [ -f "$snap" ] || die "no snapshot at $snap; cannot restore the upstream engine"
    want=$(cat "$BACKUP/ricelin-update.py.sha256")
    now=$(sha256sum "$ENGINE" | awk '{print $1}')
    # The engine is pinned, so a mismatch means someone edited it by hand: refuse
    # rather than clobber that, and point at the copy to diff against.
    [ "$now" = "$want" ] || die "engine changed since apply (sha $now != $want); diff it against $snap"
    cp -p "$snap" "$ENGINE"
    rm -rf "$BACKUP"
    say "engine restored; the next update redeploys every file again"
    exit 0
fi

# ── apply ────────────────────────────────────────────────────────────────────
if marker_present; then
    say "engine already diff-only"
    say "__CHANGED__ 0"
    exit 0
fi

mkdir -p "$BACKUP"
cp -p "$ENGINE" "$BACKUP/ricelin-update.py"

ENGINE="$ENGINE" MARKER="$MARKER" python3 - <<'PY'
import os, sys
from pathlib import Path

path = Path(os.environ["ENGINE"])
marker = os.environ["MARKER"]
src = path.read_text()
if marker in src:
    print("__CHANGED__ 0")
    sys.exit(0)

DEFAULT_REMOTE = "https://github.com/Gakuseei/Ricelin.git"

# ── 1. the docstring, so the file describes what it now does ─────────────────
doc_start = src.index("The model: keep a dedicated pristine clone")
doc_end = src.index("A manifest records the upstream sha")
src = src[:doc_start] + """The model: keep a dedicated pristine clone that the user never touches, so a pull
is always clean. An apply then touches exactly the files upstream changed between
the recorded base and the new commit; everything else in the tree is not opened at
all, so a local edit to a file upstream left alone survives without a merge. A file
upstream did change is three-way merged against the base it was last reconciled to,
so a personal edit in another region survives that too. An overlapping change is
reported as a conflict and the live file is left exactly as the user had it, with
its base pinned until the conflict is resolved.

""" + src[doc_end:]

src = src[:src.index("import datetime")] + "# " + marker + " — changed-only apply, pinned against self-update\n" + src[src.index("import datetime"):]

src = src.replace(
    "A manifest records the upstream sha each protected file was last reconciled to",
    "A manifest records the upstream sha each touched file was last reconciled to")

# ── 2. the self-pin, or the fork would be erased by its own first apply ──────
anchor = src.index("PROTECTED = [")
anchor = src.index("\n]\n", anchor) + len("\n]\n")
src = src[:anchor] + """
# The engine never rewrites itself. Otherwise the first apply would drop this
# changed-only fork back to upstream's wholesale copy and the next update would
# revert every local edit again.
NEVER_REWRITE = {"hypr/scripts/ricelin-update.py"}
""" + src[anchor:]

# ── 3. the whole reconcile pass ─────────────────────────────────────────────
start = src.index("def reconcile_protected(")
end = src.index("def migrate_hypridle(")
NEW = '''def module_name(rel):
    return Path(rel).stem


def is_binary(data):
    """git's own test for binary: a NUL in the first 8 KiB, which has no line merge."""
    return b"\\0" in data[:8192]


def backup_live(live_path, current):
    """Keep the pre-write bytes beside the file so a merge or a take stays recoverable."""
    if current is not None:
        atomic_write_bytes(live_path.with_name(live_path.name + ".bak"), current)


def reconcile_file(live_path, base, new, take, apply, rel):
    """
    Work out one deployed file's target content, and write it when apply is set.

    base is the upstream content the file was last reconciled to and new the content
    at the target commit, so git merge-file can replay upstream's change onto the
    live copy: a local edit in another region survives, an overlapping one is
    reported instead of guessed at. Returns (state, wrote, conflict).
    """
    current = live_path.read_bytes() if live_path.exists() else None
    if current == new:
        return "clean", False, False
    if current is None:                        # upstream still ships it, locally gone
        if apply:
            atomic_write_bytes(live_path, new)
        return "update", True, False
    if base is None:                           # upstream added a path the user already has
        if rel in take:
            if apply:
                backup_live(live_path, current)
                atomic_write_bytes(live_path, new)
            return "update", True, False
        return "conflict", False, True
    if current == base:                        # no local edit: straight replace
        if apply:
            atomic_write_bytes(live_path, new)
        return "update", True, False
    if is_binary(current) or is_binary(base) or is_binary(new):
        if rel in take:
            if apply:
                backup_live(live_path, current)
                atomic_write_bytes(live_path, new)
            return "update", True, False
        return "conflict", False, True
    merged, clean = merge_file(current, base, new)
    if clean:
        if merged == current:
            return "clean", False, False
        if apply:
            backup_live(live_path, current)
            atomic_write_bytes(live_path, merged)
        return "merged", True, False
    if rel in take:
        if apply:
            backup_live(live_path, current)
            atomic_write_bytes(live_path, new)
        return "update", True, False
    return "conflict", False, True


def upstream_changes(clone, base, head):
    """
    (rel, status) for every configs/ file that differs between two commits, relative
    to configs/. Renames arrive as a delete plus an add (--no-renames), which is what
    the deploy wants: the old path is left alone live, the new one lands.
    """
    out = git(clone, "diff", "--name-status", "--no-renames", base, head, "--", "configs/")
    changes = []
    for line in out.splitlines():
        status, _, rel = line.partition("\\t")
        if rel.startswith("configs/"):
            changes.append((rel[len("configs/"):], status[:1]))
    return changes


def reconcile_files(clone, config_root, manifest, head, synced, apply, take):
    """
    Apply exactly the files upstream changed between the recorded base and head.

    Candidates are that diff, plus any file whose base is pinned behind by an
    unresolved conflict. Everything else is not read or written at all, so a local
    edit to a file upstream left alone survives an update untouched; the old pass
    redeployed the whole tree and reverted every such edit, even on a one-commit
    update.

    The manifest carries a base entry only while a conflict is unresolved: every
    other file derives from the recorded head, so the next update compares against
    the commit it was reconciled to instead of retrying stale ancestors. Returns the
    module rows, the conflict list and whether anything was written.
    """
    bases = manifest.setdefault("modules", {})
    if apply:
        for rel, sha in list(bases.items()):
            if sha == synced:
                del bases[rel]                 # syncedSha already answers for it
    candidates = dict(upstream_changes(clone, synced, head)) if synced else {}
    for rel, sha in list(bases.items()):
        if sha and sha != synced and rel not in candidates:
            candidates[rel] = "M"              # pinned by a conflict: retry it
    conflicts, states = [], {}
    changed = False
    for rel in sorted(candidates):
        status = candidates[rel]
        dest = deploy_dest(rel)
        if status == "D" or dest is None:      # a drop upstream never deletes live data
            if apply:
                bases.pop(rel, None)
            continue
        if rel in NEVER_REWRITE:
            if apply:
                bases.pop(rel, None)           # upstream's copy is never the base here
            continue
        new = show_at(clone, head, rel)
        if new is None:
            if apply:
                bases.pop(rel, None)
            continue
        base_sha = bases.get(rel) or synced
        base = show_at(clone, base_sha, rel) if base_sha else None
        if base is None and status != "A" and synced and base_sha != synced:
            base_sha = synced
            base = show_at(clone, synced, rel)
        state, wrote, conflict = reconcile_file(config_root / dest, base, new, take, apply, rel)
        changed = changed or wrote
        if conflict:
            conflicts.append(rel)
        if apply:
            if conflict:
                bases[rel] = base_sha or head   # hold the ancestor until it is resolved
            else:
                bases.pop(rel, None)            # head is the base for everything else
        if rel in PROTECTED:
            states[rel] = state
    rows = [{"name": module_name(rel), "path": rel, "state": states.get(rel, "clean")}
            for rel in PROTECTED]
    return rows, conflicts, changed


def deploy_all(clone, config_root, head, apply):
    """
    First run only: with no recorded base there is no way to tell a local edit from
    upstream's, so every deployed file is replaced and a differing live file is kept
    as <file>.bak.
    """
    changed = False
    for rel in tracked_config_files(clone, head):
        dest = deploy_dest(rel)
        if dest is None or rel in NEVER_REWRITE:
            continue
        new = show_at(clone, head, rel)
        if new is None:
            continue
        live_path = config_root / dest
        current = live_path.read_bytes() if live_path.exists() else None
        if current == new:
            continue
        changed = True
        if apply:
            backup_live(live_path, current)
            atomic_write_bytes(live_path, new)
    return changed


'''
src = src[:start] + NEW + src[end:]

# ── 4. run(): first run deploys everything, later runs reconcile the diff ────
first = "        code_changed = sync_code(clone, config_root, head, apply)\n"
if src.count(first) != 1:
    sys.exit("24-diff-only-update: first-run anchor moved; refusing to patch")
src = src.replace(first, "        code_changed = deploy_all(clone, config_root, head, apply)\n")

old = """    rows, conflicts, sha_updates = reconcile_protected(
        clone, config_root, manifest, head, apply, take)
    code_changed = sync_code(clone, config_root, head, apply, base)
"""
new = """    rows, conflicts, code_changed = reconcile_files(
        clone, config_root, manifest, head, base, apply, take)
"""
if src.count(old) != 1:
    sys.exit("24-diff-only-update: apply anchor moved; refusing to patch")
src = src.replace(old, new)

stale = "        manifest.setdefault(\"modules\", {}).update(sha_updates)\n"
if src.count(stale) != 1:
    sys.exit("24-diff-only-update: manifest anchor moved; refusing to patch")
src = src.replace(stale, "")

path.write_text(src)
print("__CHANGED__ 1")
PY

marker_present || die "patch reported success but the marker is missing"
sha256sum "$ENGINE" | awk '{print $1}' > "$BACKUP/ricelin-update.py.sha256"

python3 -m py_compile "$ENGINE" || die "patched engine does not compile"
"$ENGINE" check >/dev/null 2>&1 || true   # smoke: a missing network is not a patch failure

say "engine patched; updates now apply the upstream diff only"
say "diff it against the snapshot: $BACKUP/ricelin-update.py"
)


main "$@"
