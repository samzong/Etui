# Etui

<img src="Resources/logo.svg" alt="Etui" width="64" height="64">

A macOS launcher, clipboard history, window tiler, translator, and screenshot tool built with Swift and AppKit. Requires macOS 26 or later. The name is the French *étui*: a small case made to hold and keep those tools.

`make install` builds and opens `/Applications/Etui.app` and registers it as a login item. `make uninstall` removes it, `make dmg` writes a disk image to `.local/dist`, and `make check` runs the tests. Pasting, translating selections, tiling, and window search need Accessibility access.

| Shortcut | Action |
|---|---|
| ⌘Space | Launcher |
| ⌘⇧V | Clipboard history |
| ⇧⌥; / ⇧⌥' | Tile window left / right; repeat to cycle 1/2, 2/3, 1/3, full |
| ⇧⌥[ / ⇧⌥] | Move window to previous / next screen |
| ⌥D / ⌥A | Translate selection / open empty translator |
| ⌃⌘A | Capture an area or window |

The launcher lists apps, Finder, and System Settings panes. Search matches exact, prefix, and word-prefix, then ranks by usage; launching learns the typed query as an alias. List bundle identifiers in `hidden.json` to hide entries.

Search `awake` to toggle Keep Awake, which starts enabled and prevents idle display and system sleep while Etui runs. Search `lid` for the separate Keep Running with Lid Closed setting. It requires administrator authorization and changes the system-wide `pmset disablesleep` setting on battery and power, including manual Sleep, and can block software sleep for low battery or overheating. The launcher reads the actual kernel state each time it opens and verifies each change. This setting stays enabled after quitting Etui or restarting; search `lid` and select Allow Sleep with Lid Closed to turn it off before putting your Mac in a bag. Cancelling authorization leaves the setting unchanged. No background service is installed.

To turn it off without Etui, including after uninstalling, run `sudo pmset -a disablesleep 0` in Terminal. This restores system sleep; idle display and system sleep may still be prevented by Keep Awake or other apps.

Search `clean mac` to reclaim space in one step, with no preview and no confirmation: app caches under `~/Library/Caches`, the npm `npx` cache, Lark `Service Worker/CacheStorage` leftovers, the Trash, old Claude Code versions, and bounded Docker pruning on the `colima` builder. Caches it cannot vouch for (Go build cache, Playwright browsers, sccache, Apple compiled-model caches, proxy and VPN state) are never touched, and any candidate that resolves outside its own root is skipped. Each run appends one line to `~/Library/Application Support/Etui/clean.jsonl`, including the paths it removed and any failure.

When a running app has multiple windows, on every Space, they are searchable by title and listed below the app's row; selecting one switches to that window. Open Google Chrome tabs are searchable by title and site and listed below Chrome's row in place of its windows; selecting one switches to that tab, and macOS asks once for permission to control Chrome. Combe tabs are listed the same way in place of its windows. Window discovery uses private macOS APIs and may need updates after macOS changes.

The clipboard panel keeps text and images for 48 hours, skips concealed clips, and pastes with Return or ⌘1–⌘9.

Screenshots need Screen & System Audio Recording access. Press ⌃⌘A, choose Area to drag a selection or Window to click a highlighted window. Drag inside the selection to move it, or drag its handles to resize. The glass toolbar switches between Area, Window, and Scroll. Copy captures the selection directly into clipboard history. For scrolling captures, select Scroll, keep fixed headers, sidebars, and scrollbars outside the selection, then click Start. Hold still until the first frame settles; scroll down slowly and pause between movements. The live preview shows the accepted content. Finish checks the final frame and copies the PNG directly into clipboard history. Cancel discards the capture. The area must stay visible and stationary. Captures stop growing at 40 million pixels. Missing overlap, upward scrolling, animations, and ambiguous repeating content can prevent stitching; scroll back to the last accepted position before continuing.

Translation uses any OpenAI-compatible endpoint configured in `translate.json`:

```json
{
  "base": "https://api.openai.com/v1",
  "key": "sk-...",
  "model": "gpt-4o-mini",
  "extra": {},
  "styles": [
    { "name": "Plain", "prompt": "Translate between Chinese and English." },
    { "name": "Sharp", "prompt": "Translate concisely.", "model": "gpt-4o", "extra": { "reasoning_effort": "low" } }
  ]
}
```

Only `key` is required; `base` and `model` default to DeepSeek. `extra` is merged into the request body, and a style's `model` and `extra` override the top-level ones.

Pinyin (拼音 on a Chinese system) is a Chinese input method built on [librime](https://github.com/rime/librime) and [rime-ice](https://github.com/iDvel/rime-ice). It learns from your selections and uses English punctuation. Run `make install-ime`, then add Pinyin under System Settings > Keyboard > Input Sources > + > Chinese, Simplified. Press Shift to switch between Chinese and English in every app; 中 or 英 flashes at the cursor. Control-Delete removes a learned word; `make uninstall-ime` removes Pinyin.

Data lives in `~/Library/Application Support/Etui`: `aliases.json`, `usage.json`, `hidden.json`, `translate.json`, `clipboard/`, and `rime/`, where the input method keeps learned words.
