# First-run setup sheet

Date: 2026-08-16  
Status: implemented  
Branch: `feature/first-run-setup`

## Problem

First launch of CodexGateway opens a menu-bar-only app. Settings is a power-user form: install a preset, fetch models, add one model, Update Gateway Config, restart Codex. People with an empty catalog never get a guided path to a working custom model.

## Decisions

| Topic | Choice |
|---|---|
| When it shows | Empty catalog only: no installed providers and no models. Not a one-shot UserDefaults flag. |
| Skip | This launch only (in-memory). Close = skip. Next launch shows again if still empty. |
| Re-show after delete-all | Next launch, not mid-session. |
| Finish | Replace that provider’s catalog rows with the checked (or manual) models, write Codex managed config + catalog export, then the existing **Restart Codex?** alert. No silent restart. |
| Providers | All current presets + Add custom. |
| Models | Fetch, then multi-select. Preset `suggestedModel` pre-checked when present in the list. |
| Window | Standalone setup window. Does not open Settings. |
| Implementation | Dedicated setup module. Reuse `PresetInstaller`, `ModelCatalog`, `ProviderModelFetcher`, `CursorBridgeRuntime`. |
| Cline Pass | Still asks for an API key (same as Settings). Listing does not need a key; inference does. |
| Connect side effects | Install the provider only. Do **not** seed models and do **not** patch `config.toml`. Finish is the apply step. |
| Unfinished Connect | Back to Choose, another tile, Skip, or Close cancels Connect/fetch work. A new session provider is removed; a provider/key/cache that existed before DEBUG forced setup is restored. |

## When it opens

After the gateway and menu bar are up (`AppDelegate`’s existing delayed status-bar setup), if all of:

- no *installed* providers
- no catalog models
- not skipped this launch
- this process is not quitting for the CodexBar → CodexGateway rename (`AppBundleMigration.isLegacyBundleMigrationPending`)

**Installed providers** exclude empty-name rows and the first-launch `opencode` seed stub (`opencode` + empty key + `https://opencode.ai/zen/go/v1`). `ModelCatalog.loadProviders()` still returns that stub when `providers.json` is missing. Setup treats that as “not set up.” New `providers.json` created at gateway start is an empty list so Settings does not show a fake provider.

Upgrades with real `~/.codexgateway` data never see the window.

## Steps (`SetupFlow`)

1. **Choose** — tile grid of `ProviderPreset.featuredMenuOrder` + Add custom. Clicking a tile selects it and goes to Connect. No Continue button (tiles advance).
2. **Connect** — existing auth rules; Install/Continue disabled until the form is valid:
   - API-key preset (including Cline Pass): SecureField; require a non-empty key
   - Cursor: Node banner + key + validate; Install disabled until Node meets minimum **and** the key is non-empty
   - Grok OAuth: session line + Open Terminal + Re-check; install with no key
   - Ollama: “No API key needed”
   - Custom: name, display name, base URL, key, Fill Spark example; require name + base URL
3. **Models** — fetch on enter; checkboxes; Select all / Select none; Finish requires ≥1 model. An empty list or failed fetch enables manual slug + display name; fetch errors stay on this step with Retry. In-flight fetches are cancelled/ignored after Back, Skip, Close, or a new Connect.

**Back** is allowed. Leaving Connect without Finish (Back to Choose, another tile, Skip, Close) removes the session provider when it still has zero models, so the wizard can show again next launch.

## Window

- `SetupWindowController` + SwiftUI `SetupView`
- Title: **Set Up CodexGateway**
- Closable only, fixed size (~560×560), same activation policy as Settings
- Header + step labels **Choose · Connect · Models**
- Footer: Skip (always) · Back (steps 2–3) · Install / Finish (not on Choose)
- Close and Skip set `SetupSession.skippedThisLaunch` and discard an unfinished session provider

## Finish

Do **not** call `SettingsStore.updateGatewayConfig()` (it restarts immediately).

1. Snapshot the current catalog, then replace that provider’s rows with the selected (or manual) models
2. `SettingsStore.applyGatewayConfig()` — throwing catalog export + throwing `config.toml` patch. If `~/.codex/config.toml` is missing, create a minimal file first
3. Close the setup window
4. `RestartCodexConfirmation.confirm()` then restart if accepted

If export or config apply fails, restore the catalog snapshot, keep setup open, and show the error. Do not restart.

Settings **Update Gateway Config** is apply + restart (same user-visible behavior).

## Errors

Stay on the current step. Close during Connect/fetch cancels the work, skips this launch, and restores/removes the session provider as appropriate.

No new HTTP routes. No Settings auto-open. Signed-out custom-model hint stays in Settings only.

## Files

Setup is a dedicated module. Each file has one job so show/hide, skip-for-this-launch, the step machine, and window chrome can be tested without sharing Settings files.

| File | Role |
|---|---|
| `Services/SetupPresentation.swift` | Pure `shouldShow` + placeholder-provider filter |
| `Services/SetupFlow.swift` | Pure step machine, connect validation, model selection / replace helpers |
| `Services/SetupSession.swift` | In-memory skip flag (`skippedThisLaunch`) |
| `UI/SetupStore.swift` | Install (no seed, no patch), fetch, discard unfinished provider, apply config |
| `UI/SetupView.swift` | Three screens |
| `UI/SetupWindowController.swift` | Window + present; `isMigrating` defaults to `AppBundleMigration.isLegacyBundleMigrationPending` |
| `Tests/CodexGatewayTests/SetupPresentationTests.swift` | Show / hide matrix |
| `Tests/CodexGatewayTests/SetupFlowTests.swift` | Transitions, Finish ≥1 model, suggested pre-check, connect validation, discard rule |
| `Tests/CodexGatewayTests/SetupWindowControllerTests.swift` | Chrome + `shouldPresent` (`--setup`, migrating) |

`SetupSession` is its own file so the skip flag is not mixed into the pure presentation predicates. `SetupWindowControllerTests` owns setup chrome and present rules so `SettingsWindowControllerTests` stays Settings/Doctor/About only.

`AppDelegate` calls `SetupWindowController.showIfNeeded()` after the status bar is created.

Dev-only: `--setup` launch argument is honored in **DEBUG** builds only (and DEBUG menu **Show Setup…**) so Computer Use can verify UI without requiring an empty catalog. Release builds ignore `--setup`. `--setup` does not override an in-progress CodexBar → CodexGateway rename.

## Docs

- `ARCHITECTURE.md` — new files, lifecycle, common tasks
- `README.md` — Quick start: first launch opens setup when the catalog is empty
