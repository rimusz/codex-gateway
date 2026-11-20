# Troubleshooting

## Doctor first

If the gateway, Codex config, Node.js, Cursor, Grok OAuth, or Claude Code login looks off, open **Doctor…** (⌘D) from the menu bar or the Settings toolbar.

## Custom models missing in Codex

**Custom models require you to be signed in to Codex** — a **free account is enough**. Signed out, Codex only shows its built-in fallback models and labels any active custom model as "Custom". (Native GPT/ChatGPT models still need an OpenAI/ChatGPT account.)

When you have custom models but Codex is signed out, Settings shows a reminder.

Also confirm:

1. Models are installed in **Settings**.
2. You clicked **Update Gateway Config** (not only added models).
3. Codex Desktop and the CLI daemon were restarted (Update/Reset does this; or menu **Restart Codex**, ⌘R).

## Blank assistant turn

If Codex shows your prompt and then **nothing** (blank assistant turn), common causes are:

- The gateway forwarded a dummy bearer to OpenAI
- Third-party **tool calls** were dropped from the Responses stream (fixed in current builds — update the app)
- A ChatGPT login was sent to `api.openai.com` instead of ChatGPT’s Codex backend

Restart CodexGateway after updating, then **Restart Codex**. Native GPT and custom models both work with or without Zscaler — the gateway uses the macOS trust store, not a pinned corporate certificate.

Custom-model text is streamed to Codex as the provider sends it. If that stream drops in the middle of a tool call before any text was sent, CodexGateway retries the upstream request up to twice. If text was already sent, the turn fails instead of repeating or mixing two answers.

## CLI daemon still on old models

**Restart Codex** (⌘R) restarts Codex Desktop **and** the Codex CLI daemon (`codex app-server daemon restart`). A new terminal then reloads the same catalog as Desktop.

If you only quit/reopen Desktop, the CLI may still serve a stale catalog until the daemon restarts.

## Cursor bridge

- Paste a Cursor API key from [cursor.com/dashboard](https://cursor.com/dashboard) → Integrations.
- Node.js ≥ 22.13 is required (`brew install node`, or [nodejs.org](https://nodejs.org/)).
- Doctor checks Node and the local sidecar on `127.0.0.1:18788`.
- The bridge is inference-only (assistant text); Codex keeps its own tools.

## Claude Code / Anthropic

Keep the two Anthropic presets separate:

- **Anthropic (Claude)** — Console API key from [console.anthropic.com](https://console.anthropic.com/settings/keys). Do not paste a Claude Code OAuth token here.
- **Anthropic (Claude Code)** — uses local Claude Code / CLI login (`claude auth login` or Claude Code `/login`). No OAuth token is stored in `providers.json`.

## When does Codex need a restart?

Only when you **add, edit, or delete a model** — those change the exported catalog. **Provider** changes (including installing a preset) take effect immediately; the gateway reads endpoints and keys live from `~/.codexgateway/providers.json`.

## Upgrading from CodexBar

**CodexBar** is now **CodexGateway**. Existing installs upgrade smoothly:

- Install from [Releases](https://github.com/rimusz/codex-gateway/releases) or use **Check for Updates…** (works from notarized CodexBar builds too).
- Settings migrate from `~/.codexbar` → `~/.codexgateway` on first launch.
- Bundle ID is now `com.rimusz.CodexGateway` — re-enable **Open at Login** if you used it before.
- The managed block in `~/.codex/config.toml` is rewritten `codexbar` → `codexgateway` on **Update Gateway Config** (or automatic refresh).
- On first launch or in-app update, `CodexBar.app` in `/Applications` is replaced by `CodexGateway.app`.

## Zero (third-party CLI)

For Zero TUI/CLI setup and Zero-specific errors, see [zero.md](zero.md).
