# CodexGateway

**Use any OpenAI-compatible model in Codex Desktop and Codex CLI — from a macOS menu bar app.**

CodexGateway sits in your menu bar and runs a local gateway so Desktop and the CLI can use **third-party** providers (Cursor, Anthropic Console or Claude Code login, xAI API or Grok OAuth, DeepSeek, Google Gemini, OpenRouter, Z.ai, Kimi, Qwen, MiniMax, Cline Pass, …) or **local** models (Ollama). **Update Gateway Config** writes only your custom models into Codex’s picker and restarts Desktop and the CLI daemon. **Reset Gateway Config** puts Codex’s own models back. One list at a time — ChatGPT rejects native model ids when the request comes through the gateway. Desktop and CLI share the choice via `~/.codex/config.toml`.

![CodexGateway Settings and menu bar](docs/screenshots/settings-and-menu.png)

> Most providers need an OpenAI-compatible `/chat/completions` endpoint. **Cursor** uses a managed Node sidecar (`@cursor/sdk` on `127.0.0.1:18788`; Node.js ≥ 22.13). **xAI Grok (OAuth)** reuses your Grok CLI login instead of storing an API key.

## Requirements

- macOS 26 or later
- [Codex Desktop](https://openai.com/codex) and/or the [Codex CLI](https://openai.com/codex)
- Xcode Command Line Tools (only if building from source)

## Install

Download the latest `.dmg` from [Releases](https://github.com/rimusz/codex-gateway/releases), or build from source:

```bash
make run            # build + launch the menu bar app
make app            # build dist/CodexGateway.app + DMG
make install        # copy the app to /Applications/
```

See [BUILDING.md](BUILDING.md) for packaging, signing, notarization, and publishing.

Upgrading from **CodexBar**? Settings migrate automatically — see [docs/troubleshooting.md](docs/troubleshooting.md#upgrading-from-codexbar).

## Quick start

1. Launch CodexGateway — a status icon appears in the menu bar.
2. If you have no providers yet, **Set Up CodexGateway** walks you through provider → connect → models → Finish (writes Codex config and offers **Restart Codex**).
3. Or open **Settings** (⌘,) → **Add Provider** → install a preset → **Add model**.
4. Click **Update Gateway Config** so custom models appear in Codex’s picker (native models leave that list).
5. Restart when prompted (**Restart Codex**, ⌘R) so Desktop and the CLI daemon reload the same catalog.
6. Pick a custom model in Codex Desktop or the CLI.

Optional: menu bar → **Open at Login**. If something looks wrong, open **Doctor…** (⌘D).

Custom models need a Codex sign-in (**free account is enough**). More tips: [docs/troubleshooting.md](docs/troubleshooting.md).

## How it works

```text
Update Gateway Config                         Reset Gateway Config
        │                                              │
        ▼                                              ▼
picker: your custom models only              picker: native Codex models
        │                                              │
        ▼                                              ▼
CodexGateway 127.0.0.1:8765                  Codex's own ChatGPT path
        │
        ▼
third-party or local API (Responses ⇄ Chat Completions)
```

- **Gateway** — loopback HTTP on `127.0.0.1:8765`. Update points Desktop/CLI at it via a managed block in `~/.codex/config.toml`; Reset removes that block. Providers stay in `~/.codexgateway`.
- **Routing** — Responses ⇄ Chat Completions translation; catalog slug first (`cursor/gpt-5.5` stays on Cursor). Outbound HTTPS uses the macOS trust store (works with Zscaler when the corp root is in Keychain).
- **Menu bar + Settings** — health/port, providers, models, Doctor, About.

Depth for contributors: [ARCHITECTURE.md](ARCHITECTURE.md).

## Models workflow

| Action | Effect |
|--------|--------|
| **Add / edit / delete models** | Changes the exported catalog — Settings offers **Restart Codex** |
| **Provider changes** (API key, install preset) | Take effect immediately — no restart |
| **Update Gateway Config** | Custom models only in the picker; restarts Desktop + CLI daemon |
| **Reset Gateway Config** | Native Codex models return; `~/.codexgateway` data is kept |

A custom entry whose upstream id matches a native slug still works when selected (e.g. `cursor/gpt-5.5` → Cursor). Wire format and routing details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Updates

Menu bar → **Check for Updates…** (⌘U):

1. **Update App** — downloads `CodexGateway-{tag}.app.zip` and verifies the signature
2. **Install and Restart** — replaces the running app via `codexgateway-install-update` and relaunches

Only **notarized** releases with a `.app.zip` are installable in-app. Unsigned CI builds: install the DMG from GitHub manually.

## Docs

| Doc | Contents |
|-----|----------|
| [docs/zero.md](docs/zero.md) | Point [Zero](https://zero.gitlawb.com) at the local gateway |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Sign-in, blank turns, CLI daemon, Cursor, Claude Code, CodexBar upgrade |
| [ARCHITECTURE.md](ARCHITECTURE.md) | App map, gateway routes, config paths, “common tasks → files” |
| [BUILDING.md](BUILDING.md) | Build, sign, notarize, release |
| [AGENTS.md](AGENTS.md) | Repo conventions for agents |

## Contributing

Pure-Swift SwiftPM app (no Xcode project). See [ARCHITECTURE.md](ARCHITECTURE.md) and [AGENTS.md](AGENTS.md).

## Licence

[Apache License 2.0](LICENSE). CodexGateway is an independent macOS menu-bar app with a local gateway for [Codex Desktop](https://openai.com/codex/) and CLI; it is not affiliated with, endorsed by, or sponsored by OpenAI.
