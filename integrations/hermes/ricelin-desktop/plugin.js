/**
 * Ricelin desktop integration.
 *
 * The feature switches themselves live in Hermes's user configuration:
 * `ricelin-hermes.py` persists Quick Entry and the HUD modifier off and clears
 * the HUD chord. This tiny runtime plugin only finishes the UI: it hides the
 * leftover keybind rows whose labels mention HUD (the app has no per-action
 * visibility setting, and CSS cannot select by text).
 *
 * It sweeps only while Settings is open, so chat streaming never pays for it.
 * Installed to `~/.hermes/desktop-plugins/ricelin-desktop/plugin.js` by the
 * Hermes desktop stage in install.sh. It is user-space code: no Hermes source
 * file is modified, and disabling this plugin only restores the rows.
 */

const HIDDEN_ROW = /\b(?:HUD|Quick Entry)\b/i

const settingsOpen = () => `${location.hash}${location.pathname}`.includes('/settings')

export default {
  id: 'ricelin-desktop',
  name: 'Ricelin desktop',
  description: 'Keeps the HUD and Quick Entry controls out of the shell while Ricelin disables those features.',
  defaultEnabled: true,

  register(ctx) {
    const hidden = new Set()

    const sweep = () => {
      if (!settingsOpen()) {
        return
      }

      // Keybind rows are either interactive (`div.group`) or fixed readonly
      // rows; both put their label in a truncating span, so the label is the
      // stable anchor.
      for (const label of document.querySelectorAll("span[class*='truncate']")) {
        const text = (label.textContent ?? '').trim()

        if (!HIDDEN_ROW.test(text)) {
          continue
        }

        const row = label.closest('div.group') ?? label.parentElement

        if (row && !hidden.has(row)) {
          hidden.add(row)
          row.style.setProperty('display', 'none', 'important')
        }
      }
    }

    ctx.setInterval(sweep, 250)
    ctx.onDispose(() => {
      for (const row of hidden) {
        row.style.removeProperty('display')
      }

      hidden.clear()
    })
    sweep()
  }
}
