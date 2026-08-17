---
name: codexgateway-release
description: Publishes the current CodexGateway version from an updated main branch with make release. Use when the user asks to release CodexGateway.
---

# CodexGateway release

Release the current version from `main`:

1. Check `git status`. If the working tree is dirty, stop and ask the user how to handle the changes; never discard them.
2. Switch to and update `main`:

```sh
git switch main
git pull --ff-only
```

3. Run the release:

```sh
make release
```

Monitor the command through completion and report the release URL or the exact failure. Do not force-push, move tags, or retry destructive recovery without explicit user approval.
