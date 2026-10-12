#!/usr/bin/env bash
# Fails on dashes, emoji, and AI attribution in tracked files, and on filler words in prose and commit messages.
# Usage: scripts/check-prose.sh [--commits <rev-range>]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# One regex per line, matched case-insensitively. `everywhere` applies to code too; `words` only to prose.
everywhere=(
  '\x{2014}' '\x{2013}'
  '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]'
  'co-authored-by:.*(claude|anthropic|copilot|openai)' 'generated (with|by) .*(claude|ai\b|chatgpt|copilot)'
)
words=(
  '\bdelv(e|es|ing)\b' '\bseamless(ly)?\b' '\brobust\b' '\bleverag(e|es|ed|ing)\b'
  '\bcomprehensive\b' '\butiliz(e|es|ed|ing)\b' '\bcutting-edge\b' '\bgame-?changer\b'
  '\bempower' '\bstreamlin' '\bunlock(s|ing)?\b' '\belevat(e|es|ing)\b' '\btapestry\b'
  '\bpivotal\b' '\bvibrant\b' '\bshowcas' '\bmoreover\b' '\bfurthermore\b'
  "it's worth noting" "in today's" '\bnavigat(e|ing) the\b' '\bdive (deep )?into\b'
)
code=$(IFS='|'; echo "${everywhere[*]}")
prose=$(IFS='|'; echo "${everywhere[*]}|${words[*]}")

check() { # $1 = pattern, $2 = label, stdin = text
  PATTERN="$1" LABEL="$2" perl -CSD -ne '
    BEGIN { $re = qr/$ENV{PATTERN}/i; $bad = 0 }
    if (/$re/) { print "$ENV{LABEL}:$.: $_"; $bad = 1 }
    END { exit $bad }'
}

status=0
while IFS= read -r f; do
  if [[ "$f" == *.md ]]; then check "$prose" "$f" < "$f" || status=1; else check "$code" "$f" < "$f" || status=1; fi
done < <(git ls-files '*.md' '*.swift' '*.yml' '*.sh' | grep -vx 'scripts/check-prose.sh')

if [[ "${1:-}" == "--commits" ]]; then
  conventional='^(feat|fix|docs|chore|refactor|test|ci|build|perf|style|revert)(\([a-z0-9-]+\))?!?: \S'
  while IFS= read -r sha; do
    git log -1 --format=%B "$sha" | check "$prose" "commit $sha" || status=1
    git log -1 --format=%s "$sha" | grep -Eq "$conventional" \
      || { echo "commit $sha: subject is not a conventional commit"; status=1; }
  done < <(git rev-list --no-merges "$2")
fi

exit $status
