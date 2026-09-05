#!/usr/bin/env bash
# tests/fence-profiles.sh — fence profiles, end to end, against a throwaway repo.
#
#   bash tests/fence-profiles.sh
#
# No network, no model: `codex`, `claude`, `opencode` and `curl` are stubbed on
# PATH, the real key file is swapped for an empty one, and the models.dev
# catalog `loom doctor` would fetch is seeded in $XDG_CACHE_HOME — so a chain that
# reaches a real provider, or a doctor run that reaches the network, fails
# loudly rather than quietly costing money. Needs git and python3 (>= 3.11, or
# the tomli backport) — the same requirements as `loom`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
LOOM="$HERE/../bin/loom"
[ -x "$LOOM" ] || { echo "no loom at $LOOM" >&2; exit 1; }

npass=0; nfail=0
ok()  { printf '  PASS  %s\n' "$1"; npass=$((npass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; nfail=$((nfail+1)); }
want_eq() { # want_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$3', got '$2'"; fi
}
want_in() { # want_in <label> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — '$3' not in output: $(printf '%s' "$2" | head -3 | tr '\n' ' ')" ;; esac
}
want_not_in() { # want_not_in <label> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 — '$3' IS in output: $(printf '%s' "$2" | head -3 | tr '\n' ' ')" ;; *) ok "$1" ;; esac
}
want_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 — missing: $2"; fi; }
want_absent() { if [ -e "$2" ]; then bad "$1 — present but should not be: $2"; else ok "$1"; fi; }
want_fail()   { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1 — the command exited 0"; fi; }
sedi() { if sed --version >/dev/null 2>&1; then sed -i -e "$1" "$2"; else sed -i '' -e "$1" "$2"; fi; }
want_ne()     { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 — both are '$2'"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/loom-fence-profiles.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

# ------------------------------------------------------------------- stubs
# Every model call must land here, never on a provider. Every network call must
# land on the curl stub, which records itself so a test can prove it never ran.
mkdir -p "$TMP/stubs" "$TMP/codex" "$TMP/cache/loom"
echo '{"stub":true}' > "$TMP/codex/auth.json"     # makes codex-sub "usable"
: > "$TMP/empty.env"
cat > "$TMP/stubs/claude" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${LOOM_TEST_TMP:?}/called-claude.log"
# A hostile first attempt, for the per-attempt reconcile test: widen the
# worktree the harness just fenced, then look rate-limited so `loom` falls back
# to the next model in the chain with the widened tree already on disk.
if [ -n "${LOOM_TEST_RELAX_SPARSE:-}" ]; then
  git sparse-checkout disable > /dev/null 2>&1 || true
  echo "429 rate limit exceeded"
  exit 1
fi
# An implementer must be able to write; prove the stub ran by leaving a file.
echo "written by the stub implementer" > backend/from-implementer.txt
echo "stub claude done"
STUB
cat > "$TMP/stubs/codex" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${LOOM_TEST_TMP:?}/called-codex.log"
echo "stub codex done"
STUB
cat > "$TMP/stubs/opencode" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${LOOM_TEST_TMP:?}/called-opencode.log"
# The directory grant and the CONFIG are the things under test: record both
# verbatim. opencode resolves its project config from the cwd, which is a
# worktree the agent can write, so which config it was handed is a security
# fact, not a detail.
printf 'OPENCODE_PERMISSION=%s\n' "${OPENCODE_PERMISSION:-(unset)}" \
  >> "${LOOM_TEST_TMP:?}/called-opencode.log"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-(unset)}" \
  >> "${LOOM_TEST_TMP:?}/called-opencode.log"
printf 'OPENCODE_DISABLE_PROJECT_CONFIG=%s\n' "${OPENCODE_DISABLE_PROJECT_CONFIG:-(unset)}" \
  >> "${LOOM_TEST_TMP:?}/called-opencode.log"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-(unset)}" \
  >> "${LOOM_TEST_TMP:?}/called-opencode.log"
# An INLINE config in an environment variable: a provider baseURL and a set of
# role prompts with no file for `loom` to point at. It must never arrive.
printf 'OPENCODE_CONFIG_CONTENT=%s\n' "${OPENCODE_CONFIG_CONTENT:-(unset)}" \
  >> "${LOOM_TEST_TMP:?}/called-opencode.log"
echo "stub opencode done"
STUB
cat > "$TMP/stubs/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${LOOM_TEST_TMP:?}/called-curl.log"
exit 1
STUB
chmod +x "$TMP/stubs/"*

# The catalog `loom doctor` fetches from models.dev, seeded fresh so the fetch is
# skipped: every model ID in the default chains, so doctor has an offline answer.
cat > "$TMP/cache/loom/models-dev.json" << 'JSON'
{
  "zai-coding-plan": {"models": {"glm-5.3": {"id": "glm-5.3"}, "glm-5.3-flash": {"id": "glm-5.3-flash"}}},
  "moonshotai":      {"models": {"kimi-k2.5": {"id": "kimi-k2.5"}, "kimi-k2.7-code": {"id": "kimi-k2.7-code"}}},
  "deepseek":        {"models": {"deepseek-v4-pro": {"id": "deepseek-v4-pro"}, "deepseek-v4-flash": {"id": "deepseek-v4-flash"}}}
}
JSON

export LOOM_TEST_TMP="$TMP"
export PATH="$TMP/stubs:$PATH"
export LOOM_WORKTREES="$TMP/wt"
# Two roots, because a profiled task's worktree holds released paths and must
# not sit inside the directory an unprofiled run (or the scout mirror) is
# pointed at. $WTP is a SIBLING of $WTU, never a child.
WTU="$TMP/wt"                 # unprofiled worktree root  (= $LOOM_WORKTREES)
WTP="$TMP/wt-profiled"        # profiled worktree root
export LOOM_ENV="$TMP/empty.env"          # never source the developer's real keys
export CODEX_HOME="$TMP/codex"
export XDG_CACHE_HOME="$TMP/cache"
# The operator task state lives under $XDG_CONFIG_HOME, so it is redirected
# into the sandbox: a test run must never write to the developer's real
# ~/.config/loom, and must never read a record from it either.
export XDG_CONFIG_HOME="$TMP/config"
export LOOM_TIER=standard
unset ZHIPU_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY MOONSHOT_API_KEY \
      CODEX_API_KEY OPENAI_API_KEY LOOM_SKIP LOOM_FENCE_PROFILE 2>/dev/null || true

# ------------------------------------------------------------ target repo
mkdir -p "$REPO"/{core,ios,backend,docs/audits}/ "$REPO"/.agents/{tasks,plans,reviews} "$REPO"/.opencode/prompts
cd "$REPO" || exit 1
# Where `loom` keeps the OPERATOR RECORD for this repo: outside every repository
# and outside the shared .git, keyed by the sha256 of the main checkout's real
# path. Tests read it exactly the way `loom` does, so a change of layout shows up
# here rather than silently passing.
REPO_REAL="$(pwd -P)"
STATE="$XDG_CONFIG_HOME/loom/repos/$(printf '%s' "$REPO_REAL" | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
state_of()    { printf '%s\n' "$STATE/tasks/$1"; }
state_field() { sed -n "s/^$2=//p" "$STATE/tasks/$1" 2>/dev/null | head -1; }
git init -q .
# The trunk is `main` on purpose: the round-4 cases move `refs/heads/main` and
# `refs/remotes/origin/main` around to prove that neither is a security input
# any more. `git init -b main` needs git >= 2.28; this works everywhere.
git symbolic-ref HEAD refs/heads/main
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
# The operator's opencode config. Its existence is load-bearing: `loom` points
# every opencode run at THIS file and turns the project's own config off, so
# that a worktree copy an agent rewrote cannot repoint a provider's baseURL or
# swap a role prompt. No `model`/`provider` keys — `loom doctor` reads model IDs
# out of this file and there is nothing here to verify.
cat > .opencode/opencode.json << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "implementer": {"description": "stub", "prompt": "{file:./prompts/implementer.md}"},
    "reviewer":    {"description": "stub", "prompt": "{file:./prompts/reviewer.md}"},
    "scout":       {"description": "stub", "prompt": "{file:./prompts/scout.md}"},
    "architect":   {"description": "stub", "prompt": "{file:./prompts/architect.md}"}
  }
}
JSON

cat > .agents/zones.toml << 'TOML'
[fence]
reason = "test fence"
paths = ["core/**", "ios/**", "docs/audits/**"]

[fence_profiles.codex]
reason = "Anthropic + OpenAI may read and edit the custody core."
release = ["core/**", "docs/audits/**"]
providers = ["claude", "codex"]

[fence_profiles.audit]
reason = "Anthropic may read the audit corpus. Nobody gets the core."
release = ["docs/audits/**"]
providers = ["claude"]

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
for t in 0001-a 0002-b 0003-c 0004-e 0006-g 0007-h 0008-k 0009-l 0010-m 0013-p \
         0014-u 0016-v 0017-w 0018-x 0019-y 0020-y2 0023-ae \
         0024-ad 0025-ae2 0026-af 0027-ag 0028-ah 0029-ai 0030-aj \
         0031-al 0032-am 0034-an 0035-an2 0036-ao 0037-ap 0038-ap2 0039-aq \
         0041-ar2 \
         0043-at 0044-at2 0045-at3 0046-au 0047-au2 0048-av 0049-av2 \
         0050-loom 0051-ax 0052-ax2 0053-au3 \
         0054-az 0055-az2 0056-az3 0057-ba 0058-bb 0059-bc 0060-bd 0061-ba2; do mk_task "$t"; done
mk_task 0040-ar  codex
mk_task 0042-as  codex
mk_task 0005-f codex
mk_task 0011-n codex
# (o) a Fence-profile line that is NOT a declaration: it is inside a code fence,
# below the header block — exactly the shape `loom loop` appends to a task file
# when it pastes a reviewer's text back in.
{ echo "# 0012-o — test task"; echo ""; echo "Plan: none"; echo "Zone: assist"; echo "";
  echo "## Auto fix round 1 (loom loop — reviewer REVISE)"; echo "";
  echo '```'; echo "Fence-profile: codex"; echo '```'; } > .agents/tasks/0012-o.md
# (ac) a header block that opens with a BLANK LINE, and a declaration with a
# trailing ` # comment` — the exact shape the README documents.
{ echo ""; echo "# 0021-ac — test task"; echo ""; echo "Plan: none"; echo "Zone: assist";
  echo "Fence-profile: codex        # the flag on the command line is the consent";
} > .agents/tasks/0021-ac.md
# (ac) a NEAR MISS: a space before the colon. Not a declaration, and silence
# about it would read exactly like "honoured".
{ echo "# 0022-ad — test task"; echo ""; echo "Plan: none"; echo "Zone: assist";
  echo "Fence-profile : codex"; } > .agents/tasks/0022-ad.md
git add -A
git commit -qm init

echo "fence profiles"

# --- (a) no profile: everything fenced, guard blocks a fenced/hand path -----
out="$("$LOOM" new 0001-a 2>&1)"; rc=$?
want_eq   "(a) loom new without a profile succeeds"      "$rc" "0"
want_absent "(a) core/ is fenced out"                  "$WTU/0001-a/core/lib.rs"
want_absent "(a) ios/ is fenced out"                   "$WTU/0001-a/ios/App.swift"
want_absent "(a) docs/audits/ is fenced out"           "$WTU/0001-a/docs/audits/a.md"
want_file   "(a) the working surface is present"       "$WTU/0001-a/backend/main.go"

git checkout -q -b agent/guard-a
echo "// touched" >> core/lib.rs
git add core/lib.rs
out="$("$LOOM" guard 2>&1)"; rc=$?
want_eq  "(a) guard blocks a core/ commit with no profile" "$rc" "1"
want_in  "(a) guard names the path"                        "$out" "core/lib.rs"
git reset -q --hard
git checkout -q master 2>/dev/null || git checkout -q main

# --- (b) a profile with a chain that reaches a disallowed provider ---------
roots_listing() { # every task worktree under BOTH roots, one line
  # shellcheck disable=SC2012  # the worktree names here are task ids we chose
  { ls "$WTU" 2>/dev/null; ls "$WTP" 2>/dev/null; } | sort | tr '\n' ' '
}
before="$(roots_listing)"
out="$(LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0002-b --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed implementer chain"  "$rc" "1"
want_in  "(b) the message names the role"              "$out" "implementer chain"
want_in  "(b) the message names the model"             "$out" "deepseek/deepseek-v4-pro"
want_in  "(b) the message names the override"          "$out" "LOOM_MODELS_implementer"
want_absent "(b) no worktree was created"              "$WTP/0002-b"
want_eq  "(b) nothing else appeared under EITHER worktree root" "$(roots_listing)" "$before"
# ... and the same for the reviewer chain. A DIFFERENT task id on purpose: a
# second `loom new 0002-b` would die on "worktree already exists" if the first
# leg ever stopped dying, and the assertion would pass for the wrong reason.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="zai-coding-plan/glm-5.3" \
       "$LOOM" new 0007-h --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed reviewer chain"     "$rc" "1"
want_in  "(b) the message names the reviewer role"     "$out" "reviewer chain"
want_absent "(b) no worktree for the reviewer leg either" "$WTP/0007-h"

# --- (c) a profile with allowed chains: released paths are present ---------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq   "(c) loom new under the profile succeeds"      "$rc" "0"
want_file "(c) core/ is released into the worktree"    "$WTP/0003-c/core/lib.rs"
want_file "(c) docs/audits/ is released"               "$WTP/0003-c/docs/audits/a.md"
want_absent "(c) ios/ is still fenced"                 "$WTP/0003-c/ios/App.swift"
want_eq   "(c) the profile is in the operator record" \
          "$(state_field 0003-c profile)" "codex"
want_eq   "(c) ... which lives outside the repo and outside .git" \
          "$(state_of 0003-c)" "$STATE/tasks/0003-c"
want_eq   "(c) ... and nothing was written to branch config" \
          "$(git config branch.agent/0003-c.fenceprofile 2>/dev/null || true)" ""
want_eq   "(c) ... nor a diff base" \
          "$(git config branch.agent/0003-c.loombase 2>/dev/null || true)" ""
want_eq   "(c) the recorded base is the operator's HEAD at loom new" \
          "$(state_field 0003-c base)" "$(git rev-parse HEAD)"
out="$("$LOOM" ls 2>&1)"
want_in   "(c) loom ls shows the profile"                "$out" "fence-profile:codex"

# loom run re-applies AND verifies the fence, then commits: this is the path that
# proves fence_reconcile accepts a worktree holding released paths.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq  "(c) loom run under the profile reaches a green gate" "$rc" "0"
want_in  "(c) fence_verify passed (no 'STILL present')"      "$out" "gate green"
want_file "(c) the stub implementer ran"                     "$TMP/called-claude.log"
want_in  "(c) an implementer gets claude's edit permission"  "$(cat "$TMP/called-claude.log")" "acceptEdits"
want_in  "(c) the implementer prompt names the profile"      "$(cat "$TMP/called-claude.log")" "fence profile 'codex'"
want_absent "(c) no reviewer ran yet"                        "$TMP/called-codex.log"

# The reviewer must be told the released paths are in scope, and must stay
# read-only.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq  "(c) loom check under the profile succeeds"           "$rc" "0"
want_in  "(c) the reviewer is told the release is authorised" \
         "$(cat "$TMP/called-codex.log")" "are authorised for this task"
want_in  "(c) the reviewer sandbox stays read-only"          "$(cat "$TMP/called-codex.log")" "read-only"
case "$(cat "$TMP/called-codex.log")" in
  *workspace-write*|*--add-dir*) bad "(c) reviewer must never get a writable sandbox" ;;
  *)                             ok  "(c) reviewer never gets a writable sandbox" ;;
esac

# The same provider as an IMPLEMENTER gets the writable sandbox instead — with
# or without a profile: 0006-g has none.
mv "$TMP/called-codex.log" "$TMP/called-codex-reviewer.log"
out="$(LOOM_MODELS_implementer="codex-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0006-g 2>&1)"; rc=$?
want_eq "(c) a codex-sub implementer run succeeds"           "$rc" "0"
want_in "(c) an implementer gets codex's workspace-write"    "$(cat "$TMP/called-codex.log")" "workspace-write"
want_in "(c) ... and .agents made writable for the notes"    "$(cat "$TMP/called-codex.log")" "--add-dir"

# --- (c2) the flag is required on every command ---------------------------
out="$("$LOOM" run 0003-c 2>&1)"; rc=$?
want_eq "(c2) loom run without the flag dies"                  "$rc" "1"
want_in "(c2) ... naming the profile to pass"                "$out" "--fence-profile codex"
out="$("$LOOM" check 0003-c 2>&1)"; rc=$?
want_eq "(c2) loom check without the flag dies"                "$rc" "1"
out="$("$LOOM" land 0003-c 2>&1)"; rc=$?
want_eq "(c2) loom land without the flag dies"                 "$rc" "1"
out="$("$LOOM" rebase 0003-c 2>&1)"; rc=$?
want_eq "(c2) loom rebase without the flag dies"               "$rc" "1"
out="$("$LOOM" check 0003-c --fence-profile audit 2>&1)"; rc=$?
want_eq "(c2) a flag that contradicts the record dies"       "$rc" "1"
want_in "(c2) ... naming both names"                         "$out" "contradicts the record"
out="$("$LOOM" check 0001-a --fence-profile codex 2>&1)"; rc=$?
want_eq "(c2) a profile cannot be introduced into an unprofiled task" "$rc" "1"
want_in "(c2) ... and it says why"                           "$out" "cannot be introduced"

# --- (d) the guard under a profile, IN the agent's own worktree ------------
# The guard is a pre-commit hook: it runs where the agent commits.
GW="$WTP/0003-c"
echo "// touched again" >> "$GW/core/lib.rs"
git -C "$GW" add core/lib.rs
out="$(cd "$GW" && "$LOOM" guard 2>&1)"; rc=$?
want_eq "(d) guard ALLOWS a released core/ commit under the profile" "$rc" "0"
printf '\n# tampered\n' >> "$GW/.agents/zones.toml"
git -C "$GW" add .agents/zones.toml
out="$(cd "$GW" && "$LOOM" guard 2>&1)"; rc=$?
want_eq "(d) guard still blocks the control plane"        "$rc" "1"
want_in "(d) the block names zones.toml"                  "$out" ".agents/zones.toml"
want_in "(d) the block names what the profile released"   "$out" "releases only"
case "$out" in *core/lib.rs*) bad "(d) a released path must not be listed as a violation" ;;
               *)             ok  "(d) the released path is not listed as a violation" ;; esac
git -C "$GW" reset -q --hard
# A fenced path the profile did NOT release, created inside the worktree.
mkdir -p "$GW/ios"; echo "// swift" > "$GW/ios/App.swift"
git -C "$GW" add ios/App.swift
out="$(cd "$GW" && "$LOOM" guard 2>&1)"; rc=$?
want_eq "(d) guard blocks a fenced path the profile did NOT release" "$rc" "1"
git -C "$GW" reset -q --hard
rm -f "$GW/ios/App.swift"

# --- (e) unknown profile ---------------------------------------------------
out="$("$LOOM" new 0004-e --fence-profile nope 2>&1)"; rc=$?
want_eq "(e) an unknown profile dies"                     "$rc" "1"
want_in "(e) the message says which are defined"          "$out" "unknown fence profile 'nope'"
want_absent "(e) no worktree was created"                 "$WTU/0004-e"
want_absent "(e) ... under either root"                   "$WTP/0004-e"

# --- (f) the task file declares, the FLAG consents -------------------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0005-f --fence-profile codex 2>&1)"; rc=$?
want_eq   "(f) declaration + matching flag opts in"       "$rc" "0"
want_eq   "(f) it is in the operator record"              \
          "$(state_field 0005-f profile)" "codex"
want_file "(f) the released path is present"              "$WTP/0005-f/core/lib.rs"
want_absent "(f) the unreleased fenced path is not"       "$WTP/0005-f/ios/App.swift"
# The same task, with a disallowed chain, must still die.
out="$(LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" "$LOOM" check 0005-f --fence-profile codex 2>&1)"; rc=$?
want_eq "(f) a later command re-checks the chain"         "$rc" "1"

# --- (g) a task file that gains a profile late is inert --------------------
# The file states intent; only `loom new` reads it, and only with the flag. A
# line added afterwards must neither release anything nor be honoured later.
printf 'Fence-profile: codex\n' >> .agents/tasks/0001-a.md
# One commit, because a branch with nothing past its branch point is refused on
# its own terms now — see (an). This case is about the task file, not that.
echo "benign" > "$WTU/0001-a/backend/g.txt"
git -C "$WTU/0001-a" add backend/g.txt
git -C "$WTU/0001-a" commit -qm "benign work"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0001-a 2>&1)"; rc=$?
want_eq "(g) a task file edited after loom new changes nothing" "$rc" "0"
want_absent "(g) and releases nothing into the worktree"      "$WTU/0001-a/core/lib.rs"
git checkout -q -- .agents/tasks/0001-a.md

# --- (h) fail-closed parsing ----------------------------------------------
cp .agents/zones.toml "$TMP/zones.good"
restore_zones() { cp "$TMP/zones.good" .agents/zones.toml; }
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.bogus]
release = ["backend/**"]
providers = ["claude"]
TOML
out="$("$LOOM" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a release outside [fence] is refused"        "$rc" "1"
want_in "(h) ... with a reason"                           "$out" "not one of [fence].paths"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.bogus2]
release = ["core/**"]
TOML
out="$("$LOOM" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a profile without providers is refused"      "$rc" "1"
restore_zones

# --- (i) an inherited LOOM_FENCE_PROFILE must not widen anything ------------
out="$(LOOM_FENCE_PROFILE=codex "$LOOM" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(i) the environment cannot activate a profile"   "$rc" "0"
want_in "(i) core/ is still reported as fenced"           "$out" "fenced"

# --- (k) the record is REMOVED: rule 3 is ABSOLUTE, there is no escape -----
# There used to be one: a worktree holding exactly what the flag releases was
# read as corroboration, the record was restored and the command ran. A
# worktree is a directory the agent can write (`git sparse-checkout disable`),
# so that corroborated nothing. Restoring a lost record is now an operator act.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq   "(k) setup: a profiled worktree exists"         "$rc" "0"
want_file "(k) setup: it holds the released path"         "$WTP/0008-k/core/lib.rs"
rm -f "$(state_of 0008-k)"                       # the record is lost
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0008-k 2>&1)"; rc=$?
want_eq "(k) without the flag, a released tree is refused"   "$rc" "1"
want_in "(k) ... naming the paths it found on disk"          "$out" "core/lib.rs"
want_not_in "(k) ... and no reviewer was launched"           "$out" "running on"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq "(k) with the flag and no record it STILL dies"       "$rc" "1"
want_in "(k) ... the tree is not evidence"                    "$out" "is not evidence"
want_not_in "(k) ... nothing is restored on the operator's behalf" "$out" "Restoring it"
want_not_in "(k) ... and no reviewer was launched"            "$out" "running on"
want_absent "(k) ... the record is still absent"              "$(state_of 0008-k)"
want_in "(k) ... and it says to re-create the task"           "$out" \
        "loom drop 0008-k && loom new 0008-k --fence-profile codex"
want_not_in "(k) ... never by hand-editing a record"          "$out" "git config"

# --- (l) the record is SWAPPED to another legitimate profile --------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0009-l --fence-profile codex 2>&1)"; rc=$?
want_eq "(l) setup: a codex worktree exists"              "$rc" "0"
sedi 's/^profile=.*/profile=audit/' "$(state_of 0009-l)"       # the record is swapped
out="$(LOOM_MODELS_reviewer="claude-sub" "$LOOM" check 0009-l --fence-profile audit 2>&1)"; rc=$?
want_eq "(l) the swapped profile does not release what is on disk" "$rc" "1"
want_in "(l) ... and it names the path"                   "$out" "core/lib.rs"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0009-l --fence-profile codex 2>&1)"; rc=$?
want_eq "(l) the real profile now contradicts the swapped record" "$rc" "1"
want_in "(l) ... and says so"                             "$out" "contradicts the record"

# --- (m) an agent writes a branch record from inside its worktree --------
# Branch config is shared .git state, so an agent can write it. It is no longer
# read, in either direction: it cannot widen a task's fence, and it cannot
# refuse an honest command either.
out="$("$LOOM" new 0010-m 2>&1)"; rc=$?
want_eq   "(m) setup: an UNPROFILED worktree"             "$rc" "0"
want_absent "(m) setup: core/ is fenced out of it"        "$WTU/0010-m/core/lib.rs"
echo "benign" > "$WTU/0010-m/backend/m.txt"
git -C "$WTU/0010-m" add backend/m.txt
git -C "$WTU/0010-m" commit -qm "benign work"
git -C "$WTU/0010-m" config branch.agent/0010-m.fenceprofile codex   # the agent forges it
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0010-m 2>&1)"; rc=$?
want_eq "(m) a forged branch record is not read at all"        "$rc" "0"
want_not_in "(m) ... so it cannot demand a flag"               "$out" "--fence-profile codex"
want_absent "(m) ... and nothing was released into the worktree" "$WTU/0010-m/core/lib.rs"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0010-m --fence-profile codex 2>&1)"; rc=$?
want_eq "(m) and the flag cannot introduce a profile either"   "$rc" "1"
want_in "(m) ... no record, no run"                            "$out" "has no fence-profile record"
want_absent "(m) nothing was released into the worktree"       "$WTU/0010-m/core/lib.rs"
want_absent "(m) and no profiled worktree was built for it"    "$WTP/0010-m"

# --- (n) a task-file declaration alone is not consent ---------------------
out="$("$LOOM" new 0011-n 2>&1)"; rc=$?
want_eq "(n) a 'Fence-profile:' line without the flag dies"    "$rc" "1"
want_in "(n) ... asking for confirmation on the command line"  "$out" "loom new 0011-n --fence-profile codex"
want_absent "(n) and no worktree was created"                  "$WTU/0011-n"
want_absent "(n) ... under either root"                        "$WTP/0011-n"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0011-n --fence-profile codex 2>&1)"; rc=$?
want_eq   "(n) the same line WITH the matching flag is fine"   "$rc" "0"
want_file "(n) ... and releases the path"                      "$WTP/0011-n/core/lib.rs"

# --- (o) a Fence-profile line inside a code fence is not a declaration ----
out="$("$LOOM" new 0012-o 2>&1)"; rc=$?
want_eq   "(o) a fenced-off code block is ignored"        "$rc" "0"
want_absent "(o) ... nothing was released"                "$WTU/0012-o/core/lib.rs"
want_eq   "(o) ... and nothing was recorded"              \
          "$(state_field 0012-o profile)" ""

# --- (p) .agents symlinked out of the worktree ----------------------------
out="$("$LOOM" new 0013-p 2>&1)"; rc=$?
want_eq "(p) setup: a plain worktree"                     "$rc" "0"
mkdir -p "$TMP/outside-agents/reviews"
cp "$REPO/.agents/gate.sh" "$TMP/outside-agents/gate.sh"
mv "$WTU/0013-p/.agents" "$WTU/0013-p/.agents-real"
ln -s "$TMP/outside-agents" "$WTU/0013-p/.agents"
codex_before="$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="codex-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0013-p 2>&1)"; rc=$?
want_eq "(p) a .agents that resolves outside the worktree dies" "$rc" "1"
want_in "(p) ... naming the path it resolved to"          "$out" "$TMP/outside-agents"
want_eq "(p) ... before launching the model"              \
        "$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)" "$codex_before"

# --- (q) provider entries are validated at parse time ---------------------
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.star]
release = ["core/**"]
providers = ["*"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(q) providers = [\"*\"] is refused"              "$rc" "1"
want_in "(q) ... naming the rule"                         "$out" "no glob"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.twoinone]
release = ["core/**"]
providers = ["claude deepseek"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(q) a whitespace-joined provider entry is refused" "$rc" "1"
want_in "(q) ... naming the rule"                         "$out" "no spaces"
restore_zones

# --- (r) a release another fence pattern still covers ---------------------
cat > .agents/zones.toml << 'TOML'
[fence]
reason = "overlapping test fence"
paths = ["docs/**", "docs/audits/**"]

[fence_profiles.narrow]
release = ["docs/audits/**"]
providers = ["claude"]

[hand]
paths = ["docs/**"]

[assist]
paths = ["backend/**"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(r) a release still covered by [fence] is refused" "$rc" "1"
want_in "(r) ... naming the pattern that covers it"        "$out" "'docs/**' still covers it"
restore_zones

# --- (s) an empty --fence-profile value -----------------------------------
out="$("$LOOM" new 0004-e --fence-profile= 2>&1)"; rc=$?
want_eq "(s) --fence-profile= dies"                       "$rc" "1"
want_in "(s) ... naming the missing value"                "$out" "empty value"
want_absent "(s) and creates nothing"                     "$WTU/0004-e"
want_absent "(s) ... under either root"                   "$WTP/0004-e"
out="$("$LOOM" check 0003-c --fence-profile= 2>&1)"; rc=$?
want_eq "(s) ... on every command"                        "$rc" "1"
out="$("$LOOM" check 0003-c --fence-profile 2>&1)"; rc=$?
want_eq "(s) a bare --fence-profile dies too"             "$rc" "1"

# ==========================================================================
# ROUND-2 fixes. Every case below FAILS against the pre-fix bin/loom.
# ==========================================================================

# --- (u) an existing branch is refused, never deleted ---------------------
# `loom new` set NEW_BR before `git worktree add -b`, so an add that failed
# because agent/<task> already existed ran the EXIT trap on the PRE-EXISTING
# branch — the state `loom drop --keep-branch` leaves on purpose — and silenced
# the deletion. The branch and its commits must survive the refusal.
sha_of() { git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || echo "GONE"; }
out="$("$LOOM" new 0014-u 2>&1)"; rc=$?
want_eq "(u) setup: a plain worktree"                     "$rc" "0"
echo "work" > "$WTU/0014-u/backend/u.txt"
git -C "$WTU/0014-u" add backend/u.txt
git -C "$WTU/0014-u" commit -qm "work that only exists on this branch"
u_sha="$(sha_of agent/0014-u)"
out="$("$LOOM" drop 0014-u --keep-branch 2>&1)"; rc=$?
want_eq "(u) setup: worktree dropped, branch kept"        "$rc" "0"
out="$("$LOOM" new 0014-u 2>&1)"; rc=$?
want_eq "(u) loom new refuses an existing branch"           "$rc" "1"
want_in "(u) ... naming it"                               "$out" "branch agent/0014-u already exists"
want_in "(u) ... and mentioning --keep-branch"            "$out" "--keep-branch"
want_eq "(u) ... the branch still points at its commit"   "$(sha_of agent/0014-u)" "$u_sha"
want_absent "(u) ... and no worktree was created"         "$WTU/0014-u"
# the same through `loom run`, which reaches cmd_new for a missing worktree
out="$("$LOOM" run 0014-u 2>&1)"; rc=$?
want_eq "(u) loom run refuses it too"                       "$rc" "1"
want_eq "(u) ... and the branch survives that as well"    "$(sha_of agent/0014-u)" "$u_sha"
git branch -D agent/0014-u > /dev/null 2>&1 || true

# --- (v) the branch's COMMITS are judged, not just what is on disk --------
# Materialise a fenced path, commit it, put the sparse rules back: the tree
# looks clean, and the diff, the patch file and any merge still carry it.
out="$("$LOOM" new 0016-v 2>&1)"; rc=$?
want_eq "(v) setup: an unprofiled worktree"               "$rc" "0"
VW="$WTU/0016-v"
git -C "$VW" sparse-checkout disable                       # the agent widens it
echo "// smuggled" >> "$VW/core/lib.rs"
git -C "$VW" add core/lib.rs
git -C "$VW" commit -qm "touch a fenced path"
git -C "$VW" sparse-checkout init --no-cone                # ... and re-fences
git -C "$VW" sparse-checkout set '/*' '!core/**' '!ios/**' '!docs/audits/**'
want_absent "(v) setup: the tree no longer shows the fenced path" "$VW/core/lib.rs"
rm -f "$VW/.agents/reviews/0016-v.patch"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0016-v 2>&1)"; rc=$?
want_eq "(v) loom check dies on a fenced path in the history"  "$rc" "1"
want_in "(v) ... naming the path"                            "$out" "core/lib.rs"
want_in "(v) ... and saying the commits carry it"            "$out" "commits touch fenced paths"
want_absent "(v) ... and NO patch was written"               "$VW/.agents/reviews/0016-v.patch"
want_not_in "(v) ... and no reviewer was launched"           "$out" "running on"
out="$(EDITOR=true "$LOOM" diff 0016-v 2>&1)"; rc=$?
want_eq "(v) loom diff dies on it too"                         "$rc" "1"
want_in "(v) ... for the same reason"                        "$out" "commits touch fenced paths"

# --- (w) the roots are separate, and opencode is granted neither of them --
case "$WTP" in
  "$WTU"/*) bad "(w) the profiled root must NOT be under the unprofiled root" ;;
  *)        ok  "(w) the profiled root is not under the unprofiled root" ;;
esac
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" \
       LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0017-w 2>&1)"; rc=$?
want_eq   "(w) an opencode implementer runs"              "$rc" "0"
want_file "(w) ... and the stub recorded its grant"       "$TMP/called-opencode.log"
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in     "(w) the grant is the role's OWN worktree"    "$oc" "$WTU/0017-w/**"
want_not_in "(w) ... not the whole worktree root"         "$oc" "\"$WTU/*\":\"allow\""
want_not_in "(w) ... and never the profiled root"         "$oc" "$WTP"
# (ak) opencode resolves its project config from the cwd — <worktree>/.opencode/
# opencode.json, which the agent in that worktree can rewrite, and which carries
# provider.<name>.options.baseURL (the provider identity a profile is built on)
# and the role prompts. It must be handed the OPERATOR's copy, and told not to
# read the project's own: OPENCODE_CONFIG alone is merged BEFORE the project
# files, so the worktree's copy would still win key by key.
want_in "(ak) opencode is pointed at the operator's config" \
        "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_in "(ak) ... and the worktree's own config is off"    \
        "$oc" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
# A trailing slash in $LOOM_WORKTREES must not turn the profiled root into a
# CHILD of the unprofiled one ("/x/wt/" + "-profiled" = "/x/wt/-profiled").
out="$(LOOM_WORKTREES="$TMP/wt3/" LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$LOOM" new 0023-ae --fence-profile codex 2>&1)"; rc=$?
want_eq   "(w) a trailing slash in LOOM_WORKTREES is stripped"  "$rc" "0"
want_file "(w) ... so the profiled root is a sibling"           "$TMP/wt3-profiled/0023-ae/core/lib.rs"
want_absent "(w) ... and never a child of the unprofiled root"  "$TMP/wt3/-profiled"
out="$(LOOM_WORKTREES="$TMP/wt3/" "$LOOM" drop 0023-ae 2>&1)"; rc=$?
want_eq   "(w) ... and loom drop finds it there"                  "$rc" "0"
want_absent "(w) ... and removed it"                            "$TMP/wt3-profiled/0023-ae"

rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
sc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in     "(w) the scout grant is its own mirror"       "$sc" "$WTU/_scout/**"
want_not_in "(w) ... not the whole worktree root"         "$sc" "\"$WTU/*\":\"allow\""
want_not_in "(w) ... and never the profiled root"         "$sc" "$WTP"

# --- (x) every fallback attempt re-reconciles ----------------------------
# Attempt 1 relaxes the sparse checkout and returns 429; attempt 2 must see
# the widened tree, not the tree as it was before the loop started.
out="$(LOOM_MODELS_implementer="claude-sub codex-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0018-x --fence-profile codex 2>&1)"; rc=$?
want_eq "(x) setup: a profiled worktree"                  "$rc" "0"
codex_before="$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)"
out="$(LOOM_TEST_RELAX_SPARSE=1 LOOM_MAX_ATTEMPTS=1 \
       LOOM_MODELS_implementer="claude-sub codex-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0018-x --fence-profile codex 2>&1)"; rc=$?
want_eq "(x) attempt 1 widened the tree, so attempt 2 is refused" "$rc" "1"
want_in "(x) ... the first model did fall back"           "$out" "looks rate-limited"
want_in "(x) ... naming the path the profile does not release" "$out" "ios/App.swift"
want_in "(x) ... as a profile mismatch"                   "$out" "does not release"
want_eq "(x) ... and the SECOND model never launched"     \
        "$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)" "$codex_before"

# --- (y) loom land inspects the commits it is about to publish -------------
out="$("$LOOM" new 0019-y 2>&1)"; rc=$?
want_eq "(y) setup: an unprofiled worktree"               "$rc" "0"
YW="$WTU/0019-y"
git -C "$YW" sparse-checkout disable
echo "// smuggled" >> "$YW/core/lib.rs"
git -C "$YW" add core/lib.rs
git -C "$YW" commit -qm "touch a fenced path"
git -C "$YW" sparse-checkout init --no-cone
git -C "$YW" sparse-checkout set '/*' '!core/**' '!ios/**' '!docs/audits/**'
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0019-y 2>&1)"; rc=$?
want_eq "(y) land refuses a branch whose commits touch a fenced path" "$rc" "1"
want_in "(y) ... naming the path"                         "$out" "core/lib.rs"
want_eq "(y) ... and nothing was merged"                  "$(git rev-parse HEAD)" "$head_before"
want_file "(y) ... and the worktree is still there"       "$YW/.agents/gate.sh"
# ... and a [hand] path is refused even WITH a profile, when that profile does
# not release it. 'audit' releases docs/audits/** only, to claude only.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="claude-sub" \
       "$LOOM" new 0020-y2 --fence-profile audit 2>&1)"; rc=$?
want_eq "(y) setup: a worktree under the 'audit' profile" "$rc" "0"
Y2W="$WTP/0020-y2"
printf '\n# touched\n' >> "$Y2W/.agents/gate.sh"
git -C "$Y2W" add .agents/gate.sh
git -C "$Y2W" commit -q --no-verify -m "touch a hand path the profile does not release"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0020-y2 --fence-profile audit 2>&1)"; rc=$?
want_eq "(y) land refuses a [hand] path even under a profile" "$rc" "1"
want_in "(y) ... naming the path"                         "$out" ".agents/gate.sh"
want_in "(y) ... and what the profile actually releases"   "$out" "releases only"
want_eq "(y) ... and nothing was merged"                  "$(git rev-parse HEAD)" "$head_before"

# --- (z) the overlap check, downward ------------------------------------
cat > .agents/zones.toml << 'TOML'
[fence]
reason = "subset test fence"
paths = ["core/**", "core/wallet-sdk/**"]

[fence_profiles.wide]
release = ["core/**"]
providers = ["claude"]

[hand]
paths = ["core/**"]

[assist]
paths = ["backend/**"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(z) a release that swallows a still-fenced pattern is refused" "$rc" "1"
want_in "(z) ... naming the pattern that stays fenced"    "$out" "core/wallet-sdk/**"
want_in "(z) ... and why"                                 "$out" "never reach the worktree"
restore_zones

# --- (aa) the escape is gone on loom run too, not only loom check ------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq "(aa) with the record gone, loom run dies as well"  "$rc" "1"
want_in "(aa) ... telling the operator to start clean"    "$out" \
        "loom drop 0008-k && loom new 0008-k --fence-profile codex"
want_absent "(aa) ... and loom wrote no record on its own"  "$(state_of 0008-k)"

# --- (ab) a providers entry that can never be a provider_of() output -----
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.capital]
release = ["core/**"]
providers = ["Claude"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(ab) providers = [\"Claude\"] is refused at parse" "$rc" "1"
want_in "(ab) ... as not a provider the harness can produce" "$out" "not a provider"
want_in "(ab) ... with the lower-case suggestion"          "$out" "did you mean 'claude'"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.modeltoken]
release = ["core/**"]
providers = ["claude-sub"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(ab) providers = [\"claude-sub\"] is refused too"  "$rc" "1"
want_in "(ab) ... named as a model token, not a provider"   "$out" "is a MODEL token"
restore_zones

# --- (ac) the task-file header block -------------------------------------
out="$("$LOOM" new 0021-ac 2>&1)"; rc=$?
want_eq "(ac) a declaration under a leading blank line is honoured" "$rc" "1"
want_in "(ac) ... so the flag is demanded"                "$out" "loom new 0021-ac --fence-profile codex"
want_absent "(ac) ... and nothing was created"            "$WTU/0021-ac"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0021-ac --fence-profile codex 2>&1)"; rc=$?
want_eq   "(ac) ... and a trailing '# comment' is not part of the name" "$rc" "0"
want_file "(ac) ... so the release took effect"           "$WTP/0021-ac/core/lib.rs"
out="$("$LOOM" new 0022-ad 2>&1)"; rc=$?
want_eq "(ac) a near-miss key does not opt a task in"     "$rc" "0"
want_in "(ac) ... but loom new says it was not honoured"    "$out" "not honoured"
want_in "(ac) ... quoting the line it found"              "$out" "Fence-profile : codex"
want_absent "(ac) ... and it released nothing"            "$WTU/0022-ad/core/lib.rs"


# ==========================================================================
# ROUND-3 fixes. Every case below FAILS against the pre-fix bin/loom (69a297a).
# ==========================================================================

# --- (ad) the diff base is not the agent's to choose ----------------------
# branch.<br>.loombase lived in the SHARED .git/config, so anything running in
# the worktree could rewrite it. Set to the branch's own HEAD it made `git diff
# <base> HEAD` empty, and every history check then answered "this branch
# touches nothing" — `loom land` merged a fenced commit, `loom check` handed the
# patch to a reviewer. The base is now the OPERATOR RECORD, a file outside the
# repo; the branch config below is not read at all, in either direction.
taint() { # taint <task> <worktree>   materialise a fenced path, commit, re-fence
  git -C "$2" sparse-checkout disable
  echo "// smuggled by $1" >> "$2/core/lib.rs"
  git -C "$2" add core/lib.rs
  git -C "$2" commit -qm "touch a fenced path"
  git -C "$2" sparse-checkout init --no-cone
  git -C "$2" sparse-checkout set '/*' '!core/**' '!ios/**' '!docs/audits/**'
}
out="$("$LOOM" new 0024-ad 2>&1)"; rc=$?
want_eq "(ad) setup: an unprofiled worktree"              "$rc" "0"
ADW="$WTU/0024-ad"
taint 0024-ad "$ADW"
git -C "$ADW" config "branch.agent/0024-ad.loombase" "$(git -C "$ADW" rev-parse HEAD)"  # the agent
rm -f "$ADW/.agents/reviews/0024-ad.patch"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0024-ad 2>&1)"; rc=$?
want_eq "(ad) a loombase at HEAD does not empty the check" "$rc" "1"
want_eq "(ad) ... and the recorded base is untouched by it" \
        "$(state_field 0024-ad base)" "$(git rev-parse "agent/0024-ad~1")"
want_in "(ad) ... the fenced path is still named"         "$out" "core/lib.rs"
want_absent "(ad) ... and NO patch was written"           "$ADW/.agents/reviews/0024-ad.patch"
want_not_in "(ad) ... and no reviewer was launched"       "$out" "running on"
out="$(EDITOR=true "$LOOM" diff 0024-ad 2>&1)"; rc=$?
want_eq "(ad) loom diff dies on it too"                     "$rc" "1"
want_in "(ad) ... for the same reason"                    "$out" "commits touch fenced paths"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0024-ad 2>&1)"; rc=$?
want_eq "(ad) loom land refuses the branch"                 "$rc" "1"
want_in "(ad) ... naming the fenced path"                 "$out" "core/lib.rs"
want_eq "(ad) ... and nothing was merged"                 "$(git rev-parse HEAD)" "$head_before"

# --- (ae2) a loombase that does not resolve is a refusal, not an empty diff -
# It used to be the cheapest attack in the file: `git config
# branch.<br>.loombase 0000…` and history_paths returned 0 with no paths at
# all, which reads downstream as "nothing fenced in this history". The setting
# is inert now — the base comes from the operator record — and the fenced path
# is still caught, which is what this case asserts.
out="$("$LOOM" new 0025-ae2 2>&1)"; rc=$?
want_eq "(ae) setup: an unprofiled worktree"              "$rc" "0"
AEW="$WTU/0025-ae2"
taint 0025-ae2 "$AEW"
git config "branch.agent/0025-ae2.loombase" "0000000000000000000000000000000000000000"
rm -f "$AEW/.agents/reviews/0025-ae2.patch"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0025-ae2 2>&1)"; rc=$?
want_eq "(ae) an unresolvable loombase still dies"        "$rc" "1"
want_in "(ae) ... naming the fenced path, not a git error" "$out" "core/lib.rs"
want_absent "(ae) ... and NO patch was written"           "$AEW/.agents/reviews/0025-ae2.patch"
want_not_in "(ae) ... and no reviewer was launched"       "$out" "running on"

# --- (af) an agent cannot shrink the review diff --------------------------
# The review patch used to be cut from the loombase (branch config) with a
# clamp on top. There is no second base any more: the patch is cut from the
# recorded base, so a `git config` that once hid a commit from the reviewer now
# does nothing at all — and there is no clamp warning to read either.
out="$("$LOOM" new 0026-af 2>&1)"; rc=$?
want_eq "(af) setup: an unprofiled worktree"              "$rc" "0"
AFW="$WTU/0026-af"
echo "hidden" > "$AFW/backend/af-hidden.txt"
git -C "$AFW" add backend/af-hidden.txt
git -C "$AFW" commit -qm "a commit the agent would rather the reviewer did not see"
af_hide="$(git -C "$AFW" rev-parse HEAD)"
echo "visible" > "$AFW/backend/af-visible.txt"
git -C "$AFW" add backend/af-visible.txt
git -C "$AFW" commit -qm "the commit it wants reviewed"
git -C "$AFW" config "branch.agent/0026-af.loombase" "$af_hide"          # the agent
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0026-af 2>&1)"; rc=$?
want_eq "(af) the check still succeeds"                   "$rc" "0"
want_not_in "(af) ... with no clamp to warn about"        "$out" "ahead of the"
want_not_in "(af) ... because branch config is not read"  "$out" "loombase"
patch_af="$(cat "$AFW/.agents/reviews/0026-af.patch" 2>/dev/null || true)"
want_in "(af) the review diff shows the hidden commit"    "$patch_af" "af-hidden.txt"
want_in "(af) ... and the one it wanted reviewed"         "$patch_af" "af-visible.txt"

# --- (ag) a symlink standing where the profiled root should be ------------
# "$WT_ROOT-profiled" is a sibling of the unprofiled root BY NAME. An agent
# that plants a symlink there points every released path back INSIDE the
# directory unprofiled runs are given.
mkdir -p "$TMP/wt-ag/T5"
ln -s "$TMP/wt-ag/T5" "$TMP/wt-ag-profiled"
out="$(LOOM_WORKTREES="$TMP/wt-ag" LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$LOOM" new 0027-ag --fence-profile codex 2>&1)"; rc=$?
want_eq "(ag) a symlinked worktree root is refused"       "$rc" "1"
want_in "(ag) ... naming what it really resolves to"      "$out" "$TMP/wt-ag/T5"
want_absent "(ag) ... and nothing was created under it"   "$TMP/wt-ag/T5/0027-ag"
want_eq "(ag) ... and no branch was created"              "$(sha_of agent/0027-ag)" "GONE"
rm -f "$TMP/wt-ag-profiled"

# --- (ah) LOOM_WORKTREES=/x/wt/. must not produce /x/wt/.-profiled --------
out="$(LOOM_WORKTREES="$TMP/wt5/." LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$LOOM" new 0028-ah --fence-profile codex 2>&1)"; rc=$?
want_eq   "(ah) a trailing '/.' is normalised away"       "$rc" "0"
want_file "(ah) ... so the profiled root is a sibling"    "$TMP/wt5-profiled/0028-ah/core/lib.rs"
want_absent "(ah) ... never a child of the unprofiled root" "$TMP/wt5/.-profiled"
want_absent "(ah) ... under any spelling of it"           "$TMP/wt5/-profiled"
out="$(LOOM_WORKTREES="$TMP/wt5/." "$LOOM" drop 0028-ah 2>&1)"; rc=$?
want_eq   "(ah) ... and loom drop finds it there"           "$rc" "0"

# --- (ai) .agents/loom.env is in the tree the agent writes ----------------
# It is sourced as shell (KNOWN-GAPS 3), so it cannot be trusted with either
# of the two things that decide what a check looks at: where released content
# lands, and which commit a history is measured from.
printf 'WT_ROOT_PROFILED=%s\n' "$TMP/wt6/nested" > .agents/loom.env
out="$(LOOM_WORKTREES="$TMP/wt6" LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$LOOM" new 0029-ai --fence-profile codex 2>&1)"; rc=$?
rm -f .agents/loom.env
want_eq "(ai) loom.env cannot redirect the profiled root" "$rc" "1"
want_in "(ai) ... because that root is DERIVED"           "$out" "DERIVED"
want_absent "(ai) ... and nothing landed under the unprofiled root" "$TMP/wt6/nested"
want_eq "(ai) ... and no branch was created"              "$(sha_of agent/0029-ai)" "GONE"
# The base a history check is measured from is no longer a ref at all — it is
# the operator record — so loom.env has nothing to point at. Asserted the only
# way that fact can be asserted from here: a loom.env naming the tainted tip
# changes nothing, and the fenced path is still caught.
printf 'LOOM_BASE_REF=%s\n' "$(git -C "$WTU/0016-v" rev-parse HEAD)" > .agents/loom.env
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0016-v 2>&1)"; rc=$?
rm -f .agents/loom.env
want_eq "(ai) loom.env cannot move the base"              "$rc" "1"
want_in "(ai) ... and the fenced path is still caught"    "$out" "core/lib.rs"

# --- (aj) an UNTRACKED file under a fenced path --------------------------
# `git ls-files` answers the index, and `git show HEAD:core/lib.rs >
# core/copy.rs` never touches it. The reconciler asks the disk now.
out="$("$LOOM" new 0030-aj 2>&1)"; rc=$?
want_eq "(aj) setup: an unprofiled worktree"              "$rc" "0"
AJW="$WTU/0030-aj"
want_absent "(aj) setup: core/ is fenced out of it"       "$AJW/core"
mkdir -p "$AJW/core"
git -C "$AJW" show HEAD:core/lib.rs > "$AJW/core/copy.rs"   # untracked, fenced path
claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0030-aj 2>&1)"; rc=$?
want_eq "(aj) an untracked file under a fenced path stops the run" "$rc" "1"
# Asserted as the RECONCILE's refusal, not just as the path appearing: without
# the walk the run got as far as `git add -A`, which fails on a path outside
# the sparse-checkout definition and prints the same name for another reason.
want_in "(aj) ... as a fenced path that is present"       "$out" "fenced paths are present in"
want_in "(aj) ... naming it"                              "$out" "core/copy.rs"
want_eq "(aj) ... before the model was launched"          \
        "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$claude_before"
rm -rf "$AJW/core"

# ==========================================================================
# ROUND-4 fixes. Every case below FAILS against the pre-fix bin/loom (74118da).
#
# One theme: a linked worktree shares `.git` with the main checkout, so branch
# CONFIG and REFS are both writable from inside an agent's worktree — and the
# worktree's own HEAD is not the branch. None of the three can carry a security
# input, so the base and the profile now live in an OPERATOR RECORD outside
# every repo, and the history endpoint is the branch ref read in $ROOT.
# ==========================================================================

# --- (al) a detached worktree is not a state loom judges --------------------
# `git checkout --detach HEAD~1` after a fenced commit: the tree, and every
# check measured from the tree's HEAD, stop seeing the commit the BRANCH still
# carries into the merge and into the review patch.
out="$("$LOOM" new 0031-al 2>&1)"; rc=$?
want_eq "(al) setup: an unprofiled worktree"              "$rc" "0"
ALW="$WTU/0031-al"
echo "benign" > "$ALW/backend/al.txt"
git -C "$ALW" add backend/al.txt
git -C "$ALW" commit -qm "benign work"
taint 0031-al "$ALW"                       # ... and a fenced commit on top
git -C "$ALW" checkout -q --detach HEAD~1  # the agent steps off the branch
rm -f "$ALW/.agents/reviews/0031-al.patch"
head_before="$(git rev-parse HEAD)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0031-al 2>&1)"; rc=$?
want_eq "(al) loom check refuses a detached worktree"       "$rc" "1"
want_in "(al) ... naming the branch it is not on"         "$out" "is not on refs/heads/agent/0031-al"
want_absent "(al) ... and NO patch was written"           "$ALW/.agents/reviews/0031-al.patch"
want_not_in "(al) ... and no reviewer was launched"       "$out" "running on"
out="$(EDITOR=true "$LOOM" diff 0031-al 2>&1)"; rc=$?
want_eq "(al) loom diff refuses it too"                     "$rc" "1"
want_in "(al) ... for the same reason"                    "$out" "is not on refs/heads/agent/0031-al"
out="$("$LOOM" land 0031-al 2>&1)"; rc=$?
want_eq "(al) loom land refuses it too"                     "$rc" "1"
want_in "(al) ... for the same reason"                    "$out" "is not on refs/heads/agent/0031-al"
want_eq "(al) ... and nothing was merged"                 "$(git rev-parse HEAD)" "$head_before"

# --- (am) refs are writable from a worktree, so they are not the base -----
# `.git/refs` is shared with the main checkout: one `git update-ref` inside the
# agent's worktree moved origin/main (or main) to the branch's own tip, and a
# base computed as merge-base(<trunk>, <branch>) collapsed to that tip.
out="$("$LOOM" new 0032-am 2>&1)"; rc=$?
want_eq "(am) setup: an unprofiled worktree"              "$rc" "0"
AMW="$WTU/0032-am"
taint 0032-am "$AMW"                                     # the fenced commit X
am_x="$(git -C "$AMW" rev-parse HEAD)"
echo "benign" > "$AMW/backend/am.txt"
git -C "$AMW" add backend/am.txt
git -C "$AMW" commit -qm "benign work on top"            # ... and a benign Y
rm -f "$AMW/.agents/reviews/0032-am.patch"
git -C "$AMW" update-ref refs/remotes/origin/main "$(git -C "$AMW" rev-parse HEAD)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0032-am 2>&1)"; rc=$?
want_eq "(am) a moved origin/main does not empty the check"  "$rc" "1"
want_in "(am) ... the fenced path is still named"            "$out" "core/lib.rs"
want_absent "(am) ... and NO patch was written"              "$AMW/.agents/reviews/0032-am.patch"
want_not_in "(am) ... and no reviewer was launched"          "$out" "running on"
# the PARTIAL move: the ref lands on the fenced commit, benign work on top
git -C "$AMW" update-ref refs/remotes/origin/main "$am_x"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0032-am 2>&1)"; rc=$?
want_eq "(am) nor does a partial move onto the fenced commit" "$rc" "1"
want_in "(am) ... which is still named"                       "$out" "core/lib.rs"
# ... and the same through refs/heads/main, restored immediately after
am_main_before="$(git rev-parse refs/heads/main)"
git -C "$AMW" update-ref refs/heads/main "$(git -C "$AMW" rev-parse HEAD)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0032-am 2>&1)"; rc=$?
git update-ref refs/heads/main "$am_main_before"
want_eq "(am) a moved refs/heads/main does not either"        "$rc" "1"
want_in "(am) ... and the fenced path is named"               "$out" "core/lib.rs"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0032-am 2>&1)"; rc=$?
want_eq "(am) loom land refuses the branch"                     "$rc" "1"
want_eq "(am) ... and nothing was merged"                     "$(git rev-parse HEAD)" "$head_before"
git update-ref -d refs/remotes/origin/main

# --- (an) an empty range is not a review ---------------------------------
out="$("$LOOM" new 0034-an 2>&1)"; rc=$?
want_eq "(an) setup: a fresh worktree with no commits"    "$rc" "0"
rm -f "$WTU/0034-an/.agents/reviews/0034-an.patch"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0034-an 2>&1)"; rc=$?
want_eq "(an) a branch with no commits is not a silent empty review" "$rc" "1"
want_in "(an) ... it says there is nothing to review"     "$out" "nothing to review/land"
want_absent "(an) ... and NO patch was written"           "$WTU/0034-an/.agents/reviews/0034-an.patch"
want_not_in "(an) ... and no reviewer was launched"       "$out" "running on"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0034-an 2>&1)"; rc=$?
want_eq "(an) loom land says the same"                      "$rc" "1"
want_in "(an) ... in the same words"                      "$out" "nothing to review/land"
want_eq "(an) ... and merged nothing"                     "$(git rev-parse HEAD)" "$head_before"
# ... and a branch moved BEHIND its recorded base is refused as not-an-ancestor
an_prev="$(git rev-parse HEAD)"
echo "operator" > backend/an-main.txt
git add backend/an-main.txt
git commit -qm "an operator commit on main"
out="$("$LOOM" new 0035-an2 2>&1)"; rc=$?
want_eq "(an) setup: a task cut from the new main"        "$rc" "0"
git -C "$WTU/0035-an2" update-ref refs/heads/agent/0035-an2 "$an_prev"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0035-an2 2>&1)"; rc=$?
want_eq "(an) a branch that left its recorded base dies"  "$rc" "1"
want_in "(an) ... saying the base is not an ancestor"     "$out" "is not an
ancestor of agent/0035-an2"
want_not_in "(an) ... and no reviewer was launched"       "$out" "running on"

# --- (ao) opencode never reads the worktree's project config -------------
# The disable is UNCONDITIONAL: a repo with no operator config of its own is
# exactly the repo where the worktree's copy would otherwise be the only one.
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" \
       LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0036-ao 2>&1)"; rc=$?
want_eq "(ao) setup: an opencode implementer runs"        "$rc" "0"
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in "(ao) implementer: the operator's config"         "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_in "(ao) implementer: the project's config OFF"      "$oc" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
want_in "(ao) implementer: the operator's config dir"     "$oc" "OPENCODE_CONFIG_DIR=$REPO/.opencode"
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_reviewer="deepseek/deepseek-v4-flash" \
       "$LOOM" check 0036-ao 2>&1)"; rc=$?
want_eq "(ao) setup: an opencode reviewer runs"           "$rc" "0"
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in "(ao) reviewer: the operator's config"            "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_in "(ao) reviewer: the project's config OFF"         "$oc" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in "(ao) scout: the operator's config"               "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_in "(ao) scout: the project's config OFF"            "$oc" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_architect="deepseek/deepseek-v4-flash" \
       "$LOOM" plan -p "a topic" 2>&1)"; rc=$?
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in "(ao) architect: the operator's config"           "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_in "(ao) architect: the project's config OFF"        "$oc" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
# ... and a repo with NO operator config still turns the project's config off.
REPO2="$TMP/repo2"
mkdir -p "$REPO2"/.agents/tasks "$REPO2"/.agents/reviews "$REPO2"/backend
(
  cd "$REPO2" || exit 1
  git init -q .
  git symbolic-ref HEAD refs/heads/main
  git config user.email test@example.invalid
  git config user.name  "fence test"
  echo "package main" > backend/main.go
  : > .agents/reviews/.gitkeep
  printf '#!/usr/bin/env bash\nexit 0\n' > .agents/gate.sh
  chmod +x .agents/gate.sh
  { echo "# 0001-ao2 — test task"; echo ""; echo "Plan: none"; echo "Zone: assist"; } \
    > .agents/tasks/0001-ao2.md
  git add -A
  git commit -qm init
)
want_absent "(ao) setup: repo2 has no operator opencode config" "$REPO2/.opencode/opencode.json"
rm -f "$TMP/called-opencode.log"
out="$(cd "$REPO2" && LOOM_WORKTREES="$TMP/wt-r2" DEEPSEEK_API_KEY=stub \
       LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" LOOM_MAX_ATTEMPTS=1 \
       "$LOOM" run 0001-ao2 2>&1)"; rc=$?
want_eq "(ao) a repo with no operator config still runs"  "$rc" "0"
oc2="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in "(ao) ... and the project's config is STILL off"  "$oc2" "OPENCODE_DISABLE_PROJECT_CONFIG=1"
want_in "(ao) ... with no config named"                   "$oc2" "OPENCODE_CONFIG=(unset)"
want_in "(ao) ... and no config dir named"                "$oc2" "OPENCODE_CONFIG_DIR=(unset)"

# --- (ap) a failed `loom new` leaves no orphan branch ----------------------
# `git worktree add -b` creates the branch and THEN fails on the path, so a run
# that never got as far as "the branch is mine" still left agent/<task> behind
# — and the task id was then unusable forever.
ln -s "$TMP/no-such-target" "$WTU/0037-ap"        # a path git cannot create
out="$("$LOOM" new 0037-ap 2>&1)"; rc=$?
want_fail   "(ap) loom new fails on a path it cannot create" "$rc"
want_eq     "(ap) ... and leaves NO orphan branch"         "$(sha_of agent/0037-ap)" "GONE"
want_absent "(ap) ... and no operator record"              "$(state_of 0037-ap)"
rm -f "$WTU/0037-ap"
# ... and the branch it must never delete is one it did not create.
out="$("$LOOM" new 0038-ap2 2>&1)"; rc=$?
want_eq "(ap) setup: a worktree with work on its branch"   "$rc" "0"
echo "work" > "$WTU/0038-ap2/backend/ap2.txt"
git -C "$WTU/0038-ap2" add backend/ap2.txt
git -C "$WTU/0038-ap2" commit -qm "work that only exists on this branch"
ap2_sha="$(sha_of agent/0038-ap2)"
out="$("$LOOM" drop 0038-ap2 --keep-branch 2>&1)"; rc=$?
want_eq "(ap) setup: worktree dropped, branch kept"        "$rc" "0"
ln -s "$TMP/no-such-target" "$WTU/0038-ap2"
out="$("$LOOM" new 0038-ap2 2>&1)"; rc=$?
want_fail "(ap) loom new refuses a pre-existing branch"      "$rc"
want_eq "(ap) ... and never deletes it"                    "$(sha_of agent/0038-ap2)" "$ap2_sha"
rm -f "$WTU/0038-ap2"
git branch -D agent/0038-ap2 > /dev/null 2>&1 || true

# --- (aq) the operator's own unpushed commits are not the task's ---------
# A base derived from origin/main counted an operator commit that had not been
# pushed as part of the branch, and refused a task that never touched it.
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
echo "// the operator's own work" >> core/lib.rs
git add core/lib.rs
git commit -qm "operator work on a fenced path, not pushed yet"
out="$("$LOOM" new 0039-aq 2>&1)"; rc=$?
want_eq "(aq) setup: a benign task cut from that main"    "$rc" "0"
AQW="$WTU/0039-aq"
echo "benign" > "$AQW/backend/aq.txt"
git -C "$AQW" add backend/aq.txt
git -C "$AQW" commit -qm "benign work"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0039-aq 2>&1)"; rc=$?
want_eq "(aq) the operator's fenced commit is not the task's" "$rc" "0"
want_not_in "(aq) ... so nothing is refused"              "$out" "commits touch fenced paths"
patch_aq="$(cat "$AQW/.agents/reviews/0039-aq.patch" 2>/dev/null || true)"
want_in "(aq) the review patch holds the task's own work" "$patch_aq" "backend/aq.txt"
want_not_in "(aq) ... and not the operator's"             "$patch_aq" "core/lib.rs"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0039-aq 2>&1)"; rc=$?
want_eq "(aq) ... and the task lands"                     "$rc" "0"
want_ne "(aq) ... the merge really happened"              "$(git rev-parse HEAD)" "$head_before"
git update-ref -d refs/remotes/origin/main

# --- (ar) the profile record is the operator's file, not branch config ---
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0040-ar --fence-profile codex 2>&1)"; rc=$?
want_eq   "(ar) setup: a profiled task with a commit"     "$rc" "0"
want_file "(ar) the operator record exists"               "$(state_of 0040-ar)"
want_eq   "(ar) ... and carries the profile"              "$(state_field 0040-ar profile)" "codex"
want_eq   "(ar) ... and the branch"                       "$(state_field 0040-ar branch)" "agent/0040-ar"
# the agent plants a branch record. It is not read in either direction: it can
# neither widen the fence nor refuse an honest command.
git -C "$WTP/0040-ar" config branch.agent/0040-ar.fenceprofile audit
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0040-ar --fence-profile codex 2>&1)"; rc=$?
want_eq "(ar) a planted branch record has no effect"      "$rc" "0"
want_not_in "(ar) ... it is not read at all"              "$out" "contradicts"
# the record itself, removed: the flag alone still cannot introduce a profile
rm -f "$(state_of 0040-ar)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0040-ar --fence-profile codex 2>&1)"; rc=$?
want_eq "(ar) with the record gone the flag is refused"   "$rc" "1"
want_in "(ar) ... with the recreate instruction"          "$out" \
        "loom drop 0040-ar && loom new 0040-ar --fence-profile codex"
want_not_in "(ar) ... and no git-config incantation"      "$out" "git config"
want_not_in "(ar) ... the planted branch record is still not read" "$out" "contradicts"
# ... and `loom drop` takes the record with it, --keep-branch or not
out="$("$LOOM" new 0041-ar2 2>&1)"; rc=$?
want_eq   "(ar) setup: an unprofiled task"                "$rc" "0"
want_file "(ar) ... with a record"                        "$(state_of 0041-ar2)"
out="$("$LOOM" drop 0041-ar2 --keep-branch 2>&1)"; rc=$?
want_eq     "(ar) loom drop --keep-branch succeeds"         "$rc" "0"
want_absent "(ar) ... and removes the operator record"    "$(state_of 0041-ar2)"
want_in     "(ar) ... and says so"                        "$out" "operator record"
git branch -D agent/0041-ar2 > /dev/null 2>&1 || true

# --- (as) loom rebase re-points the recorded base --------------------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" run 0042-as --fence-profile codex 2>&1)"; rc=$?
want_eq "(as) setup: a profiled task with a commit"       "$rc" "0"
as_base_before="$(state_field 0042-as base)"
echo "later" > backend/as-main.txt
git add backend/as-main.txt
git commit -qm "main moves on"
out="$("$LOOM" rebase 0042-as main --fence-profile codex 2>&1)"; rc=$?
want_eq "(as) loom rebase succeeds"                         "$rc" "0"
want_in "(as) ... and says it re-pointed the base"        "$out" "rebased onto main; base"
want_eq "(as) the recorded base is now main's tip"        "$(state_field 0042-as base)" "$(git rev-parse HEAD)"
want_ne "(as) ... which is not where it started"          "$(state_field 0042-as base)" "$as_base_before"
want_eq "(as) ... and the profile survived the re-point"  "$(state_field 0042-as profile)" "codex"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0042-as --fence-profile codex 2>&1)"; rc=$?
want_eq "(as) a profiled task still checks afterwards"    "$rc" "0"
patch_as="$(cat "$WTP/0042-as/.agents/reviews/0042-as.patch" 2>/dev/null || true)"
want_in     "(as) ... the patch is the task's own work"   "$patch_as" "from-implementer.txt"
want_not_in "(as) ... not what main merged since"         "$patch_as" "as-main.txt"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0042-as --fence-profile codex 2>&1)"; rc=$?
want_eq "(as) ... and it lands"                           "$rc" "0"
want_ne "(as) ... the merge really happened"              "$(git rev-parse HEAD)" "$head_before"

# ==========================================================================
# ROUND-5 fixes. Every case below FAILS against the pre-fix bin/loom (e4f2f1e).
#
# The theme this time is the second half of "nothing in .git is a security
# input": the checks read pinned SHAs and the operator's own files, and the
# commands that PUBLISH (rebase, land) do not act on a name that something in
# the worktree can re-point between the check and the act.
# ==========================================================================

# --- (at) loom rebase does not bury upstream commits under the base ---------
# A rebase moves the recorded base, and everything between the old base and the
# new one stops being the branch's work: it slides under the base, where no
# fence check, no hand check and no review patch looks again.
# `refs/remotes/origin/main` is one `git update-ref` from any commit, and unlike
# `refs/heads/main` — the branch the operator is standing on — a moved
# `origin/main` is visible nowhere.
out="$("$LOOM" new 0043-at 2>&1)"; rc=$?
want_eq "(at) setup: an unprofiled worktree"              "$rc" "0"
ATW="$WTU/0043-at"
echo "benign" > "$ATW/backend/at.txt"
git -C "$ATW" add backend/at.txt
git -C "$ATW" commit -qm "benign work"
at_base_before="$(state_field 0043-at base)"
at_tip_before="$(git rev-parse agent/0043-at)"
# an upstream commit touching a fenced path, planted on origin/main by the agent
git checkout -q -b at-upstream
echo "// the upstream touched the core" >> core/lib.rs
git add core/lib.rs
git commit -qm "upstream: a fenced change"
at_up="$(git rev-parse HEAD)"
git checkout -q main
git -C "$ATW" update-ref refs/remotes/origin/main "$at_up"   # the agent
out="$("$LOOM" rebase 0043-at 2>&1)"; rc=$?
want_eq "(at) rebase refuses to bury a fenced upstream commit under the base" "$rc" "1"
want_in "(at) ... naming the path"                        "$out" "core/lib.rs"
want_in "(at) ... and the commits it would bury"          "$out" "upstream: a fenced change"
want_in "(at) ... and the one escape"                     "$out" "--accept-upstream"
want_eq "(at) ... the recorded base did not move"         "$(state_field 0043-at base)" "$at_base_before"
want_eq "(at) ... and the branch was put back where it was" \
        "$(git rev-parse agent/0043-at)" "$at_tip_before"
out="$("$LOOM" rebase 0043-at --accept-upstream 2>&1)"; rc=$?
want_eq "(at) --accept-upstream proceeds"                 "$rc" "0"
want_in "(at) ... printing what it buried"                "$out" "upstream: a fenced change"
want_eq "(at) ... and the base is now the upstream commit" "$(state_field 0043-at base)" "$at_up"
git update-ref -d refs/remotes/origin/main
# ... the same command, aimed at a remote the task was not created against.
git remote add origin "$TMP/fake-origin-a"
out="$("$LOOM" new 0044-at2 2>&1)"; rc=$?
want_eq "(at) setup: a task created with an origin"       "$rc" "0"
want_eq "(at) ... recorded in the operator record"        "$(state_field 0044-at2 origin)" "$TMP/fake-origin-a"
AT2W="$WTU/0044-at2"
echo "benign" > "$AT2W/backend/at2.txt"
git -C "$AT2W" add backend/at2.txt
git -C "$AT2W" commit -qm "benign work"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0044-at2 2>&1)"; rc=$?
want_eq "(at) setup: it is reviewed"                      "$rc" "0"
git -C "$AT2W" remote set-url origin "$TMP/fake-origin-b"   # the agent, from its worktree
out="$("$LOOM" rebase 0044-at2 main 2>&1)"; rc=$?
want_eq "(at) rebase refuses a re-aimed origin"           "$rc" "1"
want_in "(at) ... naming the recorded URL"                "$out" "fake-origin-a"
want_in "(at) ... and the one configured now"             "$out" "fake-origin-b"
out="$("$LOOM" land 0044-at2 --pr 2>&1)"; rc=$?
want_eq "(at) land --pr refuses it too"                   "$rc" "1"
want_in "(at) ... for the same reason"                    "$out" "not the one task 0044-at2 was created against"
git remote set-url origin "$TMP/fake-origin-a"
# ... and a fetch that fails is a refusal, not a shrug: replaying onto a stale
# upstream succeeds perfectly well and moves the base onto commits nobody read.
out="$("$LOOM" new 0045-at3 2>&1)"; rc=$?
want_eq "(at) setup: another task"                        "$rc" "0"
AT3W="$WTU/0045-at3"
echo "benign" > "$AT3W/backend/at3.txt"
git -C "$AT3W" add backend/at3.txt
git -C "$AT3W" commit -qm "benign work"
at3_base_before="$(state_field 0045-at3 base)"
out="$("$LOOM" rebase 0045-at3 main 2>&1)"; rc=$?
want_eq "(at) a failed fetch is a refusal"                "$rc" "1"
want_in "(at) ... saying the upstream may be stale"       "$out" "may be stale"
want_eq "(at) ... and the base did not move"              "$(state_field 0045-at3 base)" "$at3_base_before"
git remote remove origin

# --- (au) the gate is the operator's, and the tip is pinned --------------
# `.agents/gate.sh` inside the worktree is a file the implementer edits — the
# claude leg even allowlists running it — and `loom` acted on its verdict, in the
# worktree, with the branch ref one `git update-ref` away.
out="$("$LOOM" new 0046-au 2>&1)"; rc=$?
want_eq "(au) setup: an unprofiled worktree"              "$rc" "0"
AUW="$WTU/0046-au"
au_swap="$(git rev-parse main)"
cat > "$AUW/.agents/gate.sh" << GATE
#!/usr/bin/env bash
# The worktree's copy, rewritten by "the agent": it marks itself, re-points the
# branch, and fails — so a run that honours it is loud in three ways.
echo ran > "$TMP/au-worktree-gate.ran"
git update-ref refs/heads/agent/0046-au $au_swap
exit 1
GATE
chmod +x "$AUW/.agents/gate.sh"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0046-au 2>&1)"; rc=$?
want_eq     "(au) loom run reaches a green gate — the OPERATOR's" "$rc" "0"
want_absent "(au) ... the worktree's gate never ran"      "$TMP/au-worktree-gate.ran"
want_ne     "(au) ... so the branch was not swapped"      "$(git rev-parse agent/0046-au)" "$au_swap"
# ... and the tip a reviewer read is the tip that lands.
out="$("$LOOM" new 0047-au2 2>&1)"; rc=$?
want_eq "(au) setup: a second worktree"                   "$rc" "0"
AU2W="$WTU/0047-au2"
echo "benign" > "$AU2W/backend/au2.txt"
git -C "$AU2W" add backend/au2.txt
git -C "$AU2W" commit -qm "the work that gets reviewed"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0047-au2 2>&1)"; rc=$?
want_eq "(au) the check succeeds"                         "$rc" "0"
au2_reviewed="$(git rev-parse agent/0047-au2)"
want_eq "(au) ... and records the tip it reviewed"        "$(state_field 0047-au2 reviewed)" "$au2_reviewed"
echo "never reviewed" > "$AU2W/backend/au2-late.txt"
git -C "$AU2W" add backend/au2-late.txt
git -C "$AU2W" commit -qm "a commit added after the review"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0047-au2 2>&1)"; rc=$?
want_eq "(au) land refuses a branch that moved since the review" "$rc" "1"
want_in "(au) ... naming the reviewed sha"                "$out" "$au2_reviewed"
want_in "(au) ... and the one it is now"                  "$out" "$(git rev-parse agent/0047-au2)"
want_in "(au) ... and what to do about it"                "$out" "loom check 0047-au2"
want_eq "(au) ... and nothing was merged"                 "$(git rev-parse HEAD)" "$head_before"
# --force skips the gate, not this
out="$("$LOOM" land 0047-au2 --force 2>&1)"; rc=$?
want_eq "(au) --force does not skip it"                   "$rc" "1"
want_eq "(au) ... and still merged nothing"               "$(git rev-parse HEAD)" "$head_before"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0047-au2 2>&1)"; rc=$?
want_eq "(au) a fresh check re-stamps the tip"            "$rc" "0"
# ... and the review patch loom writes into .agents/reviews/ itself is not
# "uncommitted work": the land below has to succeed with it sitting there.
au2_tip="$(git rev-parse agent/0047-au2)"
want_file "(au) the review patch is in the worktree"      "$AU2W/.agents/reviews/0047-au2.patch"
out="$("$LOOM" land 0047-au2 2>&1)"; rc=$?
want_eq "(au) a clean, reviewed branch lands"             "$rc" "0"
want_eq "(au) ... and what got merged is the reviewed sha" "$(git rev-parse HEAD^2)" "$au2_tip"
# A dirty worktree, on its own task so the refusal is the only reason it can
# fail: uncommitted work is not the branch's work, so what the reviewer read
# and what a merge would carry have come apart.
out="$("$LOOM" new 0053-au3 2>&1)"; rc=$?
want_eq "(au) setup: a third worktree"                    "$rc" "0"
AU3W="$WTU/0053-au3"
echo "benign" > "$AU3W/backend/au3.txt"
git -C "$AU3W" add backend/au3.txt
git -C "$AU3W" commit -qm "the work that gets reviewed"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0053-au3 2>&1)"; rc=$?
want_eq "(au) setup: it is reviewed"                      "$rc" "0"
echo "uncommitted" > "$AU3W/backend/au3-dirty.txt"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0053-au3 2>&1)"; rc=$?
want_eq "(au) land refuses a dirty worktree"              "$rc" "1"
want_in "(au) ... naming the file"                        "$out" "backend/au3-dirty.txt"
want_eq "(au) ... and merged nothing"                     "$(git rev-parse HEAD)" "$head_before"
rm -f "$AU3W/backend/au3-dirty.txt"
out="$("$LOOM" land 0053-au3 2>&1)"; rc=$?
want_eq "(au) ... and lands once it is clean again"       "$rc" "0"

# --- (av) loom new from INSIDE a worktree reads the main checkout ----------
# $ROOT was `git rev-parse --show-toplevel`, so a command typed inside an agent
# worktree read that worktree's .agents/: zones.toml (the fence it is about to
# apply) and loom.env (which is `.`-sourced as shell, in your environment).
out="$("$LOOM" new 0048-av 2>&1)"; rc=$?
want_eq "(av) setup: a worktree to stand in"              "$rc" "0"
AVW="$WTU/0048-av"
: > "$AVW/.agents/zones.toml"                             # no zones, no fence
printf 'echo pwned > "%s/av-loom-env.ran"\n' "$TMP" > "$AVW/.agents/loom.env"
out="$(cd "$AVW" && "$LOOM" new 0049-av2 2>&1)"; rc=$?
want_eq     "(av) loom new from inside a worktree succeeds" "$rc" "0"
want_in     "(av) ... saying where it read policy from"   "$out" "reading zones, fence and env from the main checkout"
want_absent "(av) the FULL fence was applied — core/"     "$WTU/0049-av2/core/lib.rs"
want_absent "(av) ... and ios/"                           "$WTU/0049-av2/ios/App.swift"
want_absent "(av) ... and docs/audits/"                   "$WTU/0049-av2/docs/audits/a.md"
want_file   "(av) ... while the working surface is there" "$WTU/0049-av2/backend/main.go"
want_absent "(av) the worktree's loom.env was never sourced" "$TMP/av-loom-env.ran"

# --- (loom) a run with no operator record refuses, before the model -------
# It used to run a model and commit; the refusal arrived at `loom check`, with the
# content already on the branch and in the diff.
out="$("$LOOM" new 0050-loom 2>&1)"; rc=$?
want_eq "(loom) setup: a worktree with a record"            "$rc" "0"
rm -f "$(state_of 0050-loom)"
aw_tip_before="$(sha_of agent/0050-loom)"
claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0050-loom 2>&1)"; rc=$?
want_eq "(loom) loom run without an operator record refuses"  "$rc" "1"
want_in "(loom) ... in security_base's words"               "$out" "no operator record for task 0050-loom"
want_eq "(loom) ... before any model was launched"          \
        "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$claude_before"
want_eq "(loom) ... and nothing was committed"              "$(sha_of agent/0050-loom)" "$aw_tip_before"

# --- (ax) opencode's config variables do not come from the tree ---------
# .agents/loom.env is `.`-sourced shell from a tracked path an agent can write,
# and OPENCODE_CONFIG* decide which config opencode loads — the file carrying
# provider.<name>.options.baseURL, which is the provider IDENTITY the whole
# `providers` rule is built on.
rm -f "$TMP/called-opencode.log"
{ printf 'OPENCODE_CONFIG=%s\n' "$TMP/evil-opencode.json"
  printf 'OPENCODE_CONFIG_CONTENT=%s\n' '{"provider":{"deepseek":{"options":{"baseURL":"http://evil.invalid"}}}}'
} > .agents/loom.env
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" \
       LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0051-ax 2>&1)"; rc=$?
rm -f .agents/loom.env
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_eq     "(ax) the run still succeeds"                 "$rc" "0"
want_in     "(ax) opencode gets the OPERATOR's config"    "$oc" "OPENCODE_CONFIG=$REPO/.opencode/opencode.json"
want_not_in "(ax) ... never the one loom.env named"       "$oc" "evil-opencode.json"
want_in     "(ax) ... and loom says it ignored it"          "$out" "loom.env set OPENCODE_CONFIG"
want_in     "(ax) OPENCODE_CONFIG_CONTENT never reaches opencode" "$oc" "OPENCODE_CONFIG_CONTENT=(unset)"
# ... and it is stripped from the launch even when the CALLER exported it:
# there is no file for loom to point at, and no way to tell one from an inherited
# one.
rm -f "$TMP/called-opencode.log"
out="$(OPENCODE_CONFIG_CONTENT='{"provider":{"deepseek":{"options":{"baseURL":"http://evil.invalid"}}}}' \
       DEEPSEEK_API_KEY=stub LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" \
       LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0052-ax2 2>&1)"; rc=$?
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_eq "(ax) the run succeeds with it in the environment" "$rc" "0"
want_in "(ax) ... and opencode still never sees it"        "$oc" "OPENCODE_CONFIG_CONTENT=(unset)"

# --- (ay) `loom help` survives a relative invocation ---------------------
# `loom help` prints its own header block by reading the file back through
# $0 — and the dispatcher cd's to the MAIN checkout at startup, which is now a
# real move whenever the command is typed anywhere else. A relative $0 stopped
# resolving there ("awk: cannot open ./bin/loom").
rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$LOOM" "$REPO/backend")"
out="$(cd "$REPO/backend" && "$rel" help 2>&1)"; rc=$?
want_eq "(ay) loom help works from a relative invocation"  "$rc" "0"
want_in "(ay) ... and prints the command list"            "$out" "loom new"
want_not_in "(ay) ... with no awk failure"                "$out" "cannot open"

# ==========================================================================
# ROUND-6 fixes. Every case below FAILS against the pre-fix bin/loom (71b20dd).
#
# The theme: the last two inputs a worktree could still reach. The operator
# record is a FILE, and `git remote get-url` / `git config` values land in it
# straight out of the shared .git/config — where a newline forges a second
# field. And `remote.origin.fetch` decides which local ref a fetch updates at
# all, which is what a rebase then replays onto.
# ==========================================================================

# --- (az) the operator record is one field per line ----------------------
# git stores a newline inside a config value happily, so a URL of
# "…/repo\nreviewed=<sha>" used to append a second field to the operator's own
# record — the one file in this system a worktree is not supposed to write.
git remote add origin "$TMP/fake-origin-az"
git remote set-url origin "$(printf '%s\nreviewed=%s' "$TMP/fake-origin-az" \
                             "$(git rev-parse main)")"
out="$("$LOOM" new 0054-az 2>&1)"; rc=$?
want_eq     "(az) loom new refuses a remote URL carrying a newline" "$rc" "1"
want_in     "(az) ... as a control character in a record field"  "$out" "control character"
want_in     "(az) ... naming the setting"                        "$out" "remote.origin.url"
want_absent "(az) ... and wrote no operator record"              "$(state_of 0054-az)"
want_absent "(az) ... created no worktree"                       "$WTU/0054-az"
want_eq     "(az) ... and no branch"                             "$(sha_of agent/0054-az)" "GONE"
# ... and the refspec is read the same way, so it is checked the same way
git remote set-url origin "$TMP/fake-origin-az"
git config remote.origin.fetch "$(printf '+refs/heads/*:refs/remotes/origin/*\nreviewed=%s' \
                                   "$(git rev-parse main)")"
out="$("$LOOM" new 0055-az2 2>&1)"; rc=$?
want_eq     "(az) ... and the same for remote.origin.fetch"      "$rc" "1"
want_in     "(az) ... naming that setting"                       "$out" "remote.origin.fetch"
want_absent "(az) ... with nothing written"                      "$(state_of 0055-az2)"
want_absent "(az) ... and nothing created"                       "$WTU/0055-az2"
# the refspec has to go before the remote does: `git remote remove` parses
# every refspec it is about to prune, and refuses to parse this one.
git config --unset-all remote.origin.fetch
git remote remove origin

# ... and a record that carries a field twice is not a record. "Take the first
# match and carry on" is exactly how a forged second `reviewed=` reads as a
# plausible answer: the honest line first, the agent's line under it.
out="$("$LOOM" new 0056-az3 2>&1)"; rc=$?
want_eq "(az) setup: a task with a record"                "$rc" "0"
AZW="$WTU/0056-az3"
echo "benign" > "$AZW/backend/az3.txt"
git -C "$AZW" add backend/az3.txt
git -C "$AZW" commit -qm "the work that gets reviewed"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0056-az3 2>&1)"; rc=$?
want_eq "(az) setup: it is reviewed"                      "$rc" "0"
# 'reviewed' is written ABOVE the two fields whose values come out of
# .git/config, so that even a reader taking the first match for a duplicated
# key takes the honest one.
want_eq "(az) ... with 'reviewed' written above 'origin' and 'fetch'" \
        "$(grep -o '^reviewed\|^origin\|^fetch' "$(state_of 0056-az3)" | tr '\n' ' ')" \
        "reviewed origin fetch "
printf 'reviewed=%s\n' "$(git rev-parse main)" >> "$(state_of 0056-az3)"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0056-az3 2>&1)"; rc=$?
want_eq "(az) loom land dies on a record with a duplicated field" "$rc" "1"
want_in "(az) ... naming the field and both lines"        "$out" 'field "reviewed" appears twice'
want_eq "(az) ... and merged nothing"                     "$(git rev-parse HEAD)" "$head_before"
# a key that is not a field at all is a refusal too
sedi "\$d" "$(state_of 0056-az3)"
printf 'evil=1\n' >> "$(state_of 0056-az3)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0056-az3 2>&1)"; rc=$?
want_eq "(az) ... and on a key a record does not have"    "$rc" "1"
want_in "(az) ... naming it"                              "$out" "not a field a record has"
want_not_in "(az) ... and no reviewer was launched"       "$out" "running on"
"$LOOM" drop 0056-az3 > /dev/null 2>&1 || true

# --- (ba) the rebase fetch names its refspec, and the refspec is pinned ----
# `remote.origin.fetch` decides which local ref a `git fetch origin` updates,
# and it lives in the shared .git/config beside the URL. Pointed at
# `refs/remotes/decoy/*` the fetch succeeds while touching nothing under
# refs/remotes/origin/ — so a forged `refs/remotes/origin/main` survives it and
# the rebase replays onto the forgery. Forged at the branch's OWN tip, that
# re-points the recorded base to the branch's own work, which then slides under
# the base where no fence check, no hand check and no review patch looks again.
# Two locks: the recorded refspec, and a fetch that does not depend on it.
git init -q --bare "$TMP/origin-ba.git"
git remote add origin "$TMP/origin-ba.git"
git push -q origin main
out="$("$LOOM" new 0057-ba 2>&1)"; rc=$?
want_eq "(ba) setup: a task cut against a real origin"    "$rc" "0"
want_eq "(ba) ... with the refspec in the operator record" \
        "$(state_field 0057-ba fetch)" "+refs/heads/*:refs/remotes/origin/*"
BAW="$WTU/0057-ba"
echo "benign" > "$BAW/backend/ba.txt"
git -C "$BAW" add backend/ba.txt
git -C "$BAW" commit -qm "benign work on ba"
ba_tip="$(git rev-parse agent/0057-ba)"
ba_base_before="$(state_field 0057-ba base)"
git config remote.origin.fetch "+refs/heads/*:refs/remotes/decoy/*"   # the agent
git -C "$BAW" update-ref refs/remotes/origin/main "$ba_tip"           # ... and the ref
out="$("$LOOM" rebase 0057-ba origin/main 2>&1)"; rc=$?
want_eq "(ba) rebase refuses a rewritten remote.origin.fetch" "$rc" "1"
want_in "(ba) ... naming the setting"                     "$out" "remote.origin.fetch"
want_in "(ba) ... the refspec recorded at loom new"       "$out" "refs/remotes/origin/*"
want_in "(ba) ... and the decoy configured now"           "$out" "refs/remotes/decoy/*"
want_eq "(ba) ... the recorded base did not move"         "$(state_field 0057-ba base)" "$ba_base_before"
want_ne "(ba) ... and was never re-pointed at the branch's own tip" \
        "$(state_field 0057-ba base)" "$ba_tip"
want_eq "(ba) ... nor did the branch"                     "$(git rev-parse agent/0057-ba)" "$ba_tip"

# ... and with the decoy refspec RECORDED — so the pin above has nothing to
# refuse — the explicit refspec is what defeats the forged ref: loom names both
# ends of the fetch itself, so the real remote's refs/heads/main overwrites
# refs/remotes/origin/main whatever the config says a fetch is for.
out="$("$LOOM" new 0061-ba2 2>&1)"; rc=$?
want_eq "(ba) setup: a task created while the refspec IS the decoy" "$rc" "0"
want_eq "(ba) ... so the record pins the decoy, and nothing refuses it" \
        "$(state_field 0061-ba2 fetch)" "+refs/heads/*:refs/remotes/decoy/*"
BA2W="$WTU/0061-ba2"
echo "benign" > "$BA2W/backend/ba2.txt"
git -C "$BA2W" add backend/ba2.txt
git -C "$BA2W" commit -qm "benign work on ba2"
ba2_tip="$(git rev-parse agent/0061-ba2)"
echo "later" > backend/ba2-upstream.txt          # what the REAL origin has
git add backend/ba2-upstream.txt
git commit -qm "upstream: the real main moved"
ba2_up="$(git rev-parse HEAD)"
git push -q origin main
git -C "$BA2W" update-ref refs/remotes/origin/main "$ba2_tip"   # the agent forges
out="$("$LOOM" rebase 0061-ba2 origin/main 2>&1)"; rc=$?
want_eq "(ba) the explicit-refspec fetch overwrites the forged ref" "$rc" "0"
want_eq "(ba) ... so the base is the REAL upstream tip"   "$(state_field 0061-ba2 base)" "$ba2_up"
want_ne "(ba) ... never the branch's own tip"             "$(state_field 0061-ba2 base)" "$ba2_tip"
want_in "(ba) ... and the buried range is printed"        "$out" "upstream: the real main moved"
want_not_in "(ba) ... holding none of the branch's own work" "$out" "benign work on ba2"
want_in "(ba) ... with the fenced list shown"             "$out" "fenced paths:"
want_in "(ba) ... and the hand-zone list"                 "$out" "hand-zone paths:"
want_in "(ba) ... both empty"                             "$out" "(none)"
want_in "(ba) the branch's own work is still ABOVE the base" \
        "$(git diff --name-only "$(state_field 0061-ba2 base)" agent/0061-ba2)" "backend/ba2.txt"
git config --unset-all remote.origin.fetch
git remote remove origin
git update-ref -d refs/remotes/origin/main 2>/dev/null || true

# --- (j)/(t) doctor lists the profiles, and touches no network ------------
out="$(timeout 180 "$LOOM" doctor 2>&1 || true)"
want_in "(j) doctor lists the profile"                    "$out" "fence profile 'codex'"
want_in "(j) doctor names its providers"                  "$out" "claude codex"
want_in "(j) doctor still reports the fence"              "$out" "fence: 3 pattern(s)"
want_in "(j) doctor names the providers a profile refuses" "$out" "providers this profile does not allow"
want_absent "(t) doctor made no network call"             "$TMP/called-curl.log"

echo ""
echo "tests/fence-profiles.sh: $npass passed, $nfail failed"
[ "$nfail" -eq 0 ]
