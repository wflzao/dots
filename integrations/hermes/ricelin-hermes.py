#!/usr/bin/env python3
"""Render the live Ricelin palette into Hermes's skin.

The generated skin is used by the default desktop window. HUD and Quick Entry
are deliberately out of scope: every rule here is scoped to a root without
their window markers, so neither surface can inherit this theme if it returns.

Run by the `ricelin-hermes-skin.path` user unit whenever the wallpaper palette
changes. It writes one file and does not call Hermes.
"""
import json
import os
import sys
from pathlib import Path

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "ricelin"
HERMES_HOME = Path(os.environ.get("HERMES_HOME") or HOME / ".hermes")
SKIN = HERMES_HOME / "skins" / "ricelin.yaml"
PALETTE = CACHE / "colors.json"

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


def main():
    text = skin_text(palette())
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
