---
name: gary-release
description: Release a new Gary version. Use when asked to cut, ship, or publish a release.
---

# Release Gary

1. Review the delta since the newest tag:

   ```sh
   last="$(git tag --list 'v*' --sort=-v:refname | head -1)"
   git log --no-merges --format='%h %s' "$last"..origin/main
   git diff --stat "$last"..origin/main
   ```

2. Check the docs against the delta. For every changed capability, node, style, config key, command, or default, search `README.md`, `docs/`, and the agent guide in `Sources/gary/SkillGuide.swift` and `Sources/gary/SkillReference.swift`. Fix stale text before you write notes.
3. Make `## Unreleased` in `CHANGELOG.md` cover the delta, grouped by user-facing area, with `### Upgrading` first and `### Fixes` last. Write for the people who use Gary or write plugins: what they can now do, what changed for them, and what they must change. Leave out refactors, tests, CI, and tooling. Check each API name against `gary plugin types`.
4. Pick the version. Before 1.0, a release with features or upgrade steps bumps the minor version, and a release with only fixes bumps the patch version.
5. Show the user the version and the final `## Unreleased` section verbatim, and the docs you checked. Get approval for that version and those notes.
6. Commit the changelog and doc fixes, and push them to `main`. Wait for CI to pass on that commit.
7. Run `just release <version>` from a clean `main`. After a failure, run the same command again.
8. Confirm that `gh release view v<version>` shows the notes and both assets, and that the cask in `../homebrew-tap/Casks/gary.rb` names the version.
