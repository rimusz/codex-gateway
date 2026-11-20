# Using CodexGateway with [Zero](https://zero.gitlawb.com)

[Zero](https://zero.gitlawb.com) is a terminal coding agent that supports any **OpenAI-compatible** API. You can point it at the CodexGateway gateway on the same Mac and use the models you configured in CodexGateway Settings — Anthropic/Claude, Cline Pass, Ollama, DeepSeek, Google Gemini, xAI via your keys, and so on.

CodexGateway must be **running** (menu bar icon present). The gateway is local-only:

| Item | Value |
|------|--------|
| Base URL | `http://127.0.0.1:8765/v1` |
| Health | `http://127.0.0.1:8765/health` |
| Model list | `GET http://127.0.0.1:8765/v1/models` |

Provider API keys live in CodexGateway (`~/.codexgateway/providers.json`); Zero only needs a **dummy** credential so its `custom-openai-compatible` profile passes auth checks.

## Prerequisites

1. CodexGateway is running and the gateway is healthy:

   ```bash
   curl -s http://127.0.0.1:8765/health
   ```

2. Models are installed in **CodexGateway → Settings** (providers + models, **Update Gateway Config** if needed).

3. [Zero](https://zero.gitlawb.com) is installed (`npm install -g @gitlawb/zero` or see Zero's install docs).

## One-time setup (CLI)

Add CodexGateway as a **Custom OpenAI-compatible** provider. Use catalog id `custom-openai-compatible` (not a made-up name like `codexgateway`):

```bash
zero providers add custom-openai-compatible \
  --name codexgateway \
  --base-url http://127.0.0.1:8765/v1 \
  --model clinepass/cline-pass-glm-5.2 \
  --auth-header-value not-used \
  --set-active
```

- `--name codexgateway` — your profile label (any name you like).
- `--model` — default model slug; pick one from `zero providers models codexgateway` (see below).
- `--auth-header-value not-used` — stored dummy key (CodexGateway ignores it for custom models; Zero requires *something* for this profile type).

**Alternative:** set an env var instead of storing a key:

```bash
export OPENAI_API_KEY=not-used
zero providers add custom-openai-compatible \
  --name codexgateway \
  --base-url http://127.0.0.1:8765/v1 \
  --model clinepass/cline-pass-glm-5.2 \
  --api-key-env OPENAI_API_KEY \
  --set-active
```

## Verify setup

```bash
zero providers check codexgateway --connectivity
zero providers models codexgateway
zero providers current
```

You want `status: ok` and `connectivity: pass`. `zero providers models codexgateway` lists the custom model slugs the gateway exposes.

## CLI — providers & models

| Command | Purpose |
|---------|---------|
| `zero providers list` | All saved provider profiles |
| `zero providers current` | Active provider + model |
| `zero providers use codexgateway` | Switch to the CodexGateway profile |
| `zero providers models codexgateway` | Live list from CodexGateway `/v1/models` |
| `zero providers check codexgateway --connectivity` | Auth + reachability |
| `zero providers catalog` | Built-in provider types (`custom-openai-compatible`, etc.) |

**Change default model** on the profile (re-run add with a new `--model`):

```bash
zero providers add custom-openai-compatible \
  --name codexgateway \
  --base-url http://127.0.0.1:8765/v1 \
  --model clinepass/cline-pass-kimi-k2.7-code \
  --auth-header-value not-used \
  --set-active
```

## CLI — run tasks (headless)

```bash
# One-shot prompt (uses active provider unless --model overrides)
zero exec "explain this repo"

# Explicit model slug from CodexGateway
zero exec --model clinepass/cline-pass-glm-5.2 "fix the failing test in ./pkg"

# Scriptable / CI-style I/O
zero exec --output-format stream-json "summarize main.go"
```

Model slugs must match **`zero providers models codexgateway`** exactly (e.g. `clinepass/cline-pass-glm-5.2`, not the raw Cline Pass upstream id).

## TUI — interactive terminal

Start Zero with the **codexgateway** profile already active (do this in a normal terminal, not inside the TUI):

```bash
zero providers use codexgateway
zero
```

If you used `--set-active` when you ran `zero providers add`, **codexgateway** is already the active profile — you can run `zero` directly. Check anytime:

```bash
zero providers current
```

Inside the TUI, `/config` or the bottom status line shows the active provider and model (you want **codexgateway** · your model slug).

> **`/provider` is for managing providers** (add / edit / delete), not for switching. Use **`zero providers use codexgateway`** in a shell before launching `zero`, or rely on `--set-active` from setup.

### Changing the model in TUI

CodexGateway models are **not** reliably listed in Zero's `/model` search picker. Use one of these methods instead:

**Method 1 — `/model <slug>` (best for switching mid-session)**

1. Confirm **codexgateway** is active (status bar or `/config`). If not, exit the TUI and run `zero providers use codexgateway`, then `zero` again.

2. In another terminal, list valid slugs:

   ```bash
   zero providers models codexgateway
   ```

3. In the Zero TUI, switch model by typing the **full slug** (no picker needed):

   ```text
   /model clinepass/cline-pass-glm-5.2
   ```

   Other examples:

   ```text
   /model clinepass/cline-pass-kimi-k2.7-code
   /model clinepass/cline-pass-deepseek-v4-pro
   /model gpt-5.4
   ```

4. Confirm the switch — Zero prints a status line showing the new model. The status bar at the bottom of the TUI also updates (provider · model).

**Method 2 — Set default before starting Zero (CLI)**

Change the profile's default model, then launch `zero`:

```bash
zero providers add custom-openai-compatible \
  --name codexgateway \
  --base-url http://127.0.0.1:8765/v1 \
  --model clinepass/cline-pass-kimi-k2.7-code \
  --auth-header-value not-used \
  --set-active

zero
```

New sessions start on that model. Use **Method 1** to switch again without restarting.

**Method 3 — `/model` picker + Recent**

After you switch with `/model <slug>` once, that model appears under **Recent** in `/model` for quicker re-selection. The graphical picker may still not show Cline Pass models when you search — use Recent or type the slug directly.

### Other TUI / CLI commands

| Action | How |
|--------|-----|
| Switch to CodexGateway provider | **`zero providers use codexgateway`** (in shell, before or after exiting TUI) |
| Add/edit providers in TUI | `/provider add` or `/provider` (manager — not for picking active provider) |
| Show active provider + model | `/config` or bottom status line; CLI: `zero providers current` |
| List models | `zero providers models codexgateway` |
| Check setup | `/doctor` or `zero doctor` |

**`/model` picker limitation:** Zero's graphical model picker uses a static placeholder catalog for `custom-openai-compatible` and often **does not list** CodexGateway's live models (searching `cline` may show "no matching models"). This is a Zero behavior, not a CodexGateway bug.

CodexGateway models appear under provider group **"Custom OpenAI-compatible"** in `/model`, not "CodexGateway". Sections like **xAI** or **MiniMax** in the picker are **other** Zero profiles talking directly to those APIs, not through CodexGateway.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `unknown provider "codexgateway"` on `providers add` | Use catalog id **`custom-openai-compatible`**, not `codexgateway`. |
| `unknown flag "--api-key"` | Use **`--auth-header-value`** or **`--api-key-env`**, not `--api-key`. |
| `requires API credentials` / connectivity fail | Set **`--auth-header-value not-used`** or `export OPENAI_API_KEY=not-used`. |
| `zero providers models` works but TUI picker is empty | Use **`/model <full-slug>`** inside TUI (see **Changing the model in TUI** above). |
| Wrong provider active (xAI, MiniMax, etc.) | Exit TUI; run **`zero providers use codexgateway`**, then **`zero`** again. |
| Connection refused | Start CodexGateway; confirm `curl http://127.0.0.1:8765/health`. |
| Model not found at runtime | Slug must match `zero providers models codexgateway`; re-export from CodexGateway Settings if you added models recently. |

See also [troubleshooting.md](troubleshooting.md) for Codex Desktop / CLI daemon issues.
