# CodexGateway — architecture reference

**Read this first in every new chat.** Canonical map of how CodexGateway works. `AGENTS.md` points here; `.cursor/rules/` add file-specific conventions.

---

## What CodexGateway is

CodexGateway is a **menu-bar macOS app** (AppKit) that runs an embedded **gateway** on `http://127.0.0.1:8765`. Codex Desktop routes model requests through it for third-party model translation and config management.

| CodexGateway owns | Codex Desktop owns |
|-------------------|-------------------|
| Loopback HTTP gateway (`/v1/*`, `/health`, `/api/restart-codex`) | Chat UI, sessions, tool execution |
| Responses ↔ Chat Completions translation | Official OpenAI / ChatGPT pass-through usage |
| `~/.codexgateway/` catalog + providers | User auth (`~/.codex/auth.json`) |
| `~/.codex/config.toml` managed block | Agent runtime |
| Menu bar status + native settings window | |
| In-app updates (notarized GitHub releases) | |

**Platform:** macOS 26+. **Version:** `AppVersion.display` prefers packaged `CFBundleShortVersionString` (from `VERSION` at build time), then falls back to the repo `VERSION` file for unpackaged `swift build` / tests. **Build:** SwiftPM only — no Xcode project; use `make` / `swift build`.

**GitHub repo:** `rimusz/codex-gateway` (legacy redirects from `rimusz/codex-bar`).

### Identity

| Item | Value |
|------|--------|
| Bundle ID | `com.rimusz.CodexGateway` |
| Config dir | `~/.codexgateway` |
| Codex provider id | `codexgateway` / `[model_providers.codexgateway]` |
| Managed markers | `# >>> codexgateway managed >>>` |
| Install helper | `Contents/Resources/codexgateway-install-update` |
| Notifications | `CodexGatewayStatusChanged`, `CodexGatewayUpdateAvailable`, etc. |
| Debug log | `/tmp/codexgateway_debug.log` |
| UserDefaults | `codexgateway.updates.*` |

### Upgrade / legacy (from CodexBar)

| Item | Legacy |
|------|--------|
| Bundle ID | `com.rimusz.CodexBar` — macOS Login Items may need re-enable after upgrade |
| Config dir | `~/.codexbar` → migrated to `~/.codexgateway` on launch (`Paths.migrateLegacyConfigDirectory`); legacy dir is removed only after a successful rename/merge so a failed migrate cannot wipe config |
| Codex provider | `codexbar` / `[model_providers.codexbar]` → rewritten to `codexgateway` on refresh/patch |
| Managed markers | `# >>> codexbar managed >>>` → rewritten on refresh/patch |
| Install helper | legacy `codexbar-install-update` |
| Release asset | older releases may still have `CodexBar-{tag}.app.zip`; new releases publish only `CodexGateway-{tag}.app.zip` |
| App folder | `CodexBar.app` → `CodexGateway.app` via `AppBundleMigration` (rename helper) after an old updater installs into `CodexBar.app`, or immediately when a new-build updater installs |

New releases publish only **`CodexGateway-{tag}.app.zip`** (and the DMG). The in-app updater still accepts a legacy **`CodexBar-{tag}.app.zip`** if present on an older release. Renaming the Finder folder is not done by the zip name — it happens on first launch of the new binary still living in `CodexBar.app` (`AppBundleMigration` writes a `/tmp` rename script: wait for quit → `mv CodexBar.app CodexGateway.app` → relaunch).

Older CodexBar install helpers `ditto` without deleting first, so Launch Services can keep launching a stale `Contents/MacOS/CodexBar` (pre-rename binary) and migration never runs. Builds therefore also ship **`Contents/MacOS/CodexBar` as a copy of `CodexGateway`** so that leftover launch path runs the new code and performs the rename.

---

## Design rules for agents

1. **Stay focused** — gateway + menu bar; no chat UI reimplementation.
2. **Reuse services** — extend `GatewayServer`, `Translator`, `ModelCatalog`, `CodexConfig`, `CodexAppServer`.
3. **Match conventions** — read surrounding code; minimize diff scope.
4. **Docs + tests with every code change** — run `make test`, update this file and other docs in the same session.
5. **Commit only when asked.**

---

## Repository layout

```
codex-gateway/                    # GitHub repo (`rimusz/codex-gateway`; legacy `rimusz/codex-bar` redirects)
├── CodexGateway/                 # Main app target (AppKit)
│   ├── main.swift                # NSApplication entry (.accessory)
│   ├── AppDelegate.swift         # Gateway start/stop, status bar
│   ├── StatusBarController.swift # Menu bar icon + menu
│   ├── AppActivationPolicy.swift # Restore .accessory when no windows remain
│   ├── AppVersion.swift
│   ├── AppIconProvider.swift
│   ├── CodexBrandIcon.swift
│   ├── Services/
│   │   ├── GatewayServer.swift   # HTTP routing
│   │   ├── LoopbackHTTPServer.swift
│   │   ├── Translator.swift      # Responses ↔ Chat translation
│   │   ├── ModelCatalog.swift    # custom_model_catalog.json + providers
│   │   ├── ProviderPresets.swift # Built-in presets (incl. Cursor bridge, xAI API + Grok OAuth)
│   │   ├── CustomProviderExample.swift # Spark DeepSeek fill-in for custom provider editor
│   │   ├── GrokOAuthSession.swift # ~/.grok/auth.json + `grok models` refresh
│   │   ├── GrokOAuthClient.swift  # CLI chat proxy (Responses) forwarder
│   │   ├── CursorBridge.swift     # Managed Cursor OpenAI bridge helpers (port 18788)
│   │   ├── CursorBridgeRuntime.swift # Node sidecar lifecycle
│   │   ├── CursorBridgeKeychain.swift # Application Support secret for CURSOR_API_KEY
│   │   ├── DoctorReport.swift    # Pure Doctor check mapping (gateway, Codex, Node, Cursor, Grok)
│   │   ├── DoctorCollector.swift # Live probes for DoctorInputs
│   │   ├── ProviderModelFetcher.swift # OpenAI /models + Cline Pass recommended-models
│   │   ├── FetchedModelsStore.swift   # ~/.codexgateway/fetched_models.json cache
│   │   ├── ZstdBridge.swift         # zstd decompress for Codex request bodies
│   │   ├── UpdateChecker.swift    # GitHub release version check
│   │   ├── UpdateScheduler.swift  # Background update polling
│   │   ├── AppUpdater.swift       # Download, verify, install update
│   │   ├── UpdatePanelModel.swift # Update panel button/status decisions
│   │   ├── CodexConfig.swift     # config.toml managed blocks (requires_openai_auth from sign-in)
│   │   ├── CodexAuthWatcher.swift # watches ~/.codex for sign-in changes, re-patches config
│   │   ├── CodexAppServer.swift  # Codex Desktop restart (re-patches config first)
│   │   ├── APIClient.swift       # Health polling
│   │   ├── OpenAtLogin.swift     # SMAppService login item toggle
│   │   ├── SetupPresentation.swift # First-run show/hide (empty catalog)
│   │   ├── SetupSession.swift    # In-memory skip-this-launch flag
│   │   ├── SetupFlow.swift       # Pure setup step machine
│   │   ├── Paths.swift
│   │   └── GatewayLog.swift
│   ├── UI/
│   │   ├── SetupWindowController.swift # First-run setup (empty catalog)
│   │   ├── SetupView.swift
│   │   ├── SetupStore.swift
│   │   ├── AboutWindowController.swift # About panel (matches UpdatePanel chrome)
│   │   ├── DoctorWindowController.swift
│   │   ├── DoctorView.swift
│   │   ├── SettingsWindowController.swift
│   │   ├── SettingsView.swift
│   │   ├── SettingsStore.swift
│   │   ├── UpdatePanel.swift
│   │   └── UpdatePanelStyle.swift # Shared About/Update fonts + Dock-rounded icon
│   └── Resources/
│       ├── Assets.xcassets/
│       └── CursorBridge/         # cursor-openai-bridge.mjs (+ npm bundle at packaging)
├── Tests/CodexGatewayTests/
├── scripts/                      # build-macos-app.sh, release.sh, notarize.sh
├── Makefile
├── Package.swift
├── VERSION
├── BUILDING.md
└── README.md
```

---

## App lifecycle

1. `main.swift` — `NSApplication` with `.accessory` (menu bar only, no Dock).
2. `AppDelegate.applicationDidFinishLaunching` — `GatewayServer.shared.start()`, then `StatusBarController` + health timer. If the catalog is empty (no installed providers and no models) and the user has not skipped this launch, `SetupWindowController` opens the first-run setup window. DEBUG `--setup` / menu **Show Setup…** force it. Rename-quit (`AppBundleMigration`) suppresses setup.
3. `AppDelegate.applicationWillTerminate` — stop gateway.

---

## Gateway routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Status + version |
| POST | `/api/restart-codex` | Restart Codex Desktop (used by the menu) |
| GET | `/v1/models` | OpenAI-compatible model list |
| POST | `/v1/responses` | Responses API (translate or pass-through) |
| POST | `/v1/chat/completions` | Chat completions proxy |

The gateway is intentionally minimal: only the routes Codex Desktop and the app itself call. Provider/model **management is done in-process** by the native Settings UI (`ModelCatalog` / `CodexConfig` directly) — there are **no HTTP mutation endpoints** and no browser dashboard, to avoid an unauthenticated local attack surface. The listener is **bound to loopback** (`NWParameters.requiredLocalEndpoint = 127.0.0.1:8765` in `LoopbackHTTPServer.start`), so it is never reachable from the LAN. WebSocket upgrades return 404 (voice removed).

`LoopbackHTTPServer` waits for complete `Content-Length` and chunked bodies, decompresses `Content-Encoding: gzip` and `zstd` request bodies, and defers POST parsing when the body has not arrived yet. Codex Desktop sends large zstd-compressed JSON to `/v1/responses`. `HTTPRequest.forwardHeaders` strips `Content-Encoding` / `Content-Length` before upstream pass-through so decoded bodies are not double-decoded.

### Other OpenAI-compatible clients (e.g. Zero)

Any tool on the same Mac that speaks OpenAI Chat Completions can use `http://127.0.0.1:8765/v1` while CodexGateway is running. Custom model slugs come from `GET /v1/models`; upstream provider keys are injected from `~/.codexgateway/providers.json`. Native GPT pass-through uses `~/.codex/auth.json` when the client does not send `Authorization`.

End-user setup (Zero TUI, CLI `zero exec`, provider profile, troubleshooting): **`README.md` → Using CodexGateway with Zero**.

---

## In-app updates

CodexGateway checks `https://api.github.com/repos/rimusz/codex-gateway/releases` (and falls back to `rimusz/codex-bar`) for the newest **notarized** release (title/body marker). Unsigned releases are ignored for one-click install.

| Component | Role |
|-----------|------|
| `UpdateScheduler` | Launch + daily background check (30s delay, 24h interval) |
| `UpdateChecker` | GitHub API (`rimusz/codex-gateway` + legacy `rimusz/codex-bar`), semver compare, asset `CodexGateway-{tag}.app.zip` (falls back to legacy `CodexBar-{tag}.app.zip` on older releases) |
| `AppUpdater` | Download, codesign/spctl verify, install via `codexgateway-install-update` helper; migrates `CodexBar.app` → `CodexGateway.app` |
| `UpdatePanel` | Menu **Check for Updates…** / **Upgrade Available…** (⌘U); primary action is a system default button (**Update App** → download/verify → **Install and Restart**, or **Open Release Page** when the notarized release has no `.app.zip`). Panel height is measured from the content chain (including the button stack) so actions are not clipped. |
| `UpdatePanelModel` | Pure UI decisions (install button vs open release page; skip vs notify) |
| `UpdateSettingsStore` | UserDefaults `codexgateway.updates.*` (migrated from legacy `codexbar.updates.*`): auto-check, skip version, last check |

Install helper: `scripts/codexgateway-install-update.sh` → bundled as `Contents/Resources/codexgateway-install-update`.

---

## Config paths

| Path | Purpose |
|------|---------|
| `~/.codexgateway/custom_model_catalog.json` | CodexGateway internal model catalog (routing metadata). Raw model ids get friendly display names via `ModelCatalog.prettyDisplayName` / `normalizeDisplayNames` (run on Settings reload + gateway startup; drops `vendor/model` prefixes, collapses doubled vendors, title-cases, prefixes the provider brand Cline-style via `providerBrand`, and appends `(API)` / `(OAuth)` for xAI vs Grok OAuth, e.g. "xAI Grok 4.5 (API)"); user-edited names are preserved. `ProviderConfig.displayLabel` prefers a stored `display_name` over the built-in preset title. Providers and models are listed A–Z by display name in Settings; **Add Provider** (presets + custom add) starts collapsed; the **Providers** and **Models** sections are collapsible (expanded by default). Custom Codex picker entries are exported in that order. |
| `~/.codex/model-catalogs/custom-providers.json` | Codex-compatible picker export (`model_catalog_json`): native ChatGPT/Codex models plus custom entries. **Codex only renders custom entries in its picker when signed in** (free account is enough); signed out it shows a built-in fallback list and labels any active custom model as "Custom". Settings surfaces a sign-in hint (`SettingsStore.customModelsNeedSignIn`) when custom models exist but `auth.json` is absent. |
| `~/.codexgateway/providers.json` | Provider endpoints + credentials. Optional `auth_kind`: omitted/`api_key` → Bearer key to `{base_url}/chat/completions`; `grok_oauth` → `GrokOAuthClient` (no key stored). Read **live** by the gateway per request (`ModelCatalog.resolveUpstream`), so provider/preset changes take effect immediately — **no Codex restart** (only model changes require one; see `SettingsStore.requiresCodexRestart`). |
| `~/.grok/auth.json` | Official Grok CLI OAuth session (not owned by CodexGateway). Used when a provider has `auth_kind = grok_oauth`. |
| `~/.codexgateway/fetched_models.json` | Cached model lists per provider (OpenAI `/models`, or Cline Pass recommended-models feed); replaced on each fetch |
| `~/.codex/config.toml` | Codex config (managed blocks patched). `[model_providers.codexgateway].requires_openai_auth` is set from sign-in state: `false` when not signed in (skips Codex login — enables local-only Ollama/custom use), `true` when signed in (native GPT/ChatGPT pass-through). Legacy `codexbar` blocks are rewritten to `codexgateway` on refresh/patch. Automatic callers (startup, `CodexAuthWatcher`, restart) only **refresh** the block when it is already present (`refreshManagedConfigIfApplied`) — CodexGateway never silently injects into a fresh/native Codex; Settings' **Update Gateway Config** is the explicit opt-in. |
| `~/.codex/auth.json` | Auth token for pass-through; also read by `CodexConfig.isSignedIn()` to decide `requires_openai_auth`; watched by `CodexAuthWatcher` |

---

## Notifications

| Name | Purpose |
|------|---------|
| `CodexGatewayStatusChanged` | Menu bar status (`AppStatus` object) |
| `CodexGatewayUpdateAvailable` | In-app update available (from `UpdateScheduler` / `UpdateChecker`) |
| `CodexGatewayDoctorRerunRequested` | Re-run Doctor checks when the existing Doctor window is shown again |

---

## Build, test & release

```bash
make build      # swift build -c release
make test       # swift test
make run        # build + launch .build/CodexGateway.app
make app        # dist/CodexGateway.app + DMG
make release    # GitHub release via scripts/release.sh
```

CI: `.github/workflows/pr.yml` (PR: `make test` + `make app`), `.github/workflows/release.yml` (manual dispatch, unsigned publish). Notarized: local `make release RELEASE_TYPE=notarized`. See `BUILDING.md` → GitHub Releases.

Release assets: `CodexGateway-{tag}.app.zip`, `CodexGateway-{tag}-macOS.dmg` (no new `CodexBar-*.app.zip`).

---

## Common tasks → files

| Task | Files |
|------|-------|
| Open About | `AboutWindowController`, menu **About CodexGateway** |
| Open Doctor | `DoctorWindowController` + `DoctorView`; menu **Doctor…** (⌘D); Settings toolbar **Doctor**. Fixed-size window (close only). `DoctorReport` maps `DoctorInputs` (pure); `DoctorCollector` probes `/health`, Codex config/sign-in, Node ≥ 22.13, Cursor key/sidecar, Grok OAuth |
| Restore menu-bar mode after windows close | `AppActivationPolicy.restoreAccessoryIfNoVisibleWindows` (About, Settings, Doctor, UpdatePanel, Setup) |
| First-run setup | `SetupWindowController` + `SetupView` + `SetupStore` + `SetupFlow` / `SetupPresentation` / `SetupSession`. Shows when the catalog is empty; Skip is this launch only. Connect installs without seeding/patching; Close/Skip cancels work and removes a new provider or restores pre-existing DEBUG-forced data. Empty fetches allow manual models. Finish transactionally replaces rows, applies a throwing catalog/config write, rolls back on failure, then asks **Restart Codex?**. `--setup` is DEBUG-only; migrating bundles use `AppBundleMigration.isLegacyBundleMigrationPending`. |
| Add gateway route | `GatewayServer.swift` |
| Change translation logic | `Translator.swift` |
| Model catalog / providers | `ModelCatalog.swift`, `ProviderPresets.swift`, `ProviderModelFetcher.swift`, `Paths.swift` |
| Install provider preset | `PresetInstaller`, Settings window (provider only by default; **xAI Grok (OAuth)** also seeds a suggested model; **Cursor** validates API key → `CursorBridgeKeychain` + enables `CursorBridgeRuntime` on port **18788**). Cline Pass listing: `ProviderModelFetcher.fetchClinePassRecommended` → `https://api.cline.bot/api/v1/ai/cline/recommended-models` (no API key) |
| Custom provider Spark example | `CustomProviderExample` + Settings **Add Provider** → Add custom provider → “Fill Spark example” (`spark-deepseek` → `http://spark:8001/v1`) |
| xAI Grok (OAuth) provider | `GrokOAuthSession` (`~/.grok/auth.json`, `grok models` refresh), `GrokOAuthClient` → `cli-chat-proxy.grok.com/v1/responses`; model list via `ProviderModelFetcher.fetchGrokOAuthModels` → `…/models-v2`. `GatewayServer` branches on `ProviderConfig.usesGrokOAuth`. Parallel to **xAI Grok (API)** preset. |
| Cursor bridge (managed) | `CursorBridge` / `CursorBridgeRuntime` — Node `@cursor/sdk` sidecar on `http://127.0.0.1:18788/v1` (coexists with GrokBuild on 18787). API key in `~/Library/Application Support/CodexGateway/Secrets/cursor-api-key` (`CursorBridgeKeychain`); `providers.json` keeps `api_key: "local"` + `auth_kind: cursor_bridge`. Settings/Doctor probe Node ≥ 22.13 off the main actor (`probeNodeAsync`); missing/too-old shows Homebrew Terminal install + nodejs.org. Concurrent `startIfNeeded()` joins an in-flight start. Gateway Cursor proxy hops off `LoopbackHTTPServer`'s serial queue while the sidecar starts. `stop()` only SIGTERMs listeners whose command line contains `cursor-openai-bridge.mjs`. Bundled via `scripts/bundle-cursor-bridge.sh` (`npm ci`). |
| Open Settings | `SettingsWindowController`, menu **Settings** (⌘,). Fixed-size window (close only) |
| Patch Codex config | `CodexConfig.swift` |
| Reset/Update gateway config | `SettingsView` (label toggles on `SettingsStore.gatewayConfigInSync`), `SettingsStore.resetGatewayConfig` / `applyGatewayConfig` / `updateGatewayConfig` (apply + restart), `CodexConfig.resetToNative` (Codex-side only; keeps `~/.codexgateway` data). `CodexConfig.ensureConfigFile()` creates a missing `config.toml` on explicit apply |
| Restart Codex Desktop | `CodexAppServer.swift`; menu **Restart Codex** (⌘R); Settings shows a **Restart Codex** button (`SettingsStore.needsCodexRestart` / `restartCodex`) after provider/model changes |
| Document third-party CLI use (Zero) | `README.md` → Using CodexGateway with Zero; gateway base URL `Paths.gatewayHost`/`gatewayPort` |
| Menu bar UI | `StatusBarController.swift` |
| Open at Login | `OpenAtLogin.swift` (`SMAppService.mainApp`), menu item in `StatusBarController` |
| Gateway status/port in menu | `StatusBarController` (disabled item), `StatusBarMenuCopy.gatewayStatusTitle`, address from `Paths.gatewayHost`/`gatewayPort` |
| Cursor bridge status in menu | `StatusBarMenuCopy.cursorBridgeStatusTitle` — shown only when `CursorBridgeRuntime.isEnabled` (Cursor provider installed); hidden otherwise |
| In-app updates | `UpdateChecker.swift`, `AppUpdater.swift`, `UpdateScheduler.swift`, `UpdatePanel.swift` |
| App rename / migration | `AppIdentity.swift` (`AppBundleMigration`), `AppUpdater.swift`, `scripts/codexgateway-install-update.sh` (`--rename-from` / `--rename-to`) |
| Version display | `AppVersion.swift` (bundle Info.plist first, then `VERSION` file) |
| Packaging / signing | `scripts/build-macos-app.sh`, `BUILDING.md` |

---

## Tests

Unit tests in `Tests/CodexGatewayTests/`:

- `TranslatorTests` — translation, namespace mapping, think stripping
- `CodexConfigTests` — managed block stripping
- `ModelCatalogTests` — provider/model API parsing
- `ProviderPresetsTests` — preset definitions, Grok OAuth install seed
- `CursorBridgeTests` — managed bridge port 18788, catalog filter, Node TLS, runtime helpers
- `GrokOAuthSessionTests` — auth.json probe/parse/refresh stubs
- `GrokOAuthClientTests` — Chat→Responses map, SSE→Chat conversion, 401 retry
- `DoctorReportTests` — Doctor check mapping, health, remediation priority
- `StatusBarTests` — accessibility labels, Doctor menu title, Cursor Bridge menu line
- `AppActivationPolicyTests` — accessory restore when no other windows remain
- `OpenAtLoginTests` — login-item status mapping + toggle flow
- `UpdateCheckerTests` — version compare, notarized filter, asset selection
- `UpdateSettingsStoreTests` — skip/dismiss behavior
- `SettingsWindowControllerTests` — Settings/Doctor/About chrome; Providers/Models disclosure defaults
- `SetupPresentationTests` / `SetupFlowTests` / `SetupWindowControllerTests` — first-run show/hide, step machine, setup chrome + `shouldPresent`
- `PathsTests` — legacy config migration

Run `make test` before finishing any code change.

---

## Related docs

- `AGENTS.md` — agent entry
- `BUILDING.md` — build, sign, release
- `README.md` — user-facing features
- `.cursor/rules/docs-and-tests.mdc` — docs + tests checklist
