# Summary

<!-- What does this PR change, and why? Link related issues with "Fixes #123". -->

## Checklist

- [ ] `make check` passes locally (lint, build, test, and the DocC build — CI does not build docs)
- [ ] Tests added or updated for behavioral changes
- [ ] No force unwraps introduced in production code; concurrency uses `async`/`await` (no `DispatchQueue`)
- [ ] Public API changes are documented (doc comments, README, `docs/design/` as appropriate)
- [ ] User-visible changes noted under **Unreleased** in `CHANGELOG.md`
