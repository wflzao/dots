#!/usr/bin/env python3
"""Render the live Ricelin palette into Hermes and keep its desktop customisation
in user space.

The generated skin is used by the default desktop window. HUD and Quick Entry
are deliberately out of scope: every rule here is scoped to a root without
their window markers, so neither surface can inherit this theme if it returns.
The same skin hides the HUD/Quick Entry controls and keeps the send / start
voice CTA on the system accent.

The behavioural switches live in Hermes's own user configuration, never in its
source tree: Quick Entry and the HUD modifier tap are persisted off, and the
HUD keyboard chord is unbound in the machine UI-preferences store. Text-only
leftovers (the keybind rows) are hidden by the companion `ricelin-desktop`
runtime plugin installed by install.sh.

Run by the `ricelin-hermes-skin.path` user unit whenever the wallpaper palette
changes. It writes user files and does not call Hermes.
"""
import json
import os
import secrets
import shutil
import sys
import time
from pathlib import Path

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "ricelin"
HERMES_HOME = Path(os.environ.get("HERMES_HOME") or HOME / ".hermes")
SKIN = HERMES_HOME / "skins" / "ricelin.yaml"
PALETTE = CACHE / "colors.json"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
QUICK_ENTRY = CONFIG_DIR / "Hermes" / "quick-entry.json"
HUD_MODIFIER = CONFIG_DIR / "Hermes" / "hud-modifier.json"
UI_PREFERENCES = HERMES_HOME / "ui-preferences.json"

DEFAULTS = {
    "surface": "#e9f4ff",
    "surface_container_low": "#dfefff",
    "surface_container": "#d6ebff",
    "surface_container_high": "#d1e6fa",
    "surface_container_highest": "#cadff2",
    "outline_variant": "#a9c2da",
    "primary": "#617e00",
    "outline": "#657889",
    "cream": "#1e2831",
    "bright": "#0a131b",
    "subtle": "#444e59",
    "dim": "#626d78",
    "faint": "#707c87",
}

CSS = """:root:not([data-hud-window]):not([data-quick-entry-window]) {
  --ricelin-surface: {surface};
  --ricelin-surface-low: {surface_container_low};
  --ricelin-surface-container: {surface_container};
  --ricelin-surface-high: {surface_container_high};
  --ricelin-surface-highest: {surface_container_highest};
  --ricelin-outline: {outline};
  --ricelin-outline-variant: {outline_variant};
  --ricelin-primary: {primary};
  --ricelin-on-surface: {cream};
  --ricelin-bright: {bright};
  --ricelin-subtle: {subtle};
  --ricelin-dim: {dim};
  --ricelin-faint: {faint};

  --dt-font-sans: 'Inter', 'Inter Variable', 'Noto Sans', system-ui, sans-serif !important;
  --dt-font-mono: 'JetBrainsMono Nerd Font', 'JetBrainsMono NL Nerd Font', 'JetBrains Mono', ui-monospace, monospace !important;
  --radius-scalar: 0.9;
  --ui-selection-background: color-mix(in srgb, var(--ricelin-primary) 28%, transparent);

  --ui-bg-primary: var(--ricelin-surface);
  --ui-bg-secondary: var(--ricelin-surface-low);
  --ui-bg-tertiary: var(--ricelin-surface-container);
  --ui-bg-elevated: var(--ricelin-surface-low);
  --ui-bg-chrome: var(--ricelin-surface-low);
  --ui-bg-sidebar: var(--ricelin-surface-low);
  --ui-chat-surface-background: var(--ricelin-surface);
  --ui-chat-bubble-background: var(--ricelin-surface-container);
  --ui-terminal-surface-background: var(--ricelin-surface);
  --ui-text-primary: var(--ricelin-on-surface);
  --ui-text-secondary: var(--ricelin-subtle);
  --ui-text-tertiary: var(--ricelin-dim);
  --ui-stroke-secondary: color-mix(in srgb, var(--ricelin-outline) 48%, transparent);

  --dt-background: var(--ricelin-surface);
  --dt-foreground: var(--ricelin-on-surface);
  --dt-card: var(--ricelin-surface-low);
  --dt-card-foreground: var(--ricelin-on-surface);
  --dt-popover: var(--ricelin-surface-low);
  --dt-popover-foreground: var(--ricelin-on-surface);
  --dt-muted-foreground: var(--ricelin-subtle);
  --dt-secondary-foreground: var(--ricelin-subtle);
  --dt-border: color-mix(in srgb, var(--ricelin-outline) 45%, transparent);
  --dt-input: color-mix(in srgb, var(--ricelin-surface-low) 88%, transparent);
  --dt-primary: var(--ricelin-primary);
  --dt-ring: var(--ricelin-primary);
  --dt-composer-ring: var(--ricelin-primary);
  --dt-sidebar-bg: var(--ricelin-surface-low);
  --dt-sidebar-border: color-mix(in srgb, var(--ricelin-outline) 38%, transparent);
  --dt-user-bubble: color-mix(in srgb, var(--ricelin-primary) 12%, var(--ricelin-surface-container));
  --dt-user-bubble-border: color-mix(in srgb, var(--ricelin-primary) 22%, transparent);
}

/* The send / start-voice CTA is the system accent, not a foreground-black
   circle. The desktop ships this as a foreground-on-background button; the
   skin is the one supported place to restyle it, so an app update cannot put
   the black circle back. */
:root:not([data-hud-window]):not([data-quick-entry-window]) [data-slot='composer-root'] button[class*='bg-foreground'] {
  background-color: var(--ricelin-primary) !important;
  color: #fff !important;
}

/* Hide the leftover HUD and Quick Entry affordances. The features themselves
   are switched off in Hermes's user configuration below; these controls have
   no per-user visibility setting, so the skin removes them from the shell. */
:root:not([data-hud-window]):not([data-quick-entry-window]) [data-titlebar-cluster] button:has(i.codicon-comment-discussion),
:root:not([data-hud-window]):not([data-quick-entry-window]) [data-tour='nav-keybinds:hud-gesture'],
:root:not([data-hud-window]):not([data-quick-entry-window]) [id='setting-field-keybinds.hud-modifier'],
:root:not([data-hud-window]):not([data-quick-entry-window]) [id='setting-field-advanced.quick-entry'],
:root:not([data-hud-window]):not([data-quick-entry-window]) [id='setting-field-advanced.quick-entry-shortcut'] {
  display: none !important;
}
"""


def palette():
    values = dict(DEFAULTS)
    try:
        data = json.loads(PALETTE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return values
    if isinstance(data, dict):
        values.update({k: v for k, v in data.items() if isinstance(v, str)})
    return values


def skin_text(p):
    colors = {
        "background": p["surface"],
        "ui_text": p["cream"],
        "ui_accent": p["primary"],
        "ui_primary": p["bright"],
        "banner_accent": p["primary"],
        "banner_title": p["bright"],
        "banner_border": p["outline_variant"],
        "banner_text": p["cream"],
        "banner_dim": p["subtle"],
        "ui_border": p["outline_variant"],
        "ui_label": p["subtle"],
        "ui_error": "#b3261e",
        "ui_warn": "#9a6700",
        "ui_ok": "#3f7d00",
        "prompt": p["bright"],
        "input_rule": p["outline_variant"],
        "response_border": p["primary"],
        "selection_bg": p["surface_container_highest"],
        "status_bar_bg": p["surface"],
        "status_bar_text": p["cream"],
        "status_bar_strong": p["primary"],
        "status_bar_dim": p["subtle"],
        "status_bar_good": "#3f7d00",
        "status_bar_warn": "#9a6700",
        "status_bar_bad": "#b3261e",
        "status_bar_critical": "#b3261e",
        "voice_status_bg": p["surface_container"],
        "completion_menu_bg": p["surface_container_low"],
        "completion_menu_current_bg": p["surface_container"],
        "completion_menu_meta_bg": p["surface"],
        "completion_menu_meta_current_bg": p["surface_container_low"],
    }

    lines = [
        "# ricelin — generated by ~/.config/hypr/scripts/ricelin-hermes.py",
        "name: ricelin",
        "description: Ricelin palette for the Hermes desktop.",
        "colors:",
    ]
    lines += [f'  {key}: "{value}"' for key, value in colors.items()]

    css = CSS
    for key, value in p.items():
        css = css.replace("{" + key + "}", value)

    lines += ["customCSS: |"]
    lines += ["  " + line for line in css.splitlines()]
    return "\n".join(lines) + "\n"


def _read_json(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def disable_quick_entry():
    """Persist Quick Entry off, keeping the last chord for a clean re-enable."""
    current = _read_json(QUICK_ENTRY) or {}
    shortcut = current.get("shortcut")
    if not isinstance(shortcut, str) or not shortcut.strip():
        shortcut = "CommandOrControl+Shift+Space"
    settings = {**current, "enabled": False, "shortcut": shortcut}
    if current == settings:
        return False
    _write_json(QUICK_ENTRY, settings)
    return True


def disable_hud_modifier():
    """Persist the HUD modifier-tap permission off."""
    current = _read_json(HUD_MODIFIER) or {}
    settings = {**current, "enabled": False}
    if current == settings:
        return False
    _write_json(HUD_MODIFIER, settings)
    return True


def _lock_ui_preferences():
    """Take the same ``<store>.lock`` directory lock the desktop/Python writers use."""
    lock = UI_PREFERENCES.with_name(f"{UI_PREFERENCES.name}.lock")
    token = f"{os.getpid()}-{secrets.token_hex(8)}"
    deadline = time.monotonic() + 3.0
    while True:
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            try:
                stale = time.time() - lock.stat().st_mtime > 10.0
            except FileNotFoundError:
                continue
            if stale:
                shutil.rmtree(lock, ignore_errors=True)
                continue
            if time.monotonic() > deadline:
                raise RuntimeError("Hermes UI preferences are busy")
            time.sleep(0.02)
    (lock / "owner").write_text(token, encoding="utf-8")
    return lock, token


def _unlock_ui_preferences(lock, token):
    try:
        owner = (lock / "owner").read_text(encoding="utf-8")
    except OSError:
        return
    if owner == token:
        shutil.rmtree(lock, ignore_errors=True)


def _read_ui_preferences():
    try:
        doc = json.loads(UI_PREFERENCES.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"corrupt": False, "exists": False, "generation": "", "revision": 0, "values": {}}
    except (OSError, ValueError):
        return {"corrupt": True, "exists": False, "generation": "", "revision": 0, "values": {}}
    if not isinstance(doc, dict):
        return {"corrupt": True, "exists": False, "generation": "", "revision": 0, "values": {}}
    values = doc.get("values")
    values = values if isinstance(values, dict) else {}
    return {
        "corrupt": False,
        "exists": True,
        "generation": doc.get("generation") if isinstance(doc.get("generation"), str) else "",
        "revision": doc.get("revision") if isinstance(doc.get("revision"), int) else 0,
        "values": {k: v for k, v in values.items() if isinstance(k, str) and isinstance(v, str)},
    }


def _write_ui_preferences(payload):
    tmp = UI_PREFERENCES.with_name(f".{UI_PREFERENCES.name}.{os.getpid()}.{int(time.time() * 1000)}")
    tmp.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, UI_PREFERENCES)


def unbind_hud_keybind():
    """Clear the HUD chord in the machine UI-preferences store the app reads."""
    lock, token = _lock_ui_preferences()
    try:
        current = _read_ui_preferences()
        if current["corrupt"] and UI_PREFERENCES.exists():
            backup = UI_PREFERENCES.with_name(f"{UI_PREFERENCES.name}.corrupt-{int(time.time() * 1000)}")
            shutil.copy2(UI_PREFERENCES, backup)
        values = dict(current["values"])
        raw = values.get("hermes.desktop.keybinds")
        try:
            bindings = json.loads(raw) if raw else {}
        except ValueError:
            bindings = {}
        if not isinstance(bindings, dict):
            bindings = {}
        bindings["view.toggleHud"] = []
        encoded = json.dumps(bindings, separators=(",", ":"))
        if current["exists"] and raw == encoded:
            return False
        values["hermes.desktop.keybinds"] = encoded
        # A write from another process may have replaced the lock; never clobber it.
        try:
            if (lock / "owner").read_text(encoding="utf-8") != token:
                return False
        except OSError:
            return False
        _write_ui_preferences(
            {
                "version": 1,
                "generation": current["generation"] or secrets.token_hex(8),
                "revision": current["revision"] + 1,
                "values": values,
            }
        )
        return True
    finally:
        _unlock_ui_preferences(lock, token)


def apply_desktop_preferences():
    """Apply every switch independently: a busy app config must not stop the skin."""
    changed = []
    for apply, path in (
        (disable_quick_entry, QUICK_ENTRY),
        (disable_hud_modifier, HUD_MODIFIER),
        (unbind_hud_keybind, UI_PREFERENCES),
    ):
        try:
            if apply():
                changed.append(path)
        except (OSError, RuntimeError) as error:
            print(f"ricelin-hermes: could not update {path}: {error}", file=sys.stderr)
    return changed


def main():
    text = skin_text(palette())
    changed = apply_desktop_preferences()
    for path in changed:
        print(f"ricelin-hermes: updated {path}")
    try:
        if SKIN.read_text(encoding="utf-8") == text:
            print(f"ricelin-hermes: {SKIN} already current")
            return 0
    except OSError:
        pass
    SKIN.parent.mkdir(parents=True, exist_ok=True)
    tmp = SKIN.with_name(f".{SKIN.name}.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, SKIN)
    print(f"ricelin-hermes: wrote {SKIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
