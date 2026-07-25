---
name: codexgateway-release
description: Versions, packages, signs, notarizes, and publishes CodexGateway GitHub releases. Use when bumping VERSION, running make release, editing release.yml, or helping with codesigning/notarization.
---

# CodexGateway release

## Version files

- `VERSION` — semver baked into Info.plist at package time; About/menu prefer that, with a `VERSION`-file fallback for unpackaged builds (e.g. `1.0.0`)
- Tag format: `v{VERSION}` (e.g. `v1.0.0`)

## CI release (unsigned)

Workflow: `.github/workflows/release.yml` — **Actions → Release → Run workflow**. Publishes unsigned `.app.zip` + DMG only.

**Notarized release:** local `make release RELEASE_TYPE=notarized` with `.env` (`SIGN_IDENTITY`, `NOTARY_PROFILE`).

## Local release

```bash
cp .env.example .env   # optional: SIGN_IDENTITY, NOTARY_PROFILE
make release           # unsigned, publishes via gh
make release RELEASE_TYPE=notarized
```

Script: `scripts/release.sh`. Requires `gh auth login`. Use one path per version — CI or local, not both.

If `make release` fails while pushing `v{VERSION}` with “already exists”, the script should force-update the remote tag when HEAD differs (lightweight tags must fall back from `tag^{}` to `refs/tags/<tag>`). Re-run `make release` after pulling the script fix, or finish a mid-flight notarized publish with:

```bash
git push --force origin "refs/tags/v{VERSION}"
gh release create "v{VERSION}" --title "v{VERSION} (Notarized)" \
  dist/CodexGateway-v{VERSION}.app.zip dist/CodexGateway-v{VERSION}-macOS.dmg
```

(Use `gh release upload … --clobber` if the release already exists.)

## Checklist

1. Bump `VERSION`
2. **`make test`** — must pass; add tests if release/packaging logic changed
3. `make app` or `make dmg` to verify packaging
4. **Update docs** — `BUILDING.md`, `README.md` (install), `ARCHITECTURE.md` if structure changed
5. Commit on feature branch; user creates tag/PR
6. Do not force-push `main` or skip git hooks unless asked

## Packaging

- Bundle ID: `com.rimusz.CodexGateway`
- App bundle: `dist/CodexGateway.app`, executable `CodexGateway`
- DMG: `dist/CodexGateway-macOS.dmg`
- Release zip: `CodexGateway-{tag}.app.zip` only (do not publish `CodexBar-*.app.zip`)
- GitHub repo: `rimusz/codex-gateway` (legacy `rimusz/codex-bar` redirects; updater queries both)
- Scripts: `scripts/build-macos-app.sh`, `scripts/codesign-app-bundle.sh`, `scripts/notarize.sh`, `scripts/codexgateway-install-update.sh`

### Upgrade / legacy (from CodexBar)

- Old bundle ID `com.rimusz.CodexBar` — Login Items may need re-enable after upgrade
- Legacy install helper `codexbar-install-update`
- Older releases may still have `CodexBar-{tag}.app.zip`; new releases publish only `CodexGateway-{tag}.app.zip`

When changing release naming, assets, packaging, or in-app update behavior, update `BUILDING.md` and `ARCHITECTURE.md`.
