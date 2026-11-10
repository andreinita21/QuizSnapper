# QuizSnapper 2

Menu bar app for macOS 14+: press a shortcut, the question on screen goes to the AI model of your choice, the answer shows up in the menu bar and in a small floating overlay.

## Build & run

```bash
./build.sh                      # release build → ~/Applications/QuizSnapper.app, then launch
./build.sh --debug              # debug build
./build.sh --no-install         # only build (no install/launch)
./build.sh --reset-permissions  # forget the Screen Recording grant (to re-test onboarding)
tools/selftest/run.sh           # provider clients vs. a mock API, answer parsing, URL + image limits
```

The bundle is assembled in `~/Library/Caches/QuizSnapper/build`: this project lives on an iCloud-synced Desktop, and iCloud tags files with attributes that `codesign` rejects.

The app is signed with your **Apple Development** certificate (or `SIGN_IDENTITY=…`). macOS ties privacy permissions to the code signature, so a stable signature means you grant Screen Recording **once** and it survives every rebuild. (The old `run.sh` signed ad-hoc, so macOS forgot the permission each time.)

Open a settings pane directly: `open ~/Applications/QuizSnapper.app --args -openSettings profiles`
(`general`, `profiles`, `providers`, `shortcuts`, `disguise`, `permissions`, `history`, `about`).

## Concepts

- **Providers**: where requests go. Claude (Messages API), OpenAI, Gemini, OpenRouter, LM Studio, Ollama, or any OpenAI-compatible server. API keys live in the macOS Keychain.
- **Profiles**: a prompt + a provider + a model + reasoning effort + max output tokens (or *unlimited*) + how the answer shows in the menu bar. Each profile can have its own global shortcut.
- **Screenshot stack**: collect several screenshots (full screen or a region) and send them as one request. Images are labelled "Image 1 of N" so the model keeps the order.

## Disguise mode (Settings → Disguise)

The menu bar icon can pretend to be Weather, Battery (real level), Wi‑Fi, Keyboard layout (fully working), a CPU/RAM monitor (live data), VPN, iCloud, any SF Symbol, text, an invisible gap, or your own image / an installed app's icon (Teams, Notion…).

- A plain click shows a convincing fake menu; a secret click (⌥‑click by default, configurable) opens QuizSnapper. The global shortcuts always work.
- Status signals: each theme changes in its own natural way while working and when the answer is ready (e.g. Wi‑Fi goes from 2 bars to full, weather turns sunny, iCloud shows a checkmark). Or use a custom icon for just one state.
- Answer flash: when the answer is multiple choice, the disguise is replaced by the bare letters (`B`, `A,C`, `1:B 2:A,D`) for a moment — 2 seconds by default, Off/1/2/3/5s in Settings → Disguise — then the icon goes back to normal.
- Fill‑in questions (text boxes instead of options) can't fit in the menu bar: every value goes to the clipboard in order, joined with `; `, ready to paste, and the icon flashes a clipboard glyph instead. The overlay and panel show the same values with a *Copy values* button.
- Locked yourself out? Open QuizSnapper again from Spotlight/Finder — that opens Settings.

## Default shortcuts (all customizable)

| Action | Shortcut |
|---|---|
| Snap screen & ask (also sends what's in the stack) | ⇧⌘X |
| Select region & ask | ⌃⌥⌘X |
| Add screen to stack | ⌃⌥⌘A |
| Add region to stack | ⌃⌥⌘R |
| Send stack | ⌃⌥⌘↩ |
| Clear stack | ⌃⌥⌘⌫ |
| Open / close panel | ⌃⌥⌘P |
| Next profile | ⌃⌥⌘N |
| Hide answer overlay | ⌃⌥⌘H |
| Toggle disguise | (unset) |

Shortcuts use the system hotkey API, so no Accessibility / Input Monitoring permission is needed.

## Permissions

- **Screen Recording** — required. The setup assistant requests it, watches until it's on, offers a relaunch if macOS needs one, then moves on.
- **Notifications** — optional, only for the "notify with answer" option.

## Files

- Settings: `~/Library/Application Support/QuizSnapper/settings.json`
- History: `~/Library/Application Support/QuizSnapper/history.json`
- Logs: `~/Library/Logs/QuizSnapper/QuizSnapper.log`

## Layout

```
Sources/QuizSnapper/
  App/          entry point, AppDelegate (windows, menu, wiring)
  Core/         models, settings store, AppModel (capture stack + requests), answer parsing
  Providers/    AnthropicClient, OpenAICompatibleClient (SSE streaming)
  Capture/      ScreenCaptureKit capture, region selector, image encoding
  Hotkeys/      Carbon hotkeys, KeyCombo
  Permissions/  permission status / requests / relaunch
  UI/           menu bar panel, HUD, settings, onboarding
Support/        Info.plist, AppIcon.icns
```
