# GitHub Actions workflows

CI/CD for CodexGateway on `macos-latest`. See [BUILDING.md](../../BUILDING.md#github-releases) for release prep and the local `make release` alternative (including notarized builds).

| Workflow | File | When it runs |
|----------|------|--------------|
| **PR Checks** | [`pr.yml`](pr.yml) | Pull requests to `main`; manual dispatch |
| **Release** | [`release.yml`](release.yml) | Manual dispatch only (unsigned) |

---

## PR Checks (`pr.yml`)

Validates that the project builds and tests pass on macOS before merge.

### Triggers

- **`pull_request`** → branch `main`
- **`workflow_dispatch`** — run manually from **Actions → PR Checks → Run workflow**

### Concurrency

One run per ref (`pr-checks-${{ github.ref }}`). A newer push cancels an in-progress run for the same PR.

### Job: `test-and-build`

| Step | What it does |
|------|----------------|
| Checkout | `actions/checkout@v4` |
| Show Swift version | `swift --version` |
| Run tests | `make test` |
| Build unsigned app | `make app` |
| Verify bundle | Asserts `dist/CodexGateway.app` exists and `Contents/MacOS/CodexGateway` is executable |

### What it does **not** do

- No codesigning or notarization
- No DMG packaging
- No GitHub release publish

### Local equivalent

```bash
make test
make app
```

---

## Release (`release.yml`)

Builds **unsigned** distributable assets and publishes a **GitHub Release** for tag `v{VERSION}`.

### Triggers

**Manual dispatch only** — **Actions → Release → Run workflow**.

Tag push auto-release is commented out in the workflow file:

```yaml
# push:
#   tags:
#     - 'v*'
```

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `version` | *(empty)* | Optional tag override; must match `VERSION` (e.g. `v0.1.1`). Empty uses `v$(cat VERSION)`. |

### Preconditions

1. **`VERSION`** matches the release you intend to ship.
2. Changes are committed and pushed to the branch you release from.

The workflow **fails** if the release tag does not match `VERSION`.

### Job: `build`

Runs on `macos-latest` with `contents: write` (to create the release).

```bash
make app
make dmg-package
```

No Apple signing secrets required. Release title: **`v{VERSION} (Unsigned)`**. Notes include Gatekeeper bypass instructions.

`GITHUB_TOKEN` is provided automatically for release creation.

### Release outputs

| Asset | Purpose |
|-------|---------|
| `CodexGateway-{tag}.app.zip` | Portable app bundle |
| `CodexGateway-{tag}-macOS.dmg` | DMG installer |

### Local equivalents

```bash
make release                                              # unsigned (same as CI)
make release RELEASE_TYPE=notarized SIGN_IDENTITY="..." NOTARY_PROFILE=...  # notarized (local only)
```

See [`scripts/release.sh`](../../scripts/release.sh).

---

## Choosing a workflow

| Goal | Use |
|------|-----|
| Verify a PR before merge | **PR Checks** (automatic on PRs to `main`) |
| Ship an unsigned version to GitHub | **Release** (manual dispatch) |
| Ship a notarized version | Local **`make release RELEASE_TYPE=notarized`** |
| Quick local validation | `make test && make app` |

Use **one release path per version** — do not run CI Release and local `make release` for the same tag.
