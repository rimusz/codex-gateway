# CodexGateway

Pure-Swift macOS menu-bar app with an embedded gateway for Codex Desktop.

## Read first

@ARCHITECTURE.md — app map, gateway routes, config paths, and **“common tasks → files”** lookup for new chats.

## Cursor in this repo

- Rules: `.cursor/rules/` (architecture, Swift/AppKit, gateway integration, menu bar, **docs-and-tests**)
- Skills: `.cursor/skills/` (dev workflow, release, gateway/Codex integration, ship-pr)
- Agents: `.cursor/agents/` (planner, implementer, auditor, verifier for orchestrator mode)

## Boundaries

CodexGateway owns the local gateway (`127.0.0.1:8765`), menu bar UI, and `~/.codex` / `~/.codexgateway` config management. Codex Desktop owns the chat UI and agent runtime.

When changing gateway or Codex integration:

1. Prefer existing services: `GatewayServer`, `Translator`, `ModelCatalog`, `CodexConfig`, `CodexAppServer`.
2. Keep menu bar state in `StatusBarController` + `APIClient` health polling.
3. Post status via `CodexGatewayStatusChanged` when gateway health changes.
4. Do not add an Xcode project; stay on SwiftPM + Makefile scripts.

## Code style

- Minimize diff scope; match surrounding Swift conventions.
- Version strings: `VERSION` file, surfaced through `AppVersion`.
- Build with `make run` or `swift build`; test with `make test`.

## Documentation & tests (required)

Every code change must ship with **updated documentation** and **tests** in the same session — not as a follow-up.

1. **Tests** — run `make test`; add or extend `Tests/CodexGatewayTests/` for new or changed behavior.
2. **Live verification** — for any Swift/app change: `make run`, `curl /health` when gateway-related, and **always use Computer Use to test changes** (`grokbuild-computer-use` MCP → `orca computer` → `agent-desktop` last). Do not skip Computer Use or ask the user for screenshots instead.
3. **ARCHITECTURE.md** — update for new services, routes, config paths, or flows.
4. **README.md** — update for user-visible features or install/requirements changes.
5. **BUILDING.md** — update for build, release, packaging, or script changes.
6. **Skills / rules** — update `.cursor/skills/` or `.cursor/rules/` when workflows change.

See `.cursor/rules/docs-and-tests.mdc` for the full checklist.
