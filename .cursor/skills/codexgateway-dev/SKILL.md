---
name: codexgateway-dev
description: Builds, runs, and tests the CodexGateway macOS SwiftPM app. Use when developing CodexGateway, running make targets, fixing build failures, or working on AppKit/menu bar UI in this repo.
---

# CodexGateway development

## Quick start

```bash
make run          # build release + launch via open
make test         # swift test
swift build       # debug build
xed .             # open Package.swift in Xcode (optional)
```

## Before coding

1. Read `ARCHITECTURE.md` for file layout and gateway routes.
2. Prefer `make` over ad-hoc `xcodebuild` (no `.xcodeproj`).
3. After Swift changes, run `swift build` or `make build`.

## Definition of done (every code change)

**Do not finish a task with code-only diffs.** Same session:

1. **`make test`** — must pass; add tests in `Tests/CodexGatewayTests/` for behavior you changed.
2. **`make run`** — rebuild + relaunch the `.app` (required before live checks; `make build` alone does not refresh the running app).
3. **Computer Use — always** — after any Swift/app change, verify the running app with Computer Use in the **same session**. Do not skip this, do not ask the user for screenshots instead, and do not mark the task done until you have actually driven the UI (or documented a hard blocker: missing Screen Recording / Accessibility permissions).
4. **Gateway smoke** — also `curl -s http://127.0.0.1:8765/health` when gateway routes or startup changed.
5. **`ARCHITECTURE.md`** — update routes, source map, config paths, or common tasks → files when structure/flow changes.
6. **`README.md`** — update when users would notice the change.
7. **`BUILDING.md`** — update when build/packaging/scripts change.
8. **Skills/rules** — update relevant `.cursor/skills/` or `.cursor/rules/` if workflow changed.

Exempt from Computer Use only: docs-only, comments, or pure test-only edits with zero app binary change.

Full checklist: `.cursor/rules/docs-and-tests.mdc`.

## Computer Use (required)

Always use Computer Use to test changes. Tooling order:

1. **`grokbuild-computer-use` MCP** (primary)
2. **`orca computer …` CLI** (fallback; needs Orca app running)
3. **`agent-desktop` CLI** (last fallback) — `agent-desktop skills get desktop --full`

### Required loop after `make run`

1. Confirm CodexGateway is running (`computer_list_apps` / `agent-desktop` app list / process list).
2. Open Settings (menu bar → **Settings**, or System Events click on status item menu bar 2).
3. Snapshot the Settings window (and sheets) — drive UI via `@refs` (click / type / wait).
4. Exercise the surface you changed (presets, providers, Fetch models, Add model, menu items, status copy). For diagnostics, open **Doctor…** (⌘D) and confirm the relevant checks.
5. For Codex Desktop effects: restart Codex, then verify with snapshot and/or screenshot (chat canvas has no a11y tree).

### Tooling notes

- MCP tools: `computer_list_apps`, `computer_snapshot`, `computer_screenshot`, `computer_click`, `computer_type`, `computer_press`, `computer_wait`, `computer_permissions`.
- `agent-desktop` examples: `agent-desktop snapshot --app CodexGateway`, `agent-desktop click --ref @e3`, `agent-desktop screenshot --app CodexGateway`.
- Read a tool's schema (or `agent-desktop skills get desktop`) before calling.
- No coordinate-click in the MCP; use snapshot `@refs`. Avoid System Events “click at”.
- If screenshots/actions fail, check Screen Recording / Accessibility (`computer_permissions` / `orca computer permissions` / TCC for `agent-desktop`).

## Common tasks

| Task | Command |
|------|---------|
| Package .app | `make app` → `dist/CodexGateway.app` |
| DMG | `make dmg` |
| Clean | `make clean` |
| Unit tests | `make test` |
| Install | `make install` |

## Codex Desktop dependency

App patches `~/.codex/config.toml` to route through the gateway. User needs Codex Desktop installed. Smoke test: `curl http://127.0.0.1:8765/health`.

## Architecture reminders

- Gateway: `GatewayServer` + `LoopbackHTTPServer`
- Translation: `Translator`
- Config: `ModelCatalog`, `CodexConfig`, `Paths`
- Menu bar: `StatusBarController` + `AppDelegate` (Settings, Doctor, About)
- Full map: `ARCHITECTURE.md`
- Do not commit unless the user asks.
