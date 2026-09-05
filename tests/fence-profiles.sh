#!/usr/bin/env bash
# tests/fence-profiles.sh — fence profiles, end to end, against a throwaway repo.
#
#   bash tests/fence-profiles.sh
#
# No network, no model: `codex`, `claude` and `opencode` are stubbed on PATH and
# the real key file is swapped for an empty one, so a chain that reaches a real
# provider would fail loudly rather than quietly cost money. Needs git and
# python3 (>= 3.11, or the tomli backport) — the same requirements as `aw`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
AW="$HERE/../bin/aw"
[ -x "$AW" ] || { echo "no aw at $AW" >&2; exit 1; }

npass=0; nfail=0
ok()  { printf '  PASS  %s\n' "$1"; npass=$((npass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; nfail=$((nfail+1)); }
want_eq() { # want_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$3', got '$2'"; fi
}
want_in() { # want_in <label> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — '$3' not in output: $(printf '%s' "$2" | head -3 | tr '\n' ' ')" ;; esac
}
want_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 — missing: $2"; fi; }
want_absent() { if [ -e "$2" ]; then bad "$1 — present but should not be: $2"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/aw-fence-profiles.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

# ------------------------------------------------------------------- stubs
# Every model call must land here, never on a provider.
mkdir -p "$TMP/stubs" "$TMP/codex"
echo '{"stub":true}' > "$TMP/codex/auth.json"     # makes codex-sub "usable"
: > "$TMP/empty.env"
cat > "$TMP/stubs/claude" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-claude.log"
# An implementer must be able to write; prove the stub ran by leaving a file.
echo "written by the stub implementer" > backend/from-implementer.txt
echo "stub claude done"
STUB
cat > "$TMP/stubs/codex" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-codex.log"
echo "stub codex done"
STUB
cat > "$TMP/stubs/opencode" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-opencode.log"
echo "stub opencode done"
STUB
chmod +x "$TMP/stubs/"*

export AW_TEST_TMP="$TMP"
export PATH="$TMP/stubs:$PATH"
export LOOM_WORKTREES="$TMP/wt"
export LOOM_ENV="$TMP/empty.env"          # never source the developer's real keys
export CODEX_HOME="$TMP/codex"
export XDG_CACHE_HOME="$TMP/cache"
export LOOM_TIER=standard
unset ZHIPU_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY MOONSHOT_API_KEY \
      CODEX_API_KEY OPENAI_API_KEY LOOM_SKIP AW_FENCE_PROFILE 2>/dev/null || true

# ------------------------------------------------------------ target repo
mkdir -p "$REPO"/{core,ios,backend,docs/audits}/ "$REPO"/.agents/{tasks,plans,reviews} "$REPO"/.opencode/prompts
cd "$REPO" || exit 1
git init -q .
git config user.email test@example.invalid
git config user.name  "fence test"
echo "fn secret() {}"      > core/lib.rs
echo "// swift"            > ios/App.swift
echo "package main"        > backend/main.go
echo "open finding: none"  > docs/audits/a.md
: > .agents/reviews/.gitkeep
printf '#!/usr/bin/env bash\nexit 0\n' > .agents/gate.sh
chmod +x .agents/gate.sh
for p in implementer reviewer scout architect; do echo "stub $p prompt" > ".opencode/prompts/$p.md"; done

cat > .agents/zones.toml << 'TOML'
[fence]
reason = "test fence"
paths = ["core/**", "ios/**", "docs/audits/**"]

[fence_profiles.codex]
reason = "Anthropic + OpenAI may read and edit the custody core."
release = ["core/**", "docs/audits/**"]
providers = ["claude", "codex"]

[hand]
reason = "test hand zone: every fenced path, plus the control plane"
paths = ["core/**", "ios/**", "docs/audits/**", ".agents/zones.toml", ".agents/gate.sh"]

[assist]
reason = "the working surface"
paths = ["backend/**"]
TOML

mk_task() { # mk_task <id> [<profile-line>]
  { echo "# $1 — test task"; echo ""; echo "Plan: none"; echo "Zone: assist";
    [ -n "${2:-}" ] && echo "Fence-profile: $2"; } > ".agents/tasks/$1.md"
}
mk_task 0001-a; mk_task 0002-b; mk_task 0003-c; mk_task 0004-e; mk_task 0005-f codex; mk_task 0006-g
git add -A
git commit -qm init

echo "fence profiles"

# --- (a) no profile: everything fenced, guard blocks a fenced/hand path -----
out="$("$AW" new 0001-a 2>&1)"; rc=$?
want_eq   "(a) aw new without a profile succeeds"      "$rc" "0"
want_absent "(a) core/ is fenced out"                  "$TMP/wt/0001-a/core/lib.rs"
want_absent "(a) ios/ is fenced out"                   "$TMP/wt/0001-a/ios/App.swift"
want_absent "(a) docs/audits/ is fenced out"           "$TMP/wt/0001-a/docs/audits/a.md"
want_file   "(a) the working surface is present"       "$TMP/wt/0001-a/backend/main.go"

git checkout -q -b agent/guard-a
echo "// touched" >> core/lib.rs
git add core/lib.rs
out="$("$AW" guard 2>&1)"; rc=$?
want_eq  "(a) guard blocks a core/ commit with no profile" "$rc" "1"
want_in  "(a) guard names the path"                        "$out" "core/lib.rs"
git reset -q --hard

# --- (b) a profile with a chain that reaches a disallowed provider ---------
# shellcheck disable=SC2012  # the worktree names here are task ids we chose
before="$(ls "$TMP/wt" 2>/dev/null | tr '\n' ' ')"
out="$(LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0002-b --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed implementer chain"  "$rc" "1"
want_in  "(b) the message names the role"              "$out" "implementer chain"
want_in  "(b) the message names the model"             "$out" "deepseek/deepseek-v4-pro"
want_in  "(b) the message names the override"          "$out" "LOOM_MODELS_implementer"
want_absent "(b) no worktree was created"              "$TMP/wt/0002-b"
# shellcheck disable=SC2012  # the worktree names here are task ids we chose
want_eq  "(b) nothing else appeared under the worktree root" "$(ls "$TMP/wt" 2>/dev/null | tr '\n' ' ')" "$before"
# ... and the same for the reviewer chain.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="zai-coding-plan/glm-5.3" \
       "$AW" new 0002-b --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed reviewer chain"     "$rc" "1"
want_in  "(b) the message names the reviewer role"     "$out" "reviewer chain"

# --- (c) a profile with allowed chains: released paths are present ---------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq   "(c) aw new under the profile succeeds"      "$rc" "0"
want_file "(c) core/ is released into the worktree"    "$TMP/wt/0003-c/core/lib.rs"
want_file "(c) docs/audits/ is released"               "$TMP/wt/0003-c/docs/audits/a.md"
want_absent "(c) ios/ is still fenced"                 "$TMP/wt/0003-c/ios/App.swift"
want_eq   "(c) the profile is recorded on the branch"  \
          "$(git config branch.agent/0003-c.fenceprofile)" "codex"
out="$("$AW" ls 2>&1)"
want_in   "(c) aw ls shows the profile"                "$out" "fence-profile:codex"

# aw run re-applies AND verifies the fence, then commits: this is the path that
# proves fence_verify accepts a worktree holding released paths.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" run 0003-c 2>&1)"; rc=$?
want_eq  "(c) aw run under the profile reaches a green gate" "$rc" "0"
want_in  "(c) fence_verify passed (no 'STILL present')"      "$out" "gate green"
want_file "(c) the stub implementer ran"                     "$TMP/called-claude.log"
want_in  "(c) an implementer gets claude's edit permission"  "$(cat "$TMP/called-claude.log")" "acceptEdits"
want_in  "(c) the implementer prompt names the profile"      "$(cat "$TMP/called-claude.log")" "fence profile 'codex'"
want_absent "(c) no reviewer ran yet"                        "$TMP/called-codex.log"

# The reviewer must be told the released paths are in scope, and must stay
# read-only.
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0003-c 2>&1)"; rc=$?
want_eq  "(c) aw check under the profile succeeds"           "$rc" "0"
want_in  "(c) the reviewer is told the release is authorised" \
         "$(cat "$TMP/called-codex.log")" "are authorised for this task"
want_in  "(c) the reviewer sandbox stays read-only"          "$(cat "$TMP/called-codex.log")" "read-only"
case "$(cat "$TMP/called-codex.log")" in
  *workspace-write*|*--add-dir*) bad "(c) reviewer must never get a writable sandbox" ;;
  *)                             ok  "(c) reviewer never gets a writable sandbox" ;;
esac

# The same provider as an IMPLEMENTER gets the writable sandbox instead.
mv "$TMP/called-codex.log" "$TMP/called-codex-reviewer.log"
out="$(LOOM_MODELS_implementer="codex-sub" LOOM_MAX_ATTEMPTS=1 "$AW" run 0006-g 2>&1)"; rc=$?
want_eq "(c) a codex-sub implementer run succeeds"           "$rc" "0"
want_in "(c) an implementer gets codex's workspace-write"    "$(cat "$TMP/called-codex.log")" "workspace-write"
want_in "(c) ... and .agents made writable for the notes"    "$(cat "$TMP/called-codex.log")" "--add-dir"

# --- (d) the guard under a profile ----------------------------------------
git checkout -q -b agent/guard-d
git config branch.agent/guard-d.fenceprofile codex
echo "// touched" >> core/lib.rs
git add core/lib.rs
out="$("$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard ALLOWS a released core/ commit under the profile" "$rc" "0"
git add .agents/zones.toml 2>/dev/null || true
printf '\n# tampered\n' >> .agents/zones.toml
git add .agents/zones.toml
out="$("$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard still blocks the control plane"        "$rc" "1"
want_in "(d) the block names zones.toml"                  "$out" ".agents/zones.toml"
want_in "(d) the block names what the profile released"   "$out" "releases only"
case "$out" in *core/lib.rs*) bad "(d) a released path must not be listed as a violation" ;;
               *)             ok  "(d) the released path is not listed as a violation" ;; esac
git reset -q --hard
echo "// touched" >> ios/App.swift
git add ios/App.swift
out="$("$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard blocks a fenced path the profile did NOT release" "$rc" "1"
git reset -q --hard
git checkout -q master 2>/dev/null || git checkout -q main

# --- (e) unknown profile ---------------------------------------------------
out="$("$AW" new 0004-e --fence-profile nope 2>&1)"; rc=$?
want_eq "(e) an unknown profile dies"                     "$rc" "1"
want_in "(e) the message says which are defined"          "$out" "unknown fence profile 'nope'"
want_absent "(e) no worktree was created"                 "$TMP/wt/0004-e"

# --- (f) opt-in through the task file -------------------------------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0005-f 2>&1)"; rc=$?
want_eq   "(f) a 'Fence-profile:' task line opts in"      "$rc" "0"
want_eq   "(f) it is recorded on the branch"              \
          "$(git config branch.agent/0005-f.fenceprofile)" "codex"
want_file "(f) the released path is present"              "$TMP/wt/0005-f/core/lib.rs"
want_absent "(f) the unreleased fenced path is not"       "$TMP/wt/0005-f/ios/App.swift"
# The same task file, with a disallowed chain, must still die.
out="$(LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" "$AW" check 0005-f 2>&1)"; rc=$?
want_eq "(f) a later command re-checks the chain"         "$rc" "1"

# --- (g) the branch record wins over a task file edited afterwards ---------
printf 'Fence-profile: codex\n' >> .agents/tasks/0001-a.md
out="$("$AW" check 0001-a 2>&1)"; rc=$?
want_eq "(g) a task file that gains a profile late is refused" "$rc" "1"
want_in "(g) the refusal explains how to fix it"               "$out" "aw drop 0001-a"
git checkout -q -- .agents/tasks/0001-a.md

# --- (h) fail-closed parsing ----------------------------------------------
cp .agents/zones.toml "$TMP/zones.good"
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.bogus]
release = ["backend/**"]
providers = ["claude"]
TOML
out="$("$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a release outside [fence] is refused"        "$rc" "1"
want_in "(h) ... with a reason"                           "$out" "not one of [fence].paths"
cp "$TMP/zones.good" .agents/zones.toml
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.bogus2]
release = ["core/**"]
TOML
out="$("$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a profile without providers is refused"      "$rc" "1"
cp "$TMP/zones.good" .agents/zones.toml

# --- (i) an inherited AW_FENCE_PROFILE must not widen anything ------------
out="$(AW_FENCE_PROFILE=codex "$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(i) the environment cannot activate a profile"   "$rc" "0"
want_in "(i) core/ is still reported as fenced"           "$out" "fenced"

# --- (j) doctor lists the profiles ----------------------------------------
out="$(timeout 180 "$AW" doctor 2>&1 || true)"
want_in "(j) doctor lists the profile"                    "$out" "fence profile 'codex'"
want_in "(j) doctor names its providers"                  "$out" "claude codex"
want_in "(j) doctor still reports the fence"              "$out" "fence: 3 pattern(s)"

echo ""
echo "tests/fence-profiles.sh: $npass passed, $nfail failed"
[ "$nfail" -eq 0 ]
