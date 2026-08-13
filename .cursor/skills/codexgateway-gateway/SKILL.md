---
name: codexgateway-gateway
description: Works with CodexGateway gateway and Codex Desktop integration — HTTP routes, model translation, config patching, catalog management. Use when changing GatewayServer, Translator, ModelCatalog, CodexConfig, or CodexAppServer.
---

# Gateway & Codex in CodexGateway

## Boundaries

CodexGateway is a gateway + menu bar companion. Core agent behavior stays in Codex Desktop.

## Key components

```swift
// HTTP gateway
GatewayServer.shared.start()   // 127.0.0.1:8765
LoopbackHTTPServer             // Network.framework HTTP

// Translation
Translator.responsesToChat(...)
Translator.chatCompletionToResponse(...)

// Config
ModelCatalog.shared            // ~/.codexgateway/
CodexConfig.patchCodexConfig()            // explicit apply → ~/.codex/config.toml managed blocks
CodexConfig.refreshManagedConfigIfApplied() // automatic callers; only if block already present
CodexAppServer.shared          // restart Codex Desktop
```

## Gateway routes

See `ARCHITECTURE.md` → Gateway routes. The gateway is **minimal and loopback-only** (`LoopbackHTTPServer.start` pins `requiredLocalEndpoint` to `127.0.0.1`): only `/health`, `/api/restart-codex`, `/v1/models`, `/v1/responses`, `/v1/chat/completions`. There are **no HTTP provider/model mutation endpoints and no browser dashboard** — all management is done in-process by the native Settings UI (`ModelCatalog` / `CodexConfig`).

Provider/model add flow (native, not HTTP): installing a preset writes only the provider endpoint/key (Grok OAuth also seeds a suggested model; Cursor validates a dashboard API key into Application Support and starts the managed bridge); Settings then fetches provider models via `ProviderModelFetcher` before adding selected models. Most providers use `GET {base_url}/models`; Cline Pass uses the public recommended-models feed (`GET https://api.cline.bot/api/v1/ai/cline/recommended-models`, no API key) via `fetchClinePassRecommended` / `parseClinePassRecommended` (same path as GrokBuild Desktop). Fetched lists persist in `~/.codexgateway/fetched_models.json` and are replaced on the next fetch. `ProviderModelFetcher.parse` accepts OpenAI (`data[]`), bare arrays, and an `items[]` shape (flattening to top-level `id`s and ignoring per-model variants; also drops Cursor routing aliases `default` / `auto` / `auto-smart`). **Cursor** (`auth_kind: cursor_bridge`) is a managed local OpenAI sidecar (Node `@cursor/sdk` on `127.0.0.1:18788`, different from GrokBuild’s 18787): `providers.json` keeps `api_key: "local"`; the real key lives in `~/Library/Application Support/CodexGateway/Secrets/cursor-api-key` and is injected into the sidecar only. Settings/Doctor probe Node ≥ 22.13 off the main actor (`probeNodeAsync`) and, if missing/too old, offer Homebrew Terminal install + nodejs.org. Concurrent `startIfNeeded()` joins an in-flight start; Cursor proxy hops off the HTTP server queue while the sidecar starts. Packaged via `scripts/bundle-cursor-bridge.sh` (`npm ci`, needs Node ≥ 22.13). Inference-only (assistant text); Codex keeps tool calling. **xAI Grok (OAuth)** (`auth_kind: grok_oauth`) is different: credentials come from `~/.grok/auth.json` / `grok login`; `GatewayServer` forwards via `GrokOAuthClient` to `cli-chat-proxy.grok.com/v1/responses`; Settings fetches models from `…/models-v2` (`ProviderModelFetcher.fetchGrokOAuthModels`) — parallel to the **xAI Grok (API)** preset. Settings **Add Provider** → Add custom provider includes **Fill Spark example** (`CustomProviderExample` → `http://spark:8001/v1`). **Doctor** (`DoctorReport` / `DoctorCollector` / `DoctorView`) checks gateway `/health`, Codex config/sign-in, Node.js, Cursor key/sidecar, and Grok OAuth — menu **Doctor…** (⌘D) or Settings toolbar.

## Config files

| File | Managed by |
|------|-----------|
| `~/.codexgateway/custom_model_catalog.json` | `ModelCatalog` internal routing catalog |
| `~/.codex/model-catalogs/custom-providers.json` | `ModelCatalog` Codex-compatible picker catalog export; includes native ChatGPT/Codex models plus custom models. **Custom entries only appear in Codex's picker when signed in** (free account suffices); signed out Codex shows a built-in fallback and labels active custom models as "Custom". `SettingsStore.customModelsNeedSignIn` drives a Settings hint. |
| `~/.codexgateway/providers.json` | `ModelCatalog` (`auth_kind` optional: `api_key` / `grok_oauth` / `cursor_bridge`) |
| `~/Library/Application Support/CodexGateway/Secrets/cursor-api-key` | Cursor bridge API key (`CursorBridgeKeychain`; not written to providers.json) |
| `~/.grok/auth.json` | Grok CLI OAuth session (read by `GrokOAuthSession` when `auth_kind` is `grok_oauth`) |
| `~/.codex/config.toml` | `CodexConfig` (managed blocks; provider id `codexgateway`). `requires_openai_auth` follows `CodexConfig.isSignedIn()`: `false` when signed out (no Codex login needed for local-only Ollama/custom), `true` when signed in (native GPT/ChatGPT pass-through). Legacy `codexbar` blocks are rewritten on refresh/patch. |
| `~/.codex/auth.json` | read-only for pass-through token + `isSignedIn()` detection |

## Status bar integration

- `APIClient.fetchStatus()` polls `/health`
- Posts `CodexGatewayStatusChanged` with `AppStatus` on main queue

## After changing gateway integration

Same session, before finishing:

1. **`make test`** — extend `TranslatorTests`, `CodexConfigTests`, or add service tests.
2. **`make run`** + `curl -s http://127.0.0.1:8765/health`.
3. **Always use Computer Use to test changes** — open Settings and exercise any provider/model/catalog/path you touched (`grokbuild-computer-use` MCP → `orca computer` → `agent-desktop` last; see `codexgateway-dev` skill). Do not skip.
4. **`ARCHITECTURE.md`** — gateway routes, config paths, service map.
5. **`README.md`** — if user-visible gateway/config behavior changed.
6. **This skill** + `codex-gateway-integration.mdc` — if APIs or route contracts changed.

## Smoke test

```bash
make run
curl -s http://127.0.0.1:8765/health
# then Computer Use: open Settings and verify the changed flow
```
