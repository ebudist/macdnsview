# CI and releases

Two GitHub Actions workflows live in `.github/workflows/`: `ci.yml` checks every push to `main` and every pull request, and `release.yml` publishes a version when its tag is pushed.

```
commit  →  local checks  →  push to main  →  ci.yml
                                               ↓ green
                           push tag vX.Y.Z  →  release.yml
                                               ↓
                              GitHub Release and Homebrew formula update
```

## Before pushing

Run the same checks CI runs, so a push does not turn `main` red:

```
swift test -j 1
scripts/check-prose.sh --commits origin/main..HEAD
```

`check-prose.sh` checks tracked text and commit messages against the writing rules in `AGENTS.md`. With Command Line Tools only, `swift test` sometimes fails to load the `TestingMacros` plugin; rerun it.

## CI: `ci.yml`

Runs on `macos-latest` for every push to `main` and every pull request, with a read-only token. Pushes and pull requests that only change Markdown files or `docs/` skip it, so run the prose check locally for those.

1. Check out the full history, which the prose check needs.
2. Check prose for the commits in the push, or for all commits of a pull request against its base branch.
3. `swift build`.
4. `swift test`, the debug build.
5. `swift test -c release -Xswiftc -enable-testing`, the same tests compiled in release mode. Some Swift compiler bugs only show up in optimized builds, so both are tested.

A red CI on `main` is fixed with a new commit, not a revert.

## Releasing a version

Maintainers only, since it needs push access and the tap token.

1. Commit `chore: release vX.Y.Z`, which changes only the version in `Sources/MacDNSViewCore/Version.swift`. Push it together with the commits it ships, so CI runs once.
2. Wait for CI to pass on that commit.
3. Tag it and push the tag on its own:

   ```
   git tag -a vX.Y.Z -m vX.Y.Z <sha>
   git push origin refs/tags/vX.Y.Z:refs/tags/vX.Y.Z
   ```

## Release: `release.yml`

Runs when a `v*` tag is pushed, with permission to write releases.

1. Check that the tag matches `Version.swift`. A tag of `v0.11.0` needs `version = "0.11.0"`, so a release cannot ship under the wrong number.
2. `swift test`.
3. `scripts/bundle.sh`: a universal (arm64 and x86_64) release build, `MacDNSView.app` assembled with its icon and `Info.plist`, the app and CLI signed ad hoc with the hardened runtime, and two zips in `dist/`: `MacDNSView-X.Y.Z.zip` and `macdnsview-cli-X.Y.Z.zip`.
4. Create the GitHub Release for the tag with both zips attached and notes generated from the commits.
5. Update `Formula/macdnsview.rb` in [ebudist/homebrew-tap](https://github.com/ebudist/homebrew-tap): point `url` at the tag's source tarball and set its `sha256`. The commit goes through the GraphQL `createCommitOnBranch` mutation, so GitHub signs it, and `expectedHeadOid` keeps it from overwriting a change that landed meanwhile. It uses the `TAP_TOKEN` secret, a fine-grained token that can write only to the tap repository and has to be renewed when it expires.

Homebrew builds the formula from source on the user's Mac; the zips are for downloading by hand.

## Signing

Releases are signed ad hoc, not with a Developer ID, and are not notarized. Browsers mark downloaded zips as quarantined, so Gatekeeper blocks them until the quarantine flag is removed, as the README describes. Homebrew builds locally, so its install is not quarantined.
