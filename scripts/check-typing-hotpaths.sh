#!/usr/bin/env bash
# Hard-fails if any commit in the PR diff touches a typing-latency hotpath
# unless the PR carries the `latency-reviewed` label.
#
# Policy reference: see /CLAUDE.md § "Typing-latency-sensitive paths" — those
# files participate in cmux's 0 ms typing-latency invariant. Any modification
# requires a senior reviewer signoff via the `latency-reviewed` PR label.
#
# Conservative scope choice: for ContentView.swift the policy actually only
# protects the `TabItemView` block, but this script flags any change to the
# whole file. The asymmetric cost (one extra label round-trip vs. shipping a
# typing regression) makes the conservative match the right default.
#
# Required env (provided by GitHub Actions):
#   BASE_SHA   — merge-base of the PR
#   HEAD_SHA   — head of the PR
#   PR_NUMBER  — PR number (used for label lookup via `gh`)
#   GH_REPO    — repo slug, e.g. g-mux/gmux

set -euo pipefail

BASE_SHA="${BASE_SHA:?}"
HEAD_SHA="${HEAD_SHA:?}"
PR_NUMBER="${PR_NUMBER:?}"
GH_REPO="${GH_REPO:?}"

HOTPATHS=(
  "Sources/TerminalWindowPortal.swift"
  "Sources/ContentView.swift"
  "Sources/GhosttyTerminalView.swift"
)

# --no-renames makes renames show as delete+add; we want to catch
# attempts to rename a hotpath out of its tracked location AND any
# new file that occupies a hotpath path.
changed=$(git diff --no-renames --name-only --diff-filter=ACMRD "$BASE_SHA" "$HEAD_SHA")
hits=()
for f in "${HOTPATHS[@]}"; do
  if printf '%s\n' "$changed" | grep -Fxq "$f"; then
    hits+=("$f")
  fi
done

if [[ ${#hits[@]} -eq 0 ]]; then
  echo "::notice::No typing-latency hotpath files touched."
  exit 0
fi

echo "::warning::Touched hotpath files:"
printf '  - %s\n' "${hits[@]}"

labels=$(gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json labels --jq '.labels[].name')
if printf '%s\n' "$labels" | grep -Fxq "latency-reviewed"; then
  echo "::notice::PR carries 'latency-reviewed'; allowing hotpath edit."
  exit 0
fi

echo "::error::Hotpath files modified without 'latency-reviewed' label." >&2
echo "Add the label after a senior reviewer signs off on the typing-latency impact." >&2
exit 1
