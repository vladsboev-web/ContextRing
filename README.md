# ContextRing for Antigravity 2.0

[![Version](https://img.shields.io/badge/version-1.0.0-orange)](https://github.com/vladsboev-web/ContextRing/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B%20(Universal)-black)](https://github.com/vladsboev-web/ContextRing)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Native macOS (Swift / AppKit / SwiftUI) floating context ring and menu bar monitor for **Google Antigravity 2.0** (`com.google.antigravity`).

> **Looking for a lightweight in-IDE plugin instead?**  
> If you don't need a macOS floating overlay or want cross-platform support (macOS / Linux / Windows) with a Sidecar panel + instant 0-token `/ctx` and `/чат` commands inside Antigravity, see the standalone plugin: **[chat_tokens](https://github.com/vladsboev-web/chat_tokens)**.

---

## Features / Возможности

- **Floating Context Ring / Плавающее кольцо поверх Antigravity**
  - Tracks active Antigravity 2.0 windows across desktops, Spaces, and macOS Fullscreen.
  - Three visual styles (**Classic**, **Minimal**, **Codex**) with **Auto / Light / Dark** theme sync (`app_storage.json`).
  - Automatic scaling linked to Antigravity zoom level (`zoomLevel`), plus independent size, stroke, and font sliders.
  - **2-nearest-edge** per-window anchoring (separate anchors for Windowed and Fullscreen modes) or **Free on screen** absolute positioning.
  - Neutral `—` state when switching to an older/empty chat without token logs.

- **Hover Tooltip & Click Popover / Карточка при наведении и окне по клику**
  - **Context & Stats tabs**: live context usage bar alongside local usage totals for the current chat and all chats (**24h / 7d**).
  - **Context breakdown**: 4-category estimate (*System & rules*, *Tools & files*, *Assistant & thinking*, *User messages*) + output tokens & top tools summary.
  - **Messages / Steps toggle**: mode-aware metrics — *Primary model* (plus `+N` other models), *Last message / step delta*, *Cache hit ratio*, and *Messages / Steps vs. Peak*.
  - **Compaction detection**: detects `CHECKPOINT` events and sudden context drops, displaying `⚡ compacted` badges and alerts.
  - **1-click recent chat switcher** (last 10 chats) with automatic rebind back to the active Antigravity chat when switching tabs.
  - **1-click `HANDOFF.md` prompt copy** to wrap up long sessions cleanly before auto-compaction.

- **Unified Settings Window & Native Launch / Единое окно настроек и автозапуск**
  - Context threshold presets (`128k`, `160k`, `200k`, `256k`, `1M`) plus custom threshold input (`300k`, `500000`, `1.5M`).
  - Optional Accessibility (`AX`) one-click snap above Antigravity's Send button when exposed.
  - Automatic **RU / EN** localization (`System`, `Русский`, `English`).
  - Three launch modes:
    - **With Antigravity** — managed via native macOS `LaunchAgent` (`WatchPaths` on Antigravity support files): launches only when Antigravity starts and quits completely on exit (**zero background process when Antigravity is closed**).
    - **With macOS** — native Login Item (`SMAppService`): waits quietly in the menu bar and shows the ring whenever Antigravity opens.
    - **Manual** — no auto-launch; quits when Antigravity closes.

---

## Requirements / Требования

- **macOS 13.0+** (Ventura or newer; Universal Binary supports Apple Silicon `arm64` and Intel `x86_64`)
- **Google Antigravity 2.0**
- **Xcode Command Line Tools** (`swiftc`) — only needed if building from source (`xcode-select --install`)

---

## Installation / Установка

### From Source / Из исходников

```bash
git clone https://github.com/vladsboev-web/ContextRing.git
cd ContextRing

# Optional: create a local code-signing certificate once so macOS Accessibility
# permission stays valid across rebuilds
./setup_signing_cert.sh

# Build & install to /Applications/ContextRing.app
./install.sh
```

To build & install a Universal Binary (`x86_64 + arm64`):

```bash
./install.sh --universal
```

### Accessibility Permission / Права Accessibility

For reliable Antigravity window title/fullscreen tracking and optional Send-button snapping, grant **Accessibility** permission to `ContextRing`:

- **English:** `System Settings → Privacy & Security → Accessibility → ContextRing`
- **Русский:** `Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → ContextRing`

---

## Building & Uninstalling / Сборка и удаление

### Build Only / Только сборка (`build/ContextRing.app`)

```bash
./build.sh               # Native architecture
./build.sh --universal   # Universal Binary (x86_64 + arm64)
```

### Uninstall / Удаление

```bash
./uninstall.sh                 # Removes /Applications/ContextRing.app and LaunchAgent
./uninstall.sh --purge-prefs   # Also deletes saved UserDefaults preferences
```

---

## Project Layout / Структура проекта

```text
ContextRing/
├── Sources/
│   ├── main.swift                      # Application entry point
│   ├── AppDelegate.swift               # Lifecycle, panels, positioning, menu bar, launch modes
│   ├── Models.swift                    # State models, breakdown & threshold helpers
│   ├── Localization.swift              # RU/EN localization & HANDOFF prompts
│   ├── AntigravityDataReader.swift     # Read-only SQLite + transcript JSONL + app_storage reader
│   ├── AntigravityWindowTracker.swift  # NSWorkspace / CGWindowList / AXObserver window tracking
│   ├── LaunchAgentManager.swift        # Native macOS LaunchAgent (WatchPaths) manager
│   ├── RingPanel.swift                 # Borderless floating ring overlay
│   ├── HoverTooltipPanel.swift         # Compact hover tooltip card
│   ├── DetailPopoverPanel.swift        # Context & Stats detail popover + 1-click chat switcher
│   └── SettingsWindow.swift            # Unified SwiftUI settings window
├── Resources/
│   └── Info.plist                      # App bundle metadata (macOS 13+, LSUIElement)
├── build.sh                            # Build script (native / --universal)
├── install.sh                          # Install to /Applications/ContextRing.app
├── uninstall.sh                        # Clean uninstall (optional --purge-prefs)
├── setup_signing_cert.sh               # Optional 10-year self-signed local cert generator
└── LICENSE                             # MIT License
```

---

## Privacy & Security / Приватность

- **100% local:** zero network requests, zero telemetry, zero API calls.
- **Read-only access** to local Antigravity data:
  - `~/.gemini/antigravity/conversation_summaries.db`
  - `~/.gemini/antigravity/brain/<conversationId>/.system_generated/logs/`
  - `~/Library/Application Support/Antigravity/app_storage.json`
- Preferences are stored locally in standard macOS `UserDefaults` (`com.vladsboev.contextring`).

---

## Authors / Авторы

- **vladsboev-web** — idea, architecture, and product direction
- **Antigravity (Google DeepMind)** — co-author & implementation

---

## License

[MIT](LICENSE)
