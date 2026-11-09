# Contributing

Keep changes small and focused. `main` is the tested source for the next release.

## Changes

1. Start from an up-to-date `main`: `git switch main && git pull --ff-only`.
2. Create a short-lived branch, for example `git switch -c codex/describe-the-change`.
3. Implement the change and add regression checks when behavior or data handling changes. Record user-visible changes under **Unreleased** in `CHANGELOG.md`.
4. Run `./scripts/check.sh` on Apple silicon with macOS 27 or later and Swift 6.2 or later. This checks version metadata, Markdown, assets, rich text, editor behavior, window creation, and a release build.
5. Commit with a concrete description, push the branch, and open a pull request against `main`. Explain the resulting behavior and validation.
6. Merge with **Squash and merge** after **macOS checks** passes. GitHub deletes the merged branch automatically. No second reviewer is required for this small project.

GitHub runs the same checks for pull requests, pushes to `main`, and release tags. The `xcode-27` runner provides macOS 27 on Apple silicon. Generated apps, local work files, and build caches stay out of Git.

## Releases

Use `MAJOR.MINOR.PATCH` versions. While the app is below 1.0, use a minor increment for new features or breaking changes and a patch increment for fixes.

`Resources/Info.plist` is the source of truth: update `CFBundleShortVersionString` and increment the integer `CFBundleVersion` for each release. Move the Unreleased entries into a dated changelog section and update its comparison links in the same pull request.

After the release pull request has merged and checks have passed:

```sh
git switch main
git pull --ff-only
git tag -a v0.2.0 -m "Newline 0.2.0" # replace both versions for the next release
git push origin v0.2.0
```

Wait for the tag's **Checks** workflow to pass, then publish a GitHub release for that existing tag using its changelog entry. Release tags must match the app version; CI rejects mismatches. Published tags are never moved or deleted. Fix mistakes in a new version.

Releases currently distribute source code. App bundles built locally are ad-hoc signed, not Developer ID signed or notarized, and are not uploaded as release assets.

## Repository settings

The active rulesets protect `main` with pull requests, a linear history, and the required **macOS checks** status. Force pushes and deletion are blocked. Release tags matching `v*` cannot be changed or deleted. The definitions are tracked in `.github/rulesets/`; changing those files alone does not change GitHub settings. Repository administrators apply reviewed changes through GitHub's settings or ruleset API.
