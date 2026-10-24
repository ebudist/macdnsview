# MacDNSView

macOS app and CLI that looks up DNS records for a list of Targets against any DNS server and exports the results. Behavior follows NirSoft DNSDataView, rebuilt clean-room for macOS.

- Domain terms: `CONTEXT.md`. Use its words in code, docs, issues, and commits.
- CI and the release steps: `docs/release.md`.
- Past decisions and their reasons: `docs/adr/`. Read the ADRs before changing DNS transport, server selection, or the build setup.

## Build and check

```
swift build
swift test
scripts/check-prose.sh                       # tracked text
scripts/check-prose.sh --commits main..HEAD  # plus commit messages
scripts/bundle.sh                            # release .app and CLI in dist/
```

A change is done when all three pass. With Command Line Tools only (no Xcode), Swift 6.4 sometimes fails to load the `TestingMacros` plugin after a source change; `swift test -j 1` makes it rarer, and a rerun passes. Tests that hit the network run only with `MACDNSVIEW_NET_TESTS=1`; everything else runs offline against captured response fixtures.

## Code

- `MacDNSViewCore` holds all DNS, parsing, and export logic and imports Foundation, Network, and SystemConfiguration only. `macdnsview` (CLI) and `MacDNSViewApp` (SwiftUI) stay thin.
- Swift 6 language mode, strict concurrency, macOS 14 minimum.
- Stdlib and Apple frameworks only. A new package dependency needs an ADR first.
- Each new record type ships with its decoder and a fixture captured from a real server response.
- Comments are one short line, written only where the code is not self-explanatory.

## Writing

Covers docs, code comments, issues, commit messages, and PR descriptions.

- Plain English, short sentences, written as the project engineer. Docs use neutral or imperative voice; ADRs and PR descriptions may use "I".
- Use commas, colons, periods, or parentheses where a dash might go. `scripts/check-prose.sh` holds the full list of rejected characters and words.
- Commits: one-line conventional commit subject (`feat:`, `fix:`, `docs:`, `chore:`, ...), no body. Detail goes in the PR description.
- PR descriptions open with two or three sentences on why the change exists, then what changed. A PR that resolves a GitHub issue says `Fixes #N`.
- Authorship stays with the human committer: commits and PRs carry no assistant attribution.

## Clean-room

Write everything from the behavior description in issues and ADRs. Strings, icons, help text, and code from DNSDataView stay out of the repo, and so do reverse-engineering notes and disassembly (`notes/` is gitignored for that).
