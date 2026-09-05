#!/usr/bin/env bash
# The gate: the deterministic reviewer. Agents are not done until this is green.
# Auto-detects project type; replace the branch for your repo if you outgrow it.
# Output stays in native tool format so your editor's error parser can read it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

fail=0
run() { echo "▶ $*" >&2; "$@" || fail=1; }

# An explicit `gate` target in a Makefile is the repo telling you what its gate
# is. Believe it, and skip auto-detection entirely.
if [ -f Makefile ] && grep -qE '^gate:' Makefile; then
  run make gate
elif [ -f Cargo.toml ]; then
  run cargo fmt --all -- --check
  run cargo clippy --all-targets --quiet -- -D warnings
  run cargo test --quiet
elif [ -f package.json ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -e '.scripts.lint'      package.json >/dev/null 2>&1 && run npm run --silent lint
    jq -e '.scripts.typecheck' package.json >/dev/null 2>&1 && run npm run --silent typecheck
    jq -e '.scripts.test'      package.json >/dev/null 2>&1 && run npm test --silent
  else
    run npm test --silent
  fi
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  command -v ruff   >/dev/null 2>&1 && run ruff check .
  command -v pytest >/dev/null 2>&1 && run pytest -q
elif [ -f Makefile ] && grep -qE '^check:' Makefile; then
  run make check
else
  echo "gate: no recognized project type — edit .agents/gate.sh for this repo" >&2
fi

if [ "$fail" -ne 0 ]; then echo "GATE: RED" >&2; else echo "GATE: GREEN" >&2; fi
exit "$fail"
