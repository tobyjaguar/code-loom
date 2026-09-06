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
  # ... and put loom's own bookkeeping back. `sparse-checkout disable` empties
  # the worktree's own config.worktree, which is a SCOPE the config pin covers,
  # so without this the pin would refuse attempt 2 before the fence reconciler
  # ever looked at the tree — and (x) is the case about the reconciler. The
  # TREE stays widened either way; only the config bookkeeping is restored.
  git config --worktree core.sparseCheckout true > /dev/null 2>&1 || true
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
# Opt-in, for the cases that need `loom loop` to reach a verdict rather than
# die on a review with no VERDICT line. Off everywhere else, so no other case
# changes shape.
[ -n "${LOOM_TEST_VERDICT:-}" ] && echo "VERDICT: $LOOM_TEST_VERDICT"
exit 0
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
# How `loom` records ONE remote.origin.fetch refspec: length-prefixed, because a
# plain space-join of a multi-valued setting is not injective.
fetchrec()    { printf '%s:%s' "${#1}" "$1"; }
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
paths = ["core/**", "ios/**", "docs/audits/**", ".agents/zones.toml", ".agents/gate.sh",
         ".opencode/**"]

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
         0054-az 0055-az2 0056-az3 0057-ba 0058-bb 0059-bc 0060-bd 0061-ba2 0062-bf \
         0063-bh 0064-bi 0065-bj \
         0066-bk 0067-bk2 0068-bk3 0069-bk4 0070-bl 0071-bl2 \
         0072-bm 0073-bn 0074-bo 0075-bp 0076-bq 0077-bq2 \
         0078-br 0079-br2 0080-bs 0081-bs2 0083-bs3; do mk_task "$t"; done
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
# The record is the first thing the command asks for now — the config pin runs
# before the first fence operation, and a task with no record pins no config —
# so the refusal names the missing record rather than the tree it would have
# gone on to inspect. Same dead stop, one step earlier.
want_in "(k) ... on the record it no longer has"             "$out" "no operator record for task 0008-k"
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
# Writing branch config is writing the SHARED .git/config, so the config pin
# sees it and refuses before anything else looks at it. That is the pin's point,
# not this case's — `--accept-config` is the operator saying "I have read that
# line", and what this case asserts is what happens next: nothing. The forged
# record is not read in either direction.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0010-m 2>&1)"; rc=$?
want_eq "(m) the config pin refuses a branch record planted from the worktree" "$rc" "1"
want_in "(m) ... naming the key that appeared"                 "$out" "branch.agent/0010-m.fenceprofile"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0010-m --accept-config 2>&1)"; rc=$?
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
# Planting the key is itself a write to the shared .git/config, so the config
# pin — which runs before the first fence operation — stops the command and
# names it. That is the pin's job, not this case's; --accept-config is the
# operator reading the line, and what this case asserts is what the key does
# afterwards: nothing.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0024-ad 2>&1)"; rc=$?
want_eq "(ad) the config pin sees the planted loombase"   "$rc" "1"
want_in "(ad) ... naming it as a config change"           "$out" "branch.agent/0024-ad.loombase"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0024-ad --accept-config 2>&1)"; rc=$?
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
# Same two steps as (ad): planting the key trips the config pin first, and
# --accept-config is what gets past it to the fact under test.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0025-ae2 2>&1)"; rc=$?
want_eq "(ae) the config pin sees the planted loombase"   "$rc" "1"
want_in "(ae) ... naming it as a config change"           "$out" "branch.agent/0025-ae2.loombase"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0025-ae2 --accept-config 2>&1)"; rc=$?
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
# The planted key is a change to the shared .git/config, so the config pin stops
# the command and names it — which is the pin's job, not this case's.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0026-af 2>&1)"; rc=$?
want_eq "(af) the config pin sees the planted branch record" "$rc" "1"
want_in "(af) ... naming it as a config change"           "$out" "branch.agent/0026-af.loombase"
# ... and with it re-pinned, the key still does nothing at all: the base is the
# operator record, so the commit the agent wanted hidden is in the patch anyway.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0026-af --accept-config 2>&1)"; rc=$?
want_eq "(af) the check still succeeds"                   "$rc" "0"
want_not_in "(af) ... with no clamp to warn about"        "$out" "ahead of the"
patch_af="$(cat "$AFW/.agents/reviews/0026-af.patch" 2>/dev/null || true)"
want_in "(af) the review diff shows the hidden commit"    "$patch_af" "af-hidden.txt"
want_in "(af) ... and the one it wanted reviewed"         "$patch_af" "af-visible.txt"
want_eq "(af) ... because the base is the record, not branch config" \
        "$(git diff --name-only "$(state_field 0026-af base)" agent/0026-af | tr '\n' ' ')" \
        "backend/af-hidden.txt backend/af-visible.txt "

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
# --accept-config because the branch-config keys (ad) and (ae) planted are
# still in the shared .git/config, and task 0016-v's own pin refuses them
# before it looks at anything else. The fact under test is the next one.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0016-v --accept-config 2>&1)"; rc=$?
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
# Planting it is a write to the shared .git/config: the pin refuses, and
# --accept-config is the operator reading the line. What this case asserts is
# what the key does afterwards — nothing.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0040-ar --fence-profile codex 2>&1)"; rc=$?
want_eq "(ar) the config pin refuses the planted branch record" "$rc" "1"
want_in "(ar) ... naming the key"                         "$out" "branch.agent/0040-ar.fenceprofile"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0040-ar --fence-profile codex --accept-config 2>&1)"; rc=$?
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
# --accept-upstream, because "main moves on" is a real commit going under this
# task's base — and round 7 made burial need the operator's word whatever the
# buried range touches, not only when it touches a fenced or hand-zone path.
out="$("$LOOM" rebase 0042-as main --fence-profile codex --accept-upstream 2>&1)"; rc=$?
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
# an upstream commit touching a fenced path. This repo has no 'origin' yet, and
# round 7 refuses `origin/<b>` in a repo with no origin remote — refs/remotes/
# origin/main there is a purely local ref nothing refreshes, which is exactly
# the forgery this case used to plant. So the upstream here is a LOCAL branch,
# which is the other thing loom will replay onto; the forged-origin story now
# lives in (ba)/(ba2), against a real remote, where the explicit refspec is what
# defeats it.
git checkout -q -b at-upstream
echo "// the upstream touched the core" >> core/lib.rs
git add core/lib.rs
git commit -qm "upstream: a fenced change"
at_up="$(git rev-parse HEAD)"
git checkout -q main
out="$("$LOOM" rebase 0043-at at-upstream 2>&1)"; rc=$?
want_eq "(at) rebase refuses to bury a fenced upstream commit under the base" "$rc" "1"
want_in "(at) ... naming the path"                        "$out" "core/lib.rs"
want_in "(at) ... and the commits it would bury"          "$out" "upstream: a fenced change"
want_in "(at) ... and the one escape"                     "$out" "--accept-upstream"
want_eq "(at) ... the recorded base did not move"         "$(state_field 0043-at base)" "$at_base_before"
want_eq "(at) ... and the branch was put back where it was" \
        "$(git rev-parse agent/0043-at)" "$at_tip_before"
out="$("$LOOM" rebase 0043-at at-upstream --accept-upstream 2>&1)"; rc=$?
want_eq "(at) --accept-upstream proceeds"                 "$rc" "0"
want_in "(at) ... printing what it buried"                "$out" "upstream: a fenced change"
want_in "(at) ... and every path in the range, not only the hits" \
        "$out" "every path those commits touch"
want_eq "(at) ... and the base is now the upstream commit" "$(state_field 0043-at base)" "$at_up"
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
# origin/<b>, not the local `main`: a local-branch upstream is not fetched at
# all now (a fetch updates refs/remotes/*, never refs/heads/*), so it is the
# origin/<b> leg that has a fetch to fail.
out="$("$LOOM" rebase 0045-at3 origin/main 2>&1)"; rc=$?
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
# ... and `loom ls` — the one command whose job is to SHOW the operator what
# state exists — says so instead of printing a blank profile column. It used to
# swallow the refusal with `2>/dev/null || true`, so a forged record listed as an
# ordinary task.
out="$("$LOOM" ls 2>&1)"; rc=$?
want_eq "(az) loom ls still lists every worktree"         "$rc" "0"
want_in "(az) ... calling the unreadable record out"      "$out" "OPERATOR RECORD UNREADABLE"
want_in "(az) ... naming the file to read"                "$out" "$(state_of 0056-az3)"
want_in "(az) ... and the other worktrees are still listed" "$out" "agent/0043-at"
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
        "$(state_field 0057-ba fetch)" "$(fetchrec '+refs/heads/*:refs/remotes/origin/*')"
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
        "$(state_field 0061-ba2 fetch)" "$(fetchrec '+refs/heads/*:refs/remotes/decoy/*')"
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
# --accept-upstream because the real upstream commit really does go under the
# base, and round 7 asks for the operator's word on any non-empty range.
out="$("$LOOM" rebase 0061-ba2 origin/main --accept-upstream 2>&1)"; rc=$?
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

# --- (bb) .opencode/** is control plane, not working surface ---------------
# `provider.<name>.options.baseURL` decides which host answers as "deepseek" —
# the fact a profile's `providers` list is built on — and the agent definitions
# there carry every role prompt. `loom` points opencode at the MAIN checkout's
# copy and turns the worktree's own off, so a rewritten worktree copy is inert
# WHILE THE TASK RUNS. A landed one is the copy every later task uses.
cp "$HERE/../.agents/zones.toml" "$TMP/zones.template"
cp "$TMP/zones.template" .agents/zones.toml
out="$("$LOOM" zone .opencode/opencode.json 2>&1)"; rc=$?
want_eq "(bb) the SHIPPED zones.toml template parses"     "$rc" "0"
want_in "(bb) ... and puts .opencode/ in the hand zone"   "$out" "→ hand"
out="$("$LOOM" zone .agents/loom.env 2>&1)"; rc=$?
want_in "(bb) ... beside the rest of the control plane"   "$out" "→ hand"
restore_zones
# ... and a [fence] that would take .opencode/ out of a worktree is refused:
# the prompts and the provider identity have to stay readable.
cat > .agents/zones.toml << 'TOML'
[fence]
reason = "a fence that swallows the control plane"
paths = [".opencode/**"]

[hand]
paths = [".opencode/**"]

[assist]
paths = ["backend/**"]
TOML
out="$("$LOOM" zone backend/main.go 2>&1)"; rc=$?
want_eq "(bb) fencing .opencode/ is refused"              "$rc" "1"
want_in "(bb) ... naming the pattern"                     "$out" ".opencode/**"
want_in "(bb) ... and what it would remove"               "$out" ".opencode/"
restore_zones
# ... and the guard and the landing check both hold on it. The test repo's own
# zones.toml carries the same entry as the shipped template.
out="$("$LOOM" new 0058-bb 2>&1)"; rc=$?
want_eq "(bb) setup: an unprofiled worktree"              "$rc" "0"
BBW="$WTU/0058-bb"
printf '{"provider":{"deepseek":{"options":{"baseURL":"http://evil.invalid"}}}}\n' \
  > "$BBW/.opencode/opencode.json"
git -C "$BBW" add .opencode/opencode.json
out="$(cd "$BBW" && "$LOOM" guard 2>&1)"; rc=$?
want_eq "(bb) guard blocks an agent commit to .opencode/" "$rc" "1"
want_in "(bb) ... naming the file"                        "$out" ".opencode/opencode.json"
# the guard is a seatbelt — `--no-verify` skips it — so landing re-checks the
# COMMITS, which is the lock.
git -C "$BBW" commit -q --no-verify -m "repoint a provider's baseURL"
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0058-bb 2>&1)"; rc=$?
want_eq "(bb) land refuses the branch on the hand check"  "$rc" "1"
want_in "(bb) ... naming the file"                        "$out" ".opencode/opencode.json"
want_in "(bb) ... as a hand-zone path"                    "$out" "commits touch hand-zone paths"
want_eq "(bb) ... and nothing was merged into your checkout" "$(git rev-parse HEAD)" "$head_before"

# --- (bc) loom loop works on a fresh task ---------------------------------
# The pre-implement check was security_base, which ALSO refuses a branch with
# nothing past its branch point — the ordinary state of the task `loom loop`
# exists to implement. So `loom loop <new-task>` died on "nothing to
# review/land" before the implementer ever ran. The record's existence is what
# has to hold there; the history check belongs inside the loop, where there is
# a history.
claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_TEST_VERDICT=APPROVE LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$LOOM" loop 0059-bc 2>&1)"; rc=$?
want_eq     "(bc) loom loop on a fresh task succeeds"     "$rc" "0"
want_not_in "(bc) ... not 'nothing to review'"            "$out" "nothing to review/land"
want_ne     "(bc) ... the implementer really ran"         \
            "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$claude_before"
want_in     "(bc) ... and the gate went green"            "$out" "gate green"
want_in     "(bc) ... and a review round followed it"     "$out" "[loop] review round 1"
want_in     "(bc) ... ending in the reviewer's verdict"   "$out" "APPROVE after 1 round(s)"
want_file   "(bc) ... with the review on disk"            "$WTU/0059-bc/.agents/reviews/0059-bc-review.md"

# --- (bd) a landed loom.env cannot re-aim git itself ----------------------
# `.agents/loom.env` is `.`-sourced as shell under `set -a`, so a single
# `GIT_DIR=` line there exports it into every git subprocess loom runs: the
# `git rev-parse HEAD` that becomes the recorded base, the `git worktree add`,
# the merge. It is cleared once both env files have been read.
git init -q "$TMP/decoy-bd"
(
  cd "$TMP/decoy-bd" || exit 1
  git symbolic-ref HEAD refs/heads/main
  git config user.email test@example.invalid
  git config user.name  "fence test"
  echo "not your repo" > decoy.txt
  git add -A
  git commit -qm "the decoy's own history"
)
bd_real="$(git rev-parse HEAD)"
bd_decoy="$(git -C "$TMP/decoy-bd" rev-parse HEAD)"
want_ne "(bd) setup: the decoy has a history of its own" "$bd_decoy" "$bd_real"
printf 'GIT_DIR=%s\n' "$TMP/decoy-bd/.git" > .agents/loom.env
out="$("$LOOM" new 0060-bd 2>&1)"; rc=$?
rm -f .agents/loom.env
want_eq     "(bd) loom new still cuts from the real repo"  "$rc" "0"
want_eq     "(bd) ... and records the REAL checkout's HEAD" "$(state_field 0060-bd base)" "$bd_real"
want_ne     "(bd) ... never the decoy's"                    "$(state_field 0060-bd base)" "$bd_decoy"
want_file   "(bd) ... and the worktree is a worktree of the real repo" "$WTU/0060-bd/backend/main.go"
want_absent "(bd) ... not of the decoy"                     "$WTU/0060-bd/decoy.txt"

# --- (be) a directory that is not a checkout is a refusal, not "nothing" ---
# A submodule's git dir lives at <superproject>/.git/modules/<name>, so
# `--git-common-dir` from inside one made $ROOT `<superproject>/.git/modules`:
# no .agents, no zones, every path "assist", every guard green.
git -c protocol.file.allow=always submodule add -q "$TMP/decoy-bd" sub 2>/dev/null
if [ -e "$REPO/sub/.git" ]; then
  out="$(cd "$REPO/sub" && "$LOOM" zone core/x 2>&1)"; rc=$?
  want_eq     "(be) loom refuses to run inside a submodule"  "$rc" "1"
  want_in     "(be) ... naming the .git directory it landed in" "$out" ".git"
  want_not_in "(be) ... rather than answering 'assist'"      "$out" "→ assist"
  git rm -q -f sub
  git submodule deinit -q -f sub 2>/dev/null || true
  rm -rf "$REPO/.git/modules/sub" "$REPO/sub"
  git commit -qm "drop the submodule" 2>/dev/null || git reset -q --hard
else
  bad "(be) setup: could not add a submodule to the test repo"
fi
# ... and a checkout with no .agents/ at all is the same refusal.
mkdir -p "$TMP/bare-repo"
(
  cd "$TMP/bare-repo" || exit 1
  git init -q .
  git config user.email test@example.invalid
  git config user.name  "fence test"
  echo hi > f.txt
  git add -A
  git commit -qm init
)
out="$(cd "$TMP/bare-repo" && "$LOOM" zone f.txt 2>&1)"; rc=$?
want_eq     "(be) a repo with no .agents/ is refused too"  "$rc" "1"
want_in     "(be) ... saying what is missing"              "$out" "no .agents directory"
want_not_in "(be) ... rather than answering 'assist'"      "$out" "→ assist"

# --- (bf) landing deletes the branch only if it is still what was merged ---
# `loom land` merges $PINNED_TIP — the reviewed sha — and then deleted the
# branch by NAME. The ref lives in the shared .git, so between the
# reviewed-tip check and that deletion it can say something else: whatever else
# is on it has never been reviewed, and `git branch -d` on a merged ref would
# throw it away without a word (or, unmerged, abort the command after the merge
# had already happened).
out="$("$LOOM" new 0062-bf 2>&1)"; rc=$?
want_eq "(bf) setup: an unprofiled worktree"              "$rc" "0"
BFW="$WTU/0062-bf"
echo "benign" > "$BFW/backend/bf.txt"
git -C "$BFW" add backend/bf.txt
git -C "$BFW" commit -qm "the work that gets reviewed"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0062-bf 2>&1)"; rc=$?
want_eq "(bf) setup: it is reviewed"                      "$rc" "0"
bf_tip="$(git rev-parse agent/0062-bf)"
bf_moved="$(git rev-parse main)"
# The operator's gate runs between the reviewed-tip check and the merge, and
# the branch ref is one `git update-ref` from anywhere while it does.
cp .agents/gate.sh "$TMP/gate.bf"
cat > .agents/gate.sh << GATE
#!/usr/bin/env bash
git update-ref refs/heads/agent/0062-bf $bf_moved
exit 0
GATE
chmod +x .agents/gate.sh
head_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0062-bf 2>&1)"; rc=$?
cp "$TMP/gate.bf" .agents/gate.sh
want_eq "(bf) the merge of the reviewed sha still succeeds" "$rc" "0"
want_ne "(bf) ... the merge really happened"              "$(git rev-parse HEAD)" "$head_before"
want_eq "(bf) ... and it carried the REVIEWED sha"        "$(git rev-parse HEAD^2)" "$bf_tip"
want_ne "(bf) ... the branch that moved is NOT deleted"   "$(sha_of agent/0062-bf)" "GONE"
want_in "(bf) ... and loom says why it kept it"           "$out" "moved after the review"
want_in "(bf) ... naming both shas"                       "$out" "$bf_tip"
git branch -D agent/0062-bf > /dev/null 2>&1 || true

# ==========================================================================
# ROUND-7 fixes. Every case below FAILS against the pre-fix bin/loom (7da0cc4).
#
# The theme: the things that are still WRITABLE from a worktree once the refs
# and the record are locked down. `.git/config` is shared, and several of its
# keys name a PROGRAM git runs — including where a push goes. And round 6's own
# blanket `unset GIT_*` took away the temporary index git hands a pre-commit
# hook, which silently disarmed the hand-zone guard for `git commit -a`.
# ==========================================================================

# --- (bg) the guard reads the index git HANDS it -------------------------
# `git commit -a`, `git commit -- <path>`, `--only` and `--include` do not
# touch the standard index: git builds a TEMPORARY one for the commit and
# names it in $GIT_INDEX_FILE for the hook. Round 6 unset that variable along
# with GIT_DIR and friends once both env files had been sourced, so
# `cmd_guard`'s `git diff --cached --name-only` read the standard index,
# found nothing staged, and exited 0 — printing nothing at all. The commit went
# through.
ln -sf "$LOOM" "$TMP/stubs/loom"          # the hook calls `loom guard` by name
out="$("$LOOM" install-hooks 2>&1)"; rc=$?
want_eq "(bg) setup: the pre-commit hook installs"        "$rc" "0"
want_file "(bg) ... at .git/hooks/pre-commit"             "$REPO/.git/hooks/pre-commit"
git checkout -q -b agent/guard-bg
bg_head="$(git rev-parse HEAD)"
echo "// the agent edits a hand path" >> core/lib.rs
# 1. `git commit -a`: nothing is staged, the content lives only in git's own
#    temporary index.
out="$(git commit -a -m "sneak a hand path past the guard" 2>&1)"; rc=$?
want_fail   "(bg) 'git commit -a' on a hand path is BLOCKED"  "$rc"
want_in     "(bg) ... by the guard, naming the path"          "$out" "core/lib.rs"
want_in     "(bg) ... with the guard's own message"           "$out" "touches hand-zone paths"
want_eq     "(bg) ... and nothing was committed"              "$(git rev-parse HEAD)" "$bg_head"
# 2. `git commit -- <path>`: same temporary index, by a different route.
out="$(git commit -m "sneak it in path-limited" -- core/lib.rs 2>&1)"; rc=$?
want_fail   "(bg) 'git commit -- <hand path>' is BLOCKED too" "$rc"
want_in     "(bg) ... naming the path"                        "$out" "core/lib.rs"
want_eq     "(bg) ... and still nothing committed"            "$(git rev-parse HEAD)" "$bg_head"
# 3. the control: an ordinary staged commit was blocked before this fix and
#    must still be.
git add core/lib.rs
out="$(git commit -m "the staged form" 2>&1)"; rc=$?
want_fail   "(bg) control: a staged hand-zone commit is blocked" "$rc"
want_in     "(bg) ... naming the path"                        "$out" "core/lib.rs"
want_eq     "(bg) ... and nothing was committed"              "$(git rev-parse HEAD)" "$bg_head"
# 4. ... and an assist-zone path still commits, so the guard is not simply
#    refusing everything now.
git reset -q --hard
echo "ordinary work" > backend/bg-ok.txt
git add backend/bg-ok.txt
out="$(git commit -m "an assist-zone commit" 2>&1)"; rc=$?
want_eq     "(bg) an assist-zone commit still goes through"   "$rc" "0"
want_ne     "(bg) ... and really committed"                   "$(git rev-parse HEAD)" "$bg_head"
git reset -q --hard "$bg_head"
git checkout -q main
git branch -D agent/guard-bg > /dev/null 2>&1 || true
rm -f "$REPO/.git/hooks/pre-commit" "$TMP/stubs/loom"

# --- (bh) the PUSH destination is pinned, not just the fetch URL ----------
# `git remote get-url origin` answers the FETCH url. A push goes somewhere
# else the moment `remote.origin.pushurl` is set, or a
# `url.<decoy>.pushInsteadOf = <the real origin>` rewrite exists — both in the
# shared .git/config, both invisible to the URL the record pinned, and
# `loom land --pr` is the one command here that publishes an agent's commits to
# a host.
git init -q --bare "$TMP/origin-bh.git"
git init -q --bare "$TMP/decoy-bh.git"
git remote add origin "$TMP/origin-bh.git"
git push -q origin main
out="$("$LOOM" new 0063-bh 2>&1)"; rc=$?
want_eq "(bh) setup: a task cut against a real origin"    "$rc" "0"
want_eq "(bh) ... with the PUSH url in the operator record" \
        "$(state_field 0063-bh pushurl)" "$TMP/origin-bh.git"
BHW="$WTU/0063-bh"
echo "benign" > "$BHW/backend/bh.txt"
git -C "$BHW" add backend/bh.txt
git -C "$BHW" commit -qm "benign work on bh"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0063-bh 2>&1)"; rc=$?
want_eq "(bh) setup: it is reviewed"                      "$rc" "0"
bh_refs() { git -C "$1" for-each-ref --format='%(refname)' | grep -c . || true; }
# 1. remote.origin.pushurl, set from inside the worktree
git -C "$BHW" config remote.origin.pushurl "$TMP/decoy-bh.git"
out="$("$LOOM" land 0063-bh --pr 2>&1)"; rc=$?
want_eq "(bh) land --pr refuses a re-aimed remote.origin.pushurl" "$rc" "1"
want_in "(bh) ... naming the push url"                    "$out" "PUSH url"
want_in "(bh) ... and the decoy configured now"           "$out" "decoy-bh.git"
want_eq "(bh) ... and the decoy received no refs"         "$(bh_refs "$TMP/decoy-bh.git")" "0"
git config --unset remote.origin.pushurl
# 2. url.<decoy>.pushInsteadOf: the same redirection with the pushurl key
#    never set, and `git remote get-url origin` still answering the real one.
git config "url.$TMP/decoy-bh.git.pushInsteadOf" "$TMP/origin-bh.git"
want_eq "(bh) setup: the FETCH url still reads as the real origin" \
        "$(git remote get-url origin)" "$TMP/origin-bh.git"
out="$("$LOOM" land 0063-bh --pr 2>&1)"; rc=$?
want_eq "(bh) land --pr refuses a pushInsteadOf rewrite"  "$rc" "1"
want_in "(bh) ... naming the decoy it would have gone to" "$out" "decoy-bh.git"
want_eq "(bh) ... which received no refs either"          "$(bh_refs "$TMP/decoy-bh.git")" "0"
git config --remove-section "url.$TMP/decoy-bh.git"
# 3. ext::<program> — refused before any transport is opened, so the program
#    named in the URL never runs.
cat > "$TMP/bh-ext.sh" << EXT
#!/usr/bin/env bash
: > "$TMP/bh-ext-ran"
exit 1
EXT
chmod +x "$TMP/bh-ext.sh"
git config remote.origin.pushurl "ext::$TMP/bh-ext.sh"
out="$("$LOOM" land 0063-bh --pr 2>&1)"; rc=$?
want_eq     "(bh) land --pr refuses an ext:: push url"    "$rc" "1"
want_in     "(bh) ... naming it"                          "$out" "ext::"
want_absent "(bh) ... and the program it names never ran" "$TMP/bh-ext-ran"
git config --unset remote.origin.pushurl
# ... and with the recorded push url back, the push really happens
out="$("$LOOM" land 0063-bh --pr 2>&1)"; rc=$?
want_eq "(bh) with the recorded push url back, land --pr pushes" "$rc" "0"
want_ne "(bh) ... and origin now carries the branch" \
        "$(git -C "$TMP/origin-bh.git" rev-parse --verify --quiet refs/heads/agent/0063-bh || echo GONE)" "GONE"
"$LOOM" drop 0063-bh > /dev/null 2>&1 || true
git remote remove origin

# --- (bi) repo-local git config is not a code channel --------------------
# `.git/config` is in the SHARED git directory, so `git -C <worktree> config
# core.pager /tmp/x` is one command from inside an agent's tree — and several
# of those keys name a PROGRAM git runs, in YOUR session, the next time loom
# touches the repository. loom exports its own GIT_CONFIG_PARAMETERS (which
# outranks every config file) and spells out --no-ext-diff / --receive-pack /
# --upload-pack where a config value would otherwise win.
git init -q --bare "$TMP/origin-bi.git"
git remote add origin "$TMP/origin-bi.git"
git push -q origin main
for n in pager fsmonitor extdiff; do
  cat > "$TMP/bi-$n.sh" << BI
#!/usr/bin/env bash
: > "$TMP/bi-$n-ran"
BI
done
printf 'exec cat\n' >> "$TMP/bi-pager.sh"
printf 'echo /\n'   >> "$TMP/bi-fsmonitor.sh"     # fsmonitor v1: "everything is dirty"
printf 'exit 0\n'   >> "$TMP/bi-extdiff.sh"
cat > "$TMP/bi-receivepack.sh" << BI
#!/usr/bin/env bash
: > "$TMP/bi-receivepack-ran"
exec git receive-pack "\$@"
BI
chmod +x "$TMP/bi-pager.sh" "$TMP/bi-fsmonitor.sh" "$TMP/bi-extdiff.sh" "$TMP/bi-receivepack.sh"
out="$("$LOOM" new 0064-bi 2>&1)"; rc=$?
want_eq "(bi) setup: a task against a real origin"        "$rc" "0"
BIW="$WTU/0064-bi"
echo "benign" > "$BIW/backend/bi.txt"
git -C "$BIW" add backend/bi.txt
git -C "$BIW" commit -qm "benign work on bi"
# the agent, from its worktree, into the shared config
git -C "$BIW" config core.pager                "$TMP/bi-pager.sh"
git -C "$BIW" config core.fsmonitor            "$TMP/bi-fsmonitor.sh"
git -C "$BIW" config diff.external             "$TMP/bi-extdiff.sh"
git -C "$BIW" config remote.origin.receivepack "$TMP/bi-receivepack.sh"
# the OPERATOR's gate, which loom runs with its own environment: it reports what
# every git subprocess loom spawns actually resolves these keys to.
cp .agents/gate.sh "$TMP/gate.bi"
cat > .agents/gate.sh << 'GATE'
#!/usr/bin/env bash
{ printf 'pager=%s\n'     "$(git config --get core.pager || true)"
  printf 'fsmonitor=%s\n' "$(git config --get core.fsmonitor || true)"
  printf 'extallow=%s\n'  "$(git config --get protocol.ext.allow || true)"
  printf 'editor=%s\n'    "$(git config --get core.editor || true)"
} > "${LOOM_TEST_TMP:?}/bi-gate-config.txt"
exit 0
GATE
chmod +x .agents/gate.sh
# Planting those four keys IS the change the config pin exists for, so the pin
# refuses first and names them. This case is about what happens once the
# operator has read them and re-pinned: every one of those programs must still
# be inert, because GIT_CONFIG_PARAMETERS and the spelled-out flags do not
# depend on the config being unchanged.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0064-bi 2>&1)"; rc=$?
want_eq "(bi) the config pin refuses the planted keys"    "$rc" "1"
want_in "(bi) ... naming one of them"                     "$out" "core.fsmonitor="
want_absent "(bi) ... before any of them could run"       "$TMP/bi-fsmonitor-ran"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0064-bi --accept-config 2>&1)"; rc=$?
want_eq "(bi) loom check still succeeds"                  "$rc" "0"
out="$("$LOOM" diff 0064-bi 2>&1)"; rc=$?
want_eq "(bi) loom diff still succeeds"                   "$rc" "0"
want_in "(bi) ... and really shows the patch"             "$out" "backend/bi.txt"
out="$("$LOOM" land 0064-bi --pr 2>&1)"; rc=$?
cp "$TMP/gate.bi" .agents/gate.sh
want_eq "(bi) land --pr succeeds against the recorded origin" "$rc" "0"
want_absent "(bi) core.fsmonitor never ran"               "$TMP/bi-fsmonitor-ran"
want_absent "(bi) diff.external never ran"                "$TMP/bi-extdiff-ran"
want_absent "(bi) core.pager never ran"                   "$TMP/bi-pager-ran"
want_absent "(bi) remote.origin.receivepack never ran"    "$TMP/bi-receivepack-ran"
want_ne "(bi) ... and the push really happened" \
        "$(git -C "$TMP/origin-bi.git" rev-parse --verify --quiet refs/heads/agent/0064-bi || echo GONE)" "GONE"
bi_cfg="$(cat "$TMP/bi-gate-config.txt" 2>/dev/null || true)"
want_in "(bi) every git subprocess loom spawns sees core.pager=cat"  "$bi_cfg" "pager=cat"
want_in "(bi) ... core.fsmonitor=false"                   "$bi_cfg" "fsmonitor=false"
want_in "(bi) ... protocol.ext.allow=never"               "$bi_cfg" "extallow=never"
want_in "(bi) ... core.editor=true"                       "$bi_cfg" "editor=true"
"$LOOM" drop 0064-bi > /dev/null 2>&1 || true
git config --unset core.pager
git config --unset core.fsmonitor
git config --unset diff.external
git config --unset remote.origin.receivepack
git remote remove origin

# --- (bj) what a rebase may replay onto, and what it may bury ------------
# Two rules, and they are the same rule twice: a rebase MOVES the recorded base,
# so loom must be able to refresh what it replays onto, and the operator must
# have seen what goes under.
out="$("$LOOM" new 0065-bj 2>&1)"; rc=$?
want_eq "(bj) setup: an unprofiled worktree"              "$rc" "0"
BJW="$WTU/0065-bj"
echo "benign" > "$BJW/backend/bj.txt"
git -C "$BJW" add backend/bj.txt
git -C "$BJW" commit -qm "the task's own work"
bj_base_before="$(state_field 0065-bj base)"
bj_tip_before="$(git rev-parse agent/0065-bj)"
# an upstream commit in the ASSIST zone only: nothing fenced, nothing in [hand].
# The old gate was "the range touches a fenced or hand-zone path", so this range
# moved the base in silence.
echo "assist only" > backend/bj-upstream.txt
git add backend/bj-upstream.txt
git commit -qm "upstream: an assist-zone commit"
bj_up="$(git rev-parse HEAD)"
out="$("$LOOM" rebase 0065-bj main 2>&1)"; rc=$?
want_eq "(bj) an assist-only buried range is refused without the flag" "$rc" "1"
want_in "(bj) ... printing the commits it would bury"     "$out" "upstream: an assist-zone commit"
want_in "(bj) ... with the fenced list"                   "$out" "fenced paths:"
want_in "(bj) ... the hand-zone list"                     "$out" "hand-zone paths:"
want_in "(bj) ... both empty"                             "$out" "(none)"
want_in "(bj) ... and every path in the range"            "$out" "backend/bj-upstream.txt"
want_in "(bj) ... naming the one escape"                  "$out" "--accept-upstream"
want_eq "(bj) ... the base did not move"                  "$(state_field 0065-bj base)" "$bj_base_before"
want_eq "(bj) ... and the branch is back where it was"    "$(git rev-parse agent/0065-bj)" "$bj_tip_before"
out="$("$LOOM" rebase 0065-bj main --accept-upstream 2>&1)"; rc=$?
want_eq "(bj) ... and proceeds with the flag"             "$rc" "0"
want_eq "(bj) ... moving the base onto main's tip"        "$(state_field 0065-bj base)" "$bj_up"
want_in "(bj) ... saying the range was accepted unreviewed" "$out" "accepted under the base, unreviewed"
# an upstream on a remote loom cannot refresh: only origin/<b> gets a refspec,
# so `upstream/main` was replayed onto whatever refs/remotes/upstream/main said.
git remote add upstream "$TMP/origin-bh.git"
git update-ref refs/remotes/upstream/main "$bj_up"
out="$("$LOOM" rebase 0065-bj upstream/main 2>&1)"; rc=$?
want_eq "(bj) an upstream on another remote is refused"   "$rc" "1"
want_in "(bj) ... naming the rule"                        "$out" "only origin/<b> or a local branch"
want_in "(bj) ... and the remote it cannot refresh"       "$out" "cannot refresh 'upstream'"
want_eq "(bj) ... with the base left alone"               "$(state_field 0065-bj base)" "$bj_up"
git remote remove upstream
git update-ref -d refs/remotes/upstream/main 2>/dev/null || true
# ... and origin/<b> in a repo that has no origin at all: refs/remotes/origin/main
# is then a purely local ref, refreshed by nothing, one update-ref from anything.
out="$("$LOOM" rebase 0065-bj origin/main 2>&1)"; rc=$?
want_eq "(bj) origin/<b> with no 'origin' remote is refused" "$rc" "1"
want_in "(bj) ... saying the repository has none"         "$out" "this repository has none"
want_in "(bj) ... and what it would have replayed onto"   "$out" "refs/remotes/origin/main"
want_eq "(bj) ... with the base left alone"               "$(state_field 0065-bj base)" "$bj_up"
"$LOOM" drop 0065-bj > /dev/null 2>&1 || true

# ==========================================================================
# ROUND-8 fixes. Every case below FAILS against the pre-fix bin/loom (97af9b6).
#
# The theme: the two things left in `.git/config` and in a ref NAME. The config
# keys that matter cannot be enumerated in advance, because the attack is in the
# KEY (`filter.<anything>`, `pager.<anything>`, `includeIf.<anything>`) — so the
# whole local config is pinned instead. And `origin/main` is not a ref, it is a
# lookup, and the lookup order puts a forgery first.
# ==========================================================================

# --- (bk) the repository's LOCAL git config is pinned to the task ---------
# `.git/config` is in the SHARED git directory, so `git -C <worktree> config
# <anything> <anything>` is one command from inside an agent's tree. Several of
# those keys name a PROGRAM git runs in your session, and two of them —
# `credential.helper` and `core.askPass` — are HANDED YOUR CREDENTIAL as well as
# executed. The digest of the whole local config is recorded at `loom new` and
# re-checked before every model launch, fetch, push, merge, replay and review
# patch; `--accept-config` is the only escape.
git init -q --bare "$TMP/origin-bk.git"
git remote add origin "$TMP/origin-bk.git"
git push -q origin main
out="$("$LOOM" new 0066-bk 2>&1)"; rc=$?
want_eq   "(bk) setup: a task against a real origin"      "$rc" "0"
want_ne   "(bk) ... with the local config pinned in the record" "$(state_field 0066-bk config)" ""
want_file "(bk) ... and the full list beside it, for the diff" "$(state_of 0066-bk).gitconfig"
BKW="$WTU/0066-bk"
echo "benign" > "$BKW/backend/bk.txt"
git -C "$BKW" add backend/bk.txt
git -C "$BKW" commit -qm "benign work on bk"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0066-bk 2>&1)"; rc=$?
want_eq "(bk) setup: it is reviewed"                      "$rc" "0"
cat > "$TMP/bk-cred.sh" << CRED
#!/usr/bin/env bash
: > "$TMP/bk-cred-ran"
exit 0
CRED
chmod +x "$TMP/bk-cred.sh"
# 1. credential.helper, set from inside the worktree. `!<command>` is a shell,
#    and git also hands it the credential to store.
git -C "$BKW" config credential.helper "!$TMP/bk-cred.sh"
out="$("$LOOM" land 0066-bk --pr 2>&1)"; rc=$?
want_eq     "(bk) land --pr refuses a credential.helper planted from the worktree" "$rc" "1"
want_in     "(bk) ... naming the key that appeared"       "$out" "+ credential.helper="
want_in     "(bk) ... and saying which task it is not the config of" \
            "$out" "not the one task 0066-bk was created against"
want_in     "(bk) ... with the one escape"                "$out" "--accept-config"
want_absent "(bk) ... refused before any transport: the helper never ran" "$TMP/bk-cred-ran"
want_eq     "(bk) ... and origin received nothing" \
            "$(git -C "$TMP/origin-bk.git" rev-parse --verify --quiet refs/heads/agent/0066-bk || echo GONE)" "GONE"
git config --unset credential.helper
# 2. core.askPass, the same way.
git -C "$BKW" config core.askPass "$TMP/bk-cred.sh"
out="$("$LOOM" land 0066-bk --pr 2>&1)"; rc=$?
want_eq     "(bk) land --pr refuses a core.askPass too"   "$rc" "1"
# git lower-cases the variable name in `--list`, so the pinned list says
# `core.askpass` however it was written.
want_in     "(bk) ... naming it"                          "$out" "+ core.askpass="
want_absent "(bk) ... which never ran either"             "$TMP/bk-cred-ran"
want_eq     "(bk) ... and origin still received nothing" \
            "$(git -C "$TMP/origin-bk.git" rev-parse --verify --quiet refs/heads/agent/0066-bk || echo GONE)" "GONE"
git config --unset core.askPass
# 3. ... and with the config back where the record pinned it, the push happens.
out="$("$LOOM" land 0066-bk --pr 2>&1)"; rc=$?
want_eq "(bk) with the config back, land --pr pushes"     "$rc" "0"
want_ne "(bk) ... and origin now carries the branch" \
        "$(git -C "$TMP/origin-bk.git" rev-parse --verify --quiet refs/heads/agent/0066-bk || echo GONE)" "GONE"
"$LOOM" drop 0066-bk > /dev/null 2>&1 || true

# 4. a filter driver planted AFTER `loom new`: `loom run` refuses before the
#    model, not after it. filter.<d>.clean is the shape that cannot be pinned
#    key by key — the driver name is the agent's to choose.
out="$("$LOOM" new 0067-bk2 2>&1)"; rc=$?
want_eq "(bk) setup: a second task"                       "$rc" "0"
BK2W="$WTU/0067-bk2"
git -C "$BK2W" config filter.x.clean "$TMP/bk-cred.sh"
bk_claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0067-bk2 2>&1)"; rc=$?
want_eq     "(bk) loom run refuses a filter driver planted after loom new" "$rc" "1"
want_in     "(bk) ... naming it"                          "$out" "+ filter.x.clean="
want_not_in "(bk) ... before the model, not after"        "$out" "running on"
want_eq     "(bk) ... so no model was launched" \
            "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$bk_claude_before"
# 5. --accept-config prints the diff and proceeds, and what it re-records is
#    the new baseline.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0067-bk2 --accept-config 2>&1)"; rc=$?
want_eq "(bk) --accept-config proceeds"                   "$rc" "0"
want_in "(bk) ... printing what changed"                  "$out" "+ filter.x.clean="
want_in "(bk) ... saying it is re-recorded, and by whom"  "$out" "re-recording it as the baseline"
want_in "(bk) ... and the model really ran"               "$out" "gate green"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0067-bk2 2>&1)"; rc=$?
want_eq "(bk) the re-recorded config is the new baseline, no flag needed" "$rc" "0"
"$LOOM" drop 0067-bk2 > /dev/null 2>&1 || true
git config --unset filter.x.clean

# 6. a record with no `config=` at all — the shape a pre-pin `loom` wrote. There
#    is nothing to compare against, so it is a refusal, and --accept-config is
#    NOT an escape from it: re-recording would pin whatever is there now and
#    call it the baseline the operator chose.
out="$("$LOOM" new 0068-bk3 2>&1)"; rc=$?
want_eq "(bk) setup: a third task"                        "$rc" "0"
BK3W="$WTU/0068-bk3"
echo "benign" > "$BK3W/backend/bk3.txt"
git -C "$BK3W" add backend/bk3.txt
git -C "$BK3W" commit -qm "benign work on bk3"
sedi '/^config=/d' "$(state_of 0068-bk3)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0068-bk3 2>&1)"; rc=$?
want_eq     "(bk) a record with no config= is refused"    "$rc" "1"
want_in     "(bk) ... saying there is nothing to compare against" "$out" "pins no git config"
want_in     "(bk) ... with the recreate instruction"      "$out" "loom drop 0068-bk3 && loom new 0068-bk3"
want_not_in "(bk) ... and no reviewer was launched"       "$out" "running on"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0068-bk3 --accept-config 2>&1)"; rc=$?
want_eq "(bk) ... and --accept-config does not paper over a MISSING pin" "$rc" "1"
want_in "(bk) ... for the same reason"                    "$out" "pins no git config"
"$LOOM" drop 0068-bk3 > /dev/null 2>&1 || true
# 7. `loom new` is the command that pins, so it has nothing to accept — and
#    swallowing the flag would read as "the config was re-pinned".
out="$("$LOOM" new 0069-bk4 --accept-config 2>&1)"; rc=$?
want_eq     "(bk) loom new refuses --accept-config"       "$rc" "1"
want_in     "(bk) ... because it is the command that pins" "$out" "this command is the one that pins it"
want_absent "(bk) ... and created nothing"                "$WTU/0069-bk4"
want_absent "(bk) ... not a record either"                "$(state_of 0069-bk4)"
git remote remove origin

# --- (bl) a rebase resolves its refs; it does not look them up ------------
# `origin/main` and `main` are not ref names, they are things git RESOLVES, and
# the order (gitrevisions) is refs/<n> > refs/tags/<n> > refs/heads/<n> >
# refs/remotes/<n>. So a local branch literally named "origin/main", a
# `refs/origin/main`, and a TAG named "main" each answer before the ref
# `loom rebase` fetched and means — and each is one `git update-ref` from inside
# a worktree, which is where they are planted from here.
git init -q --bare "$TMP/origin-bl.git"
git remote add origin "$TMP/origin-bl.git"
git push -q origin main
out="$("$LOOM" new 0070-bl 2>&1)"; rc=$?
want_eq "(bl) setup: a task against a real origin"        "$rc" "0"
BLW="$WTU/0070-bl"
echo "benign" > "$BLW/backend/bl.txt"
git -C "$BLW" add backend/bl.txt
git -C "$BLW" commit -qm "the task's own work"
bl_tip="$(git rev-parse agent/0070-bl)"
echo "upstream" > backend/bl-upstream.txt        # what the REAL origin/main has
git add backend/bl-upstream.txt
git commit -qm "upstream: the real main moved for bl"
bl_up="$(git rev-parse HEAD)"
git push -q origin main
# the three forgeries, all at the branch's own tip: burying the branch's own
# work under its own base is what a hijacked `origin/main` buys.
git -C "$BLW" update-ref refs/heads/origin/main "$bl_tip"
git -C "$BLW" update-ref refs/origin/main       "$bl_tip"
git -C "$BLW" update-ref refs/tags/origin/main  "$bl_tip"
out="$("$LOOM" rebase 0070-bl origin/main --accept-upstream 2>&1)"; rc=$?
want_eq     "(bl) the rebase replays onto the REAL refs/remotes/origin/main" "$rc" "0"
want_eq     "(bl) ... so the recorded base is the real upstream tip" \
            "$(state_field 0070-bl base)" "$bl_up"
want_ne     "(bl) ... never the branch's own tip"         "$(state_field 0070-bl base)" "$bl_tip"
want_not_in "(bl) ... and git never had to pick"          "$out" "is ambiguous"
want_in     "(bl) the branch's own work is still ABOVE the base" \
            "$(git diff --name-only "$(state_field 0070-bl base)" refs/heads/agent/0070-bl)" "backend/bl.txt"
git update-ref -d refs/heads/origin/main 2>/dev/null || true
git update-ref -d refs/origin/main       2>/dev/null || true
git update-ref -d refs/tags/origin/main  2>/dev/null || true
"$LOOM" drop 0070-bl > /dev/null 2>&1 || true
# ... and the LOCAL-branch leg, where a TAG named `main` outranks the branch
# `main` that the `show-ref --verify refs/heads/main` guard just proved exists.
out="$("$LOOM" new 0071-bl2 2>&1)"; rc=$?
want_eq "(bl) setup: a second task"                       "$rc" "0"
BL2W="$WTU/0071-bl2"
echo "benign" > "$BL2W/backend/bl2.txt"
git -C "$BL2W" add backend/bl2.txt
git -C "$BL2W" commit -qm "the task's own work on bl2"
bl2_tip="$(git rev-parse agent/0071-bl2)"
echo "assist only" > backend/bl2-upstream.txt
git add backend/bl2-upstream.txt
git commit -qm "upstream: the local main moved for bl2"
bl2_up="$(git rev-parse refs/heads/main)"
git -C "$BL2W" update-ref refs/tags/main "$bl2_tip"       # the forgery
out="$("$LOOM" rebase 0071-bl2 main --accept-upstream 2>&1)"; rc=$?
want_eq     "(bl) the local leg replays onto refs/heads/main" "$rc" "0"
want_eq     "(bl) ... so the base is the local BRANCH's tip"  "$(state_field 0071-bl2 base)" "$bl2_up"
want_ne     "(bl) ... not the tag's"                      "$(state_field 0071-bl2 base)" "$bl2_tip"
want_not_in "(bl) ... and git never had to pick here either" "$out" "is ambiguous"
git update-ref -d refs/tags/main 2>/dev/null || true
"$LOOM" drop 0071-bl2 > /dev/null 2>&1 || true
git remote remove origin

# ==========================================================================
# ROUND-9 fixes. Every case below FAILS against the pre-fix bin/loom (428c664).
#
# The theme: `git config --local --list` is not the whole of what git reads.
# Two entire SCOPES sit outside it — the MAIN checkout's `config.worktree` and
# each linked worktree's own — and an `include.path` in any of them is a
# POINTER whose target the listings never show. And the pin was read one line
# too late: `fence_apply` updates the working tree, and a working-tree update
# runs smudge filters.
# ==========================================================================

# --- (bm) the WORKTREE scopes are pinned too -----------------------------
# git reads `$GIT_COMMON_DIR/config.worktree` (the MAIN checkout's own scope)
# and `$GIT_COMMON_DIR/worktrees/<wt>/config.worktree` (each linked worktree's)
# whenever `extensions.worktreeConfig` is enabled — which loom's own
# `git sparse-checkout init` enables, on the first `loom new` in a repository.
# `git config --local --list` never shows a key from either. So every key the
# pin exists for is settable from inside the agent's tree with one
# `git config --worktree`, invisibly to the old pin — and a `core.hooksPath` in
# the MAIN scope runs in YOUR checkout, during `loom land`'s merge.
git init -q --bare "$TMP/origin-bm.git"
git remote add origin "$TMP/origin-bm.git"
git push -q origin main
mkdir -p "$TMP/bm-hooks"
cat > "$TMP/bm-hooks/pre-commit" << HOOK
#!/usr/bin/env bash
: > "$TMP/bm-hook-ran"
exit 0
HOOK
cat > "$TMP/bm-prog.sh" << PROG
#!/usr/bin/env bash
: > "$TMP/bm-prog-ran"
exit 0
PROG
chmod +x "$TMP/bm-hooks/pre-commit" "$TMP/bm-prog.sh"
out="$("$LOOM" new 0072-bm 2>&1)"; rc=$?
want_eq "(bm) setup: a task against a real origin"        "$rc" "0"
want_in "(bm) ... and loom new says what it pinned"       "$out" "loom: pinned "
want_in "(bm) ... counting the worktree scopes of it"     "$out" "worktree config entries"
BMW="$WTU/0072-bm"
echo "benign" > "$BMW/backend/bm.txt"
git -C "$BMW" add backend/bm.txt
git -C "$BMW" commit -qm "benign work on bm"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0072-bm 2>&1)"; rc=$?
want_eq "(bm) setup: it is reviewed"                      "$rc" "0"
# 1. core.hooksPath, set at --worktree scope from inside the agent's worktree.
#    `loom run` commits when the gate is green, so the hook is one step away.
git -C "$BMW" config --worktree core.hooksPath "$TMP/bm-hooks"
bm_claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0072-bm 2>&1)"; rc=$?
want_eq     "(bm) loom run refuses a core.hooksPath set at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming the key"                     "$out" "+ core.hookspath="
want_in     "(bm) ... and the scope it appeared in"       "$out" "[worktree-task]"
want_absent "(bm) ... before the add/commit, so the hook never ran" "$TMP/bm-hook-ran"
want_not_in "(bm) ... and before the model, not after"    "$out" "running on"
want_eq     "(bm) ... so none was launched" \
            "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$bm_claude_before"
git -C "$BMW" config --worktree --unset core.hooksPath
# 2. credential.helper, the same way: refused before the transport that would
#    hand it your credential.
git -C "$BMW" config --worktree credential.helper "!$TMP/bm-prog.sh"
out="$("$LOOM" land 0072-bm --pr 2>&1)"; rc=$?
want_eq     "(bm) land --pr refuses a credential.helper at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ credential.helper="
want_in     "(bm) ... in the worktree's own scope"        "$out" "[worktree-task]"
want_absent "(bm) ... refused before any transport"       "$TMP/bm-prog-ran"
want_eq     "(bm) ... and origin received nothing" \
            "$(git -C "$TMP/origin-bm.git" rev-parse --verify --quiet refs/heads/agent/0072-bm || echo GONE)" "GONE"
git -C "$BMW" config --worktree --unset credential.helper
# 3. a filter driver AND the attributes file that selects it, both at
#    --worktree scope: the pair that makes `git add` run a program.
printf '* filter=bmf\n' > "$TMP/bm-attrs"
git -C "$BMW" config --worktree filter.bmf.clean       "$TMP/bm-prog.sh"
git -C "$BMW" config --worktree core.attributesFile    "$TMP/bm-attrs"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0072-bm 2>&1)"; rc=$?
want_eq     "(bm) loom run refuses a filter driver at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming the driver"                  "$out" "+ filter.bmf.clean="
want_in     "(bm) ... and the attributes file that selects it" "$out" "+ core.attributesfile="
want_absent "(bm) ... and the filter never ran"           "$TMP/bm-prog-ran"
want_not_in "(bm) ... before the model, not after"        "$out" "running on"
git -C "$BMW" config --worktree --unset filter.bmf.clean
git -C "$BMW" config --worktree --unset core.attributesFile
# 4. (bi)'s and (bk)'s plants, re-run at --worktree scope. Every one of them
#    was invisible to a pin taken over `git config --local --list`.
git -C "$BMW" config --worktree core.fsmonitor "$TMP/bm-prog.sh"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0072-bm 2>&1)"; rc=$?
want_eq     "(bm) loom check refuses a core.fsmonitor at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ core.fsmonitor="
want_absent "(bm) ... which never ran"                    "$TMP/bm-prog-ran"
git -C "$BMW" config --worktree --unset core.fsmonitor
git -C "$BMW" config --worktree core.askPass "$TMP/bm-prog.sh"
out="$("$LOOM" land 0072-bm --pr 2>&1)"; rc=$?
want_eq     "(bm) land --pr refuses a core.askPass at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ core.askpass="
want_absent "(bm) ... which never ran either"             "$TMP/bm-prog-ran"
git -C "$BMW" config --worktree --unset core.askPass
git -C "$BMW" config --worktree diff.external "$TMP/bm-prog.sh"
out="$("$LOOM" diff 0072-bm 2>&1)"; rc=$?
want_eq     "(bm) loom diff refuses a diff.external at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ diff.external="
want_absent "(bm) ... nor did that one run"               "$TMP/bm-prog-ran"
git -C "$BMW" config --worktree --unset diff.external
git -C "$BMW" config --worktree remote.origin.receivepack "$TMP/bm-prog.sh"
out="$("$LOOM" land 0072-bm --pr 2>&1)"; rc=$?
want_eq     "(bm) land --pr refuses a remote.origin.receivepack at --worktree scope" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ remote.origin.receivepack="
git -C "$BMW" config --worktree --unset remote.origin.receivepack
# 5. the MAIN checkout's own scope: `.git/config.worktree`, which no linked
#    worktree reads and `git config --local --list` does not show. A
#    core.hooksPath there runs in YOUR checkout, during the merge.
printf '[core]\n\thooksPath = %s\n' "$TMP/bm-hooks" >> "$REPO/.git/config.worktree"
bm_main_before="$(git rev-parse HEAD)"
out="$("$LOOM" land 0072-bm 2>&1)"; rc=$?
want_eq     "(bm) land refuses a core.hooksPath in the MAIN checkout's config.worktree" "$rc" "1"
want_in     "(bm) ... naming it"                          "$out" "+ core.hookspath="
want_in     "(bm) ... in the main checkout's own scope"   "$out" "[worktree-main]"
want_absent "(bm) ... refused before the merge, so no hook ran" "$TMP/bm-hook-ran"
want_eq     "(bm) ... and your checkout did not move"     "$(git rev-parse HEAD)" "$bm_main_before"
want_ne     "(bm) ... with the branch still standing" \
            "$(git rev-parse --verify --quiet refs/heads/agent/0072-bm || echo GONE)" "GONE"
rm -f "$REPO/.git/config.worktree"
# 6. ... and with every scope back where the record pinned it, the push happens.
out="$("$LOOM" land 0072-bm --pr 2>&1)"; rc=$?
want_eq "(bm) with all three scopes back, land --pr pushes" "$rc" "0"
want_ne "(bm) ... and origin now carries the branch" \
        "$(git -C "$TMP/origin-bm.git" rev-parse --verify --quiet refs/heads/agent/0072-bm || echo GONE)" "GONE"
"$LOOM" drop 0072-bm > /dev/null 2>&1 || true
git remote remove origin

# --- (bn) the include closure is pinned, and `loom new` is loud about it ---
# `git config --local --list` prints `include.path=<file>` and
# `includeIf.<cond>.path=<file>` as POINTERS: the keys of the included file are
# live (they show up in the FULL `git config --list`) and appear in no scoped
# listing at all — measured, git 2.34.1. A pin taken over the listings therefore
# pins the pointer and nothing behind it: plant one benign include while a task
# is created, and every later edit of the TARGET is free. loom resolves the
# closure and digests the target FILES, and says so at `loom new`.
mkdir -p "$TMP/bn" "$TMP/bn-hooks"
cat > "$TMP/bn-hooks/pre-commit" << HOOK
#!/usr/bin/env bash
: > "$TMP/bn-hook-ran"
exit 0
HOOK
chmod +x "$TMP/bn-hooks/pre-commit"
printf '[core]\n\tquotePath = false\n' > "$TMP/bn/inc.cfg"      # benign, for now
git config include.path "$TMP/bn/inc.cfg"                       # planted by task A
# `include.path` names a PROGRAM channel, so the repository baseline has moved
# in a way `loom new` will not adopt on its own (it takes no --accept-config).
# The operator baselines it deliberately first — which is what the refusal says
# to do, and (bs) is the case that proves the refusal.
"$LOOM" pin-config --accept-config > /dev/null 2>&1
out="$("$LOOM" new 0073-bn 2>&1)"; rc=$?
want_eq "(bn) setup: a task created while an include is present" "$rc" "0"
want_in "(bn) loom new prints what it pinned"             "$out" "loom: pinned "
want_in "(bn) ... and WARNs that the config pulls other files in" "$out" "include.path"
want_in "(bn) ... naming the target"                      "$out" "$TMP/bn/inc.cfg"
want_in "(bn) ... which is in the pinned sidecar, digested" \
        "$(tr '\0' '\n' < "$(state_of 0073-bn).gitconfig")" "include:$TMP/bn/inc.cfg:"
# the agent edits the INCLUDED file. Nothing in .git/config changes at all.
printf '[core]\n\thooksPath = %s\n' "$TMP/bn-hooks" >> "$TMP/bn/inc.cfg"
want_eq     "(bn) setup: the include really is live"      "$(git config --get core.hooksPath)" "$TMP/bn-hooks"
want_in     "(bn) ... while the local listing still shows only the pointer" \
            "$(git config --local --list)" "include.path=$TMP/bn/inc.cfg"
want_not_in "(bn) ... and names no hooksPath of its own"  "$(git config --local --list)" "hookspath"
# ... and the keys BEHIND the pointer are named at the moment they are adopted.
# `--list` shows an include as a pointer and never what it brings, so a
# core.hooksPath one directive away from .git/config was pinned in full and
# named nowhere.
out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
want_eq "(bn) pin-config re-records the closure"          "$rc" "0"
want_in "(bn) ... naming the keys INSIDE the included file" \
        "$out" "[include:$TMP/bn/inc.cfg] core.hookspath=$TMP/bn-hooks"
# An include target is a config file, so a big one is either a mistake or a way
# to bloat the sidecar and drown a refusal in it. Past 64 KiB the bytes are not
# stored; the digest, which is what the change check runs on, still is.
cp "$TMP/bn/inc.cfg" "$TMP/bn/inc.cfg.small"
python3 -c 'import sys; sys.stdout.write("# " + "x"*70000 + "\n")' >> "$TMP/bn/inc.cfg"
out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
want_eq "(bn) ... an include target over the cap is still pinned" "$rc" "0"
want_in "(bn) ... by digest and size rather than by content"      "$out" "over the 65536-byte cap"
want_eq "(bn) ... so the sidecar does not grow with it" \
        "$([ "$(wc -c < "$STATE/config.gitconfig")" -lt 65536 ] && echo small || echo BIG)" "small"
mv "$TMP/bn/inc.cfg.small" "$TMP/bn/inc.cfg"
"$LOOM" pin-config --accept-config > /dev/null 2>&1
bn_claude_before="$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0073-bn 2>&1)"; rc=$?
want_eq     "(bn) loom run refuses an edit to the INCLUDED file" "$rc" "1"
want_in     "(bn) ... naming the include by path"         "$out" "include:$TMP/bn/inc.cfg"
want_absent "(bn) ... before the commit, so the hook never fired" "$TMP/bn-hook-ran"
want_eq     "(bn) ... and no model was launched" \
            "$(wc -l < "$TMP/called-claude.log" 2>/dev/null || echo 0)" "$bn_claude_before"
# ... and --accept-config re-records the closure. The hook firing on the commit
# that follows is what proves the plant was live all along.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0073-bn --accept-config 2>&1)"; rc=$?
want_eq   "(bn) --accept-config re-pins the closure and proceeds" "$rc" "0"
want_in   "(bn) ... printing the include line that changed" "$out" "include:$TMP/bn/inc.cfg"
want_file "(bn) ... and the hook the included file named really does fire" "$TMP/bn-hook-ran"
"$LOOM" drop 0073-bn > /dev/null 2>&1 || true
git config --unset include.path
rm -f "$TMP/bn/inc.cfg"
want_eq "(bn) cleanup: the include is gone"               "$(git config --get core.hooksPath || true)" ""

# --- (bo) the config check runs BEFORE the first fence operation ----------
# `fence_reconcile` -> `fence_apply` -> `git sparse-checkout set` is a
# WORKING-TREE UPDATE: git materialises every path the new pattern list admits,
# and materialising one runs the SMUDGE side of whatever `filter.<d>` a
# `.gitattributes` in that worktree selects. The `.gitattributes` is a file the
# agent writes (uncommitted is enough) and `filter.<d>.smudge` is one
# `git config` away — so the planted program ran, as the operator, one line
# before the pin that exists to refuse it.
out="$("$LOOM" new 0074-bo 2>&1)"; rc=$?
want_eq "(bo) setup: a plain worktree"                    "$rc" "0"
BOW="$WTU/0074-bo"
echo "benign" > "$BOW/backend/bo.txt"
git -C "$BOW" add backend/bo.txt
git -C "$BOW" commit -qm "benign work on bo"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0074-bo 2>&1)"; rc=$?
want_eq "(bo) setup: it is reviewed"                      "$rc" "0"
cat > "$TMP/bo-smudge.sh" << SM
#!/usr/bin/env bash
: > "$TMP/bo-smudge-ran"
exec cat
SM
chmod +x "$TMP/bo-smudge.sh"
git -C "$BOW" config filter.evil.smudge "$TMP/bo-smudge.sh"    # the program
printf '* filter=evil\n' > "$BOW/.gitattributes"               # what selects it
# ... and a narrowed sparse spec, so that loom's own `sparse-checkout set` has
# files to MATERIALISE. That materialisation is the step that runs the smudge.
git -C "$BOW" sparse-checkout set '/.agents/' > /dev/null 2>&1
for c in check diff run land; do
  case "$c" in
    run) out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0074-bo 2>&1)"; rc=$? ;;
    *)   out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" "$c" 0074-bo 2>&1)"; rc=$? ;;
  esac
  want_eq     "(bo) loom $c refuses the planted smudge filter" "$rc" "1"
  want_in     "(bo) ... naming it"                        "$out" "+ filter.evil.smudge="
  want_absent "(bo) ... before fence_apply could run it"  "$TMP/bo-smudge-ran"
done
git config --unset filter.evil.smudge
rm -f "$BOW/.gitattributes"
"$LOOM" drop 0074-bo > /dev/null 2>&1 || true

# ==========================================================================
# ROUND-10 fixes. Every case below FAILS against the pre-fix bin/loom (144eaf1).
#
# Two themes. The pin was PER TASK, and two roles have no task: `loom plan`'s
# architect and `loom scout`, the second of which does a working-tree update on
# a mirror it shares with every task and every provider. And a worktree was
# taken on trust: `$wt/.git` is a one-line FILE in a directory the agent owns,
# and rewriting it points every later `git -C "$wt" …` at a repository of the
# agent's choosing — which `require_wt_on_branch` could not see, because a decoy
# built with the same branch name answers the branch question correctly.
# ==========================================================================

# --- (bp) the REPOSITORY's config baseline, and a disposable scout mirror ---
# `loom scout` runs `fence_apply` -> `sparse-checkout set`, a `clean` and a
# `reset --hard` on $WT_ROOT/_scout. Every one of those is a WORKING-TREE
# UPDATE, and a working-tree update runs the SMUDGE side of whatever
# `filter.<d>` a .gitattributes there selects — with the driver read out of the
# SHARED .git/config, one `git config` from inside any agent's worktree. There
# was no task, so there was no pin, so nothing looked.
cat > "$TMP/bp-prog.sh" << PROG
#!/usr/bin/env bash
exit 0
PROG
chmod +x "$TMP/bp-prog.sh"
# A program-naming key that is ALREADY in the config when the task is pinned.
# The pin is a CHANGE check, so this is adopted as the baseline and trusted from
# here on — which the operator has to be told once, at the moment it happens.
git config gpg.program "$TMP/bp-prog.sh"
# ... and, since the REPOSITORY baseline already exists and this moved it in a
# way that names a program, the operator records that deliberately before
# `loom new` will touch it. See (bs).
"$LOOM" pin-config --accept-config > /dev/null 2>&1
out="$("$LOOM" new 0075-bp 2>&1)"; rc=$?
want_eq   "(bp) setup: a task, which baselines the REPOSITORY too" "$rc" "0"
want_file "(bp) ... at \$STATE_DIR/config"                "$STATE/config"
want_file "(bp) ... with the dump beside it, for the diff" "$STATE/config.gitconfig"
want_in   "(bp) ... and loom new names the programs it is adopting" "$out" "names PROGRAMS git runs"
want_in   "(bp) ... with the key, its value and its scope" "$out" "[local] gpg.program=$TMP/bp-prog.sh"
BPW="$WTU/0075-bp"
cat > "$TMP/bp-smudge.sh" << SM
#!/usr/bin/env bash
: > "$TMP/bp-smudge-ran"
exec cat
SM
chmod +x "$TMP/bp-smudge.sh"
printf '* filter=evil\n' > "$TMP/bp-attrs"
# Both planted from INSIDE an agent worktree, both landing in the SHARED
# .git/config: the driver, and the attributes file that selects it for a path.
git -C "$BPW" config filter.evil.smudge  "$TMP/bp-smudge.sh"
git -C "$BPW" config core.attributesFile "$TMP/bp-attrs"
# ... and a narrowed sparse spec in the MIRROR, so that loom's own fence_apply
# has files to MATERIALISE. That materialisation is the step that runs the
# smudge, and it is the first thing `loom scout` used to do.
git -C "$WTU/_scout" sparse-checkout set '/.agents/' > /dev/null 2>&1
bp_oc_before="$(wc -l < "$TMP/called-opencode.log" 2>/dev/null || echo 0)"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq     "(bp) loom scout refuses a config change although it has no task" "$rc" "1"
want_in     "(bp) ... naming the filter"                  "$out" "+ filter.evil.smudge="
want_in     "(bp) ... and the attributes file that selects it" "$out" "+ core.attributesfile="
want_in     "(bp) ... in the shared scope"                "$out" "[local]"
want_absent "(bp) ... before fence_apply could run it"    "$TMP/bp-smudge-ran"
want_in     "(bp) ... pointing at the operator command"   "$out" "loom pin-config --accept-config"
want_eq     "(bp) ... and no model was launched" \
            "$(wc -l < "$TMP/called-opencode.log" 2>/dev/null || echo 0)" "$bp_oc_before"
# `loom plan` is the same launch without the tree: the architect runs in $ROOT.
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_architect="deepseek/deepseek-v4-flash" \
       "$LOOM" plan -p "a topic" 2>&1)"; rc=$?
want_eq "(bp) loom plan refuses the same change, before the architect" "$rc" "1"
want_in "(bp) ... naming the filter"                      "$out" "+ filter.evil.smudge="
want_eq "(bp) ... and no architect was launched" \
        "$(wc -l < "$TMP/called-opencode.log" 2>/dev/null || echo 0)" "$bp_oc_before"
# The operator's command: it shows the diff, and it refuses without consent.
out="$("$LOOM" pin-config 2>&1)"; rc=$?
want_eq "(bp) loom pin-config refuses a changed baseline on its own"  "$rc" "1"
want_in "(bp) ... printing the diff rather than two digests"          "$out" "+ filter.evil.smudge="
want_in "(bp) ... and naming the flag that accepts it"               "$out" "--accept-config"
out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
want_eq "(bp) loom pin-config --accept-config re-records it"          "$rc" "0"
want_in "(bp) ... printing what it accepted"                         "$out" "+ filter.evil.smudge="
want_in "(bp) ... and saying which programs are now the baseline"    "$out" "names PROGRAMS git runs"
want_in "(bp) ... tagged with the scope they live in"                "$out" "[local] filter.evil.smudge="
# ... and now the scout runs. The smudge firing is what proves the plant was
# live all along, i.e. that the refusal above was not theatre.
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq   "(bp) with the baseline re-recorded, the scout runs"        "$rc" "0"
want_file "(bp) ... and the planted smudge really does fire"          "$TMP/bp-smudge-ran"
git config --unset filter.evil.smudge
git config --unset core.attributesFile
rm -f "$TMP/bp-smudge-ran"
"$LOOM" pin-config --accept-config > /dev/null 2>&1

# The mirror's OWN worktree scope — $GITCOMMON/worktrees/_scout/config.worktree
# — is the one scope no repository baseline can cover: it is not the local
# scope, not the main checkout's, and not any task's. `git -C <mirror> config
# --worktree` writes it, and the mirror is where every scout run's cwd is.
git -C "$WTU/_scout" config --worktree filter.evil.smudge "$TMP/bp-smudge.sh"
printf '* filter=evil\n' > "$WTU/_scout/.gitattributes"
git -C "$WTU/_scout" sparse-checkout set '/.agents/' > /dev/null 2>&1
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq     "(bp) loom scout refuses a key in the MIRROR's own worktree scope" "$rc" "1"
want_in     "(bp) ... naming the key"                     "$out" "filter.evil.smudge"
want_in     "(bp) ... and the file it is in"              "$out" "worktrees/_scout/config.worktree"
want_absent "(bp) ... with the smudge never run"          "$TMP/bp-smudge-ran"
git -C "$WTU/_scout" config --worktree --unset filter.evil.smudge

# The mirror is shared by every task and every provider, so nothing may survive
# in it: `reset --hard` never touches an untracked file, so a previous run's
# scratch — or a copy of a fenced path made with `git show HEAD:core/lib.rs >
# notes.txt`, which the index never sees — sat there for the next provider.
printf 'copied out of a fenced path\n' > "$WTU/_scout/backend/leftover.txt"
mkdir -p "$WTU/_scout/scratch"
printf 'notes from the last provider\n' > "$WTU/_scout/scratch/notes.txt"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq     "(bp) with the mirror's scope clear, the scout runs"      "$rc" "0"
want_absent "(bp) ... and an untracked file planted in it is gone"    "$WTU/_scout/backend/leftover.txt"
want_absent "(bp) ... including a whole directory of them"            "$WTU/_scout/scratch"
want_absent "(bp) ... and the .gitattributes that selected a driver"  "$WTU/_scout/.gitattributes"
want_file   "(bp) ... while the mirror itself is intact"              "$WTU/_scout/backend/main.go"
want_absent "(bp) ... still fenced, as it always was"                 "$WTU/_scout/core/lib.rs"

# No baseline at all is its own refusal, in the words written for it — and it
# is the state every repository that has never run `loom new` is in.
mv "$STATE/config"           "$TMP/bp-baseline"
mv "$STATE/config.gitconfig" "$TMP/bp-baseline.gitconfig"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq "(bp) with no baseline at all, the scout refuses" "$rc" "1"
want_in "(bp) ... in the words written for it"            "$out" "no repository config baseline"
want_in "(bp) ... naming both ways to get one"            "$out" "loom pin-config"
out="$("$LOOM" pin-config 2>&1)"; rc=$?
want_eq   "(bp) loom pin-config records one from nothing" "$rc" "0"
want_file "(bp) ... at \$STATE_DIR/config"                "$STATE/config"
want_in   "(bp) ... saying what it pinned"                "$out" "loom: pinned "
# ... and a baseline that is not one loom wrote is a dead stop, with the one
# command that can overwrite it still able to.
printf 'not a digest at all\n' > "$STATE/config"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq "(bp) a baseline loom did not write is a dead stop" "$rc" "1"
want_in "(bp) ... saying so"                              "$out" "not one loom wrote"
out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
want_eq "(bp) ... and --accept-config is a way out of it"  "$rc" "0"
git config --unset gpg.program
# The baseline is the REPOSITORY's, not a task's: dropping every task leaves it.
"$LOOM" drop 0075-bp > /dev/null 2>&1 || true
want_file "(bp) loom drop leaves the repository baseline where it is" "$STATE/config"

# --- (bq) a worktree whose .git was rewritten is not this repository's ------
# `$wt/.git` in a linked worktree is a FILE — one line, `gitdir: <path>` — in a
# directory the agent owns. Rewrite it and every `git -C "$wt" …` afterwards
# reads a git directory of the writer's choosing: its config (filter drivers,
# core.hooksPath, credential.helper), its hooks, its refs, its objects. The
# trap is that everything downstream still ANSWERS — a decoy built with the
# same branch name answers `symbolic-ref HEAD` with refs/heads/agent/<task>, so
# require_wt_on_branch passed it.
out="$("$LOOM" new 0076-bq 2>&1)"; rc=$?
want_eq "(bq) setup: an ordinary worktree"                "$rc" "0"
BQW="$WTU/0076-bq"
bq_gitfile="$(cat "$BQW/.git")"
echo "benign" > "$BQW/backend/bq.txt"
git -C "$BQW" add backend/bq.txt
git -C "$BQW" commit -qm "benign work on bq"
bq_tip="$(git rev-parse agent/0076-bq)"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0076-bq 2>&1)"; rc=$?
want_eq "(bq) setup: it is reviewed"                      "$rc" "0"
mkdir -p "$TMP/bq-hooks"
cat > "$TMP/bq-hooks/pre-commit" << HOOK
#!/usr/bin/env bash
: > "$TMP/bq-hook-ran"
exit 0
HOOK
cat > "$TMP/bq-prog.sh" << PROG
#!/usr/bin/env bash
: > "$TMP/bq-prog-ran"
exec cat
PROG
chmod +x "$TMP/bq-hooks/pre-commit" "$TMP/bq-prog.sh"
# The decoy, built the way one would actually be built: its own repository, the
# SAME BRANCH NAME (so the branch question is answered correctly),
# extensions.worktreeConfig on and core.sparseCheckout in the holder's own
# scope (so the config pin, which reads the task worktree's scope through
# `git -C "$wt"`, sees what it saw before), and the two programs the pin exists
# for — a clean filter and a hooksPath.
(
  cd "$TMP" || exit 1
  git init -q bq-decoy
  cd bq-decoy || exit 1
  git symbolic-ref HEAD refs/heads/main
  git config user.email test@example.invalid
  git config user.name  "fence test"
  git config extensions.worktreeConfig true
  git config core.hooksPath     "$TMP/bq-hooks"
  git config filter.evil.clean  "$TMP/bq-prog.sh"
  git config filter.evil.smudge "$TMP/bq-prog.sh"
  printf '* filter=evil\n' > .gitattributes
  echo "the decoy's own content" > decoy.txt
  git add -A
  git commit -qm "the decoy"
  git worktree add -q -b agent/0076-bq "$TMP/bq-holder" HEAD
  git -C "$TMP/bq-holder" config --worktree core.sparseCheckout true
) > /dev/null 2>&1
# Building the decoy runs its OWN hook (on its commit) and its own smudge (on
# the worktree checkout), which is the cheapest possible proof that both plants
# are live before a single loom command is typed. Cleared, so that what the
# assertions below measure is loom.
want_file "(bq) setup: the decoy's hook and filter are live"   "$TMP/bq-hook-ran"
want_file "(bq) setup: ... both of them"                       "$TMP/bq-prog-ran"
rm -f "$TMP/bq-hook-ran" "$TMP/bq-prog-ran"
mv "$TMP/bq-decoy/.git/worktrees/bq-holder" "$TMP/bq-decoy/.git/worktrees/holder"
printf 'gitdir: %s/bq-decoy/.git/worktrees/holder\n' "$TMP" > "$BQW/.git"
want_eq "(bq) setup: the rewritten worktree still answers with the task's branch" \
        "$(git -C "$BQW" symbolic-ref -q HEAD 2>/dev/null || echo NONE)" "refs/heads/agent/0076-bq"
want_eq "(bq) setup: ... while pointing at another repository entirely" \
        "$(git -C "$BQW" rev-parse --git-common-dir 2>/dev/null || echo NONE)" "$TMP/bq-decoy/.git"
for c in run check diff land rebase; do
  case "$c" in
    run)    out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0076-bq 2>&1)"; rc=$? ;;
    rebase) out="$("$LOOM" rebase 0076-bq main 2>&1)"; rc=$? ;;
    *)      out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" "$c" 0076-bq 2>&1)"; rc=$? ;;
  esac
  want_eq "(bq) loom $c refuses a worktree whose .git points elsewhere" "$rc" "1"
  want_in "(bq) ... naming the foreign git directory"     "$out" "$TMP/bq-decoy/.git"
  want_in "(bq) ... and saying what is wrong with it"     "$out" "does not belong to this repository"
done
want_absent "(bq) ... with the decoy's hook never run"    "$TMP/bq-hook-ran"
want_absent "(bq) ... nor its filter"                     "$TMP/bq-prog-ran"
want_eq     "(bq) ... and the real branch is exactly where it was" \
            "$(git rev-parse agent/0076-bq)" "$bq_tip"
out="$("$LOOM" drop 0076-bq 2>&1)"; rc=$?
want_eq     "(bq) loom drop refuses it too"               "$rc" "1"
want_not_in "(bq) ... and never prints its success line"  "$out" "loom: dropped"
want_file   "(bq) ... leaving the operator record that explains the directory" "$(state_of 0076-bq)"
want_file   "(bq) ... and the directory itself, for inspection" "$BQW/.git"
printf '%s\n' "$bq_gitfile" > "$BQW/.git"
out="$("$LOOM" drop 0076-bq 2>&1)"; rc=$?
want_eq     "(bq) ... and with the .git file put back, the drop goes through" "$rc" "0"
want_in     "(bq) ... this time saying so"                "$out" "loom: dropped"
want_absent "(bq) ... with the worktree gone"             "$BQW"

# A removal that did not remove is not a drop either. `git worktree remove`
# refuses a LOCKED worktree even with --force ("use remove -f -f"), and the old
# code wrote that call `|| true` — so the released paths stayed on disk under a
# message that said they were gone.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0077-bq2 --fence-profile codex 2>&1)"; rc=$?
want_eq   "(bq) setup: a profiled worktree, holding a released path" "$rc" "0"
BQ2W="$WTP/0077-bq2"
want_file "(bq) setup: ... which is core/, released by the profile" "$BQ2W/core/lib.rs"
git worktree lock "$BQ2W"
out="$("$LOOM" drop 0077-bq2 2>&1)"; rc=$?
want_eq     "(bq) loom drop refuses to call a failed removal a drop" "$rc" "1"
want_not_in "(bq) ... so it never prints its success line" "$out" "loom: dropped"
want_in     "(bq) ... it says what is still there"        "$out" "STILL on disk"
want_in     "(bq) ... and lists it"                       "$out" "$BQ2W/core"
want_file   "(bq) ... the released path really is still on disk" "$BQ2W/core/lib.rs"
want_file   "(bq) ... with the operator record kept, so it can be explained" "$(state_of 0077-bq2)"
git worktree unlock "$BQ2W"
out="$("$LOOM" drop 0077-bq2 2>&1)"; rc=$?
want_eq     "(bq) ... and once it can be removed, it is"  "$rc" "0"
want_in     "(bq) ... saying so"                          "$out" "loom: dropped"
want_absent "(bq) ... with the released path gone with it" "$BQ2W"
want_absent "(bq) ... and the operator record too"        "$(state_of 0077-bq2)"

# ==========================================================================
# ROUND-11 fixes. Every case below FAILS against the pre-fix bin/loom (2b3ec1b).
# ==========================================================================

# --- (br) the review directory is RESOLVED before loom writes into it -------
# `.agents/reviews` is the one place loom writes INTO a tree the agent owns:
# the review PATCH (which carries the content of every path in the diff,
# released paths included), the gate log, and the review text. The directory is
# the agent's to replace, and `reviews_dir` was `mkdir -p` and nothing else — a
# symlink there redirected all three, silently, because `mkdir -p` on a path
# that already resolves to a directory simply succeeds. The obvious target is
# another task's worktree: an UNPROFILED tree, under the other root, that a
# provider this profile does not allow is about to run in.
out="$("$LOOM" new 0078-br 2>&1)"; rc=$?
want_eq "(br) setup: an unprofiled task — the redirect's target"  "$rc" "0"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$LOOM" new 0079-br2 --fence-profile codex 2>&1)"; rc=$?
want_eq   "(br) setup: a profiled task, holding released paths"   "$rc" "0"
BRT="$WTU/0078-br"; BRP="$WTP/0079-br2"
want_file "(br) setup: ... core/ really is released into it"      "$BRP/core/lib.rs"
echo "// released work" >> "$BRP/core/lib.rs"
git -C "$BRP" add core/lib.rs
git -C "$BRP" commit -qm "released work on br2"
# The stealth variant: `.agents` intact and tracked, one directory inside it
# swapped. Every check written at the `.agents` level walks straight past it.
rm -rf "$BRP/.agents/reviews"
ln -s "$BRT/.agents/reviews" "$BRP/.agents/reviews"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0079-br2 --fence-profile codex 2>&1)"; rc=$?
want_eq     "(br) loom check refuses a symlinked .agents/reviews"  "$rc" "1"
want_in     "(br) ... naming the path it RESOLVES to"              "$out" "$BRT/.agents/reviews"
want_in     "(br) ... and the worktree that is not inside"         "$out" "$BRP"
want_absent "(br) ... with no patch written through the link"      "$BRT/.agents/reviews/0079-br2.patch"
want_absent "(br) ... nor a review"                                "$BRT/.agents/reviews/0079-br2-review.md"
out="$("$LOOM" diff 0079-br2 --fence-profile codex 2>&1)"; rc=$?
want_eq     "(br) loom diff refuses it the same way"               "$rc" "1"
want_in     "(br) ... naming the resolved path"                    "$out" "$BRT/.agents/reviews"
want_absent "(br) ... and writes no patch either"                  "$BRT/.agents/reviews/0079-br2.patch"
# `wt_dirty` excludes `.agents/reviews` by pathspec so that loom's own review
# scratch does not make a task unlandable. The exclusion is for loom's scratch
# and for nothing else: a symlink in its place is not that directory, the
# pathspec is dropped, and landing refuses.
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" land 0079-br2 --fence-profile codex 2>&1)"; rc=$?
want_eq     "(br) loom land refuses it, because the exclusion no longer applies" "$rc" "1"
want_in     "(br) ... as uncommitted work"                         "$out" "uncommitted changes"
want_in     "(br) ... naming the link itself"                      "$out" ".agents/reviews"
# ... and the tree the link points AT goes on working, with nothing of the
# other task's in it.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MAX_ATTEMPTS=1 "$LOOM" run 0078-br 2>&1)"; rc=$?
want_eq     "(br) the redirect's target runs normally"             "$rc" "0"
want_in     "(br) ... reaching a green gate"                       "$out" "gate green"
want_file   "(br) ... writing its OWN gate log"                    "$BRT/.agents/reviews/0078-br-gate.log"
want_absent "(br) ... and never the other task's patch"            "$BRT/.agents/reviews/0079-br2.patch"
# The coarse variant: `.agents` itself. It must be caught BEFORE the `mkdir -p`,
# which would otherwise create the directory at the far end of the link — a
# write outside the worktree by the call that is supposed to be checking.
rm -f "$BRP/.agents/reviews"
mv "$BRP/.agents" "$TMP/br-agents"
ln -s "$TMP/br-agents" "$BRP/.agents"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0079-br2 --fence-profile codex 2>&1)"; rc=$?
want_eq "(br) the coarse variant — .agents itself — is refused too" "$rc" "1"
want_in "(br) ... naming .agents rather than the directory under it" "$out" ".agents resolves to"
want_in "(br) ... and where it points"                             "$out" "$TMP/br-agents"
rm -f "$BRP/.agents"
mv "$TMP/br-agents" "$BRP/.agents"
"$LOOM" drop 0079-br2 > /dev/null 2>&1 || true
"$LOOM" drop 0078-br  > /dev/null 2>&1 || true

# --- (bs) a repository baseline never moves silently ------------------------
# `config_repin` re-records the REPOSITORY baseline as a side effect of pinning
# a task — at `loom new`, and again at `land --pr` after its own
# `--set-upstream-to`. Both are places where loom expects to be adopting its
# OWN writes, and "expects" is not "checked": anything else that moved in the
# same window became the baseline the next `loom scout` and `loom plan` are
# judged against, with nothing printed.
cat > "$TMP/bs-smudge.sh" << SM
#!/usr/bin/env bash
: > "$TMP/bs-smudge-ran"
exec cat
SM
chmod +x "$TMP/bs-smudge.sh"
git config filter.evil.smudge "$TMP/bs-smudge.sh"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$LOOM" scout "where is main" 2>&1)"; rc=$?
want_eq "(bs) setup: the operator's scout refuses the planted key" "$rc" "1"
want_in "(bs) ... naming it"                              "$out" "+ filter.evil.smudge="
# The agent's next move is a `loom new`, which used to re-record that key as the
# baseline and hand the scout a config nobody had read.
bs_base="$(cat "$STATE/config")"
out="$("$LOOM" new 0080-bs 2>&1)"; rc=$?
want_eq     "(bs) loom new REFUSES a baseline move that names a program" "$rc" "1"
want_in     "(bs) ... printing the delta first"           "$out" "repository config baseline moved:"
want_in     "(bs) ... naming the key"                     "$out" "+ filter.evil.smudge="
want_in     "(bs) ... and saying it is a program git runs" "$out" "names a PROGRAM git runs"
want_in     "(bs) ... pointing at the command that CAN weigh it" \
            "$out" "loom pin-config --accept-config"
want_eq     "(bs) ... with the baseline left exactly as it was" "$(cat "$STATE/config")" "$bs_base"
want_absent "(bs) ... and the half-built task unwound"    "$WTU/0080-bs"
want_absent "(bs) ... record and all"                     "$(state_of 0080-bs)"
out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
want_eq "(bs) ... loom pin-config --accept-config is the way through" "$rc" "0"
out="$("$LOOM" new 0080-bs 2>&1)"; rc=$?
want_eq "(bs) ... and then loom new goes ahead"           "$rc" "0"
"$LOOM" drop 0080-bs > /dev/null 2>&1 || true
git config --unset filter.evil.smudge
"$LOOM" pin-config --accept-config > /dev/null 2>&1
# A move that names NO program is adopted — but never silently.
git config loom.probe "a value"
out="$("$LOOM" new 0081-bs2 2>&1)"; rc=$?
want_eq "(bs) a move that names no program is adopted"    "$rc" "0"
want_in "(bs) ... with the delta printed rather than swallowed" \
        "$out" "repository config baseline moved:"
want_in "(bs) ... naming the key"                         "$out" "+ loom.probe="
want_in "(bs) ... and saying who vouches for it"          "$out" "loom vouches for none of it"
"$LOOM" drop 0081-bs2 > /dev/null 2>&1 || true
git config --unset loom.probe
"$LOOM" pin-config --accept-config > /dev/null 2>&1
# ... and the same rule at `land --pr`'s post-push re-pin, where the window is
# the push itself. The plant arrives from git's own pre-push hook — no config
# change of its own, so nothing before the push can see it coming.
git init -q --bare "$TMP/origin-bs.git"
git remote add origin "$TMP/origin-bs.git"
git push -q origin main
out="$("$LOOM" new 0083-bs3 2>&1)"; rc=$?
want_eq "(bs) setup: a task against a real origin"        "$rc" "0"
BS3W="$WTU/0083-bs3"
echo "benign" > "$BS3W/backend/bs.txt"
git -C "$BS3W" add backend/bs.txt
git -C "$BS3W" commit -qm "benign work on bs3"
out="$(LOOM_MODELS_reviewer="codex-sub" "$LOOM" check 0083-bs3 2>&1)"; rc=$?
want_eq "(bs) setup: it is reviewed"                      "$rc" "0"
cat > "$TMP/bs-prog.sh" << PROG
#!/usr/bin/env bash
: > "$TMP/bs-prog-ran"
exec cat
PROG
chmod +x "$TMP/bs-prog.sh"
cat > "$REPO_REAL/.git/hooks/pre-push" << HOOK
#!/usr/bin/env bash
git config --local filter.pushwindow.clean "$TMP/bs-prog.sh"
exit 0
HOOK
chmod +x "$REPO_REAL/.git/hooks/pre-push"
bs_base="$(cat "$STATE/config")"
out="$("$LOOM" land 0083-bs3 --pr 2>&1)"; rc=$?
want_eq "(bs) land --pr refuses to re-pin a baseline that moved during the push" "$rc" "1"
want_in "(bs) ... printing the delta"                     "$out" "repository config baseline moved:"
want_in "(bs) ... including loom's own two writes"        "$out" "+ branch.agent/0083-bs3.remote="
want_in "(bs) ... and the key that rode in under them"    "$out" "+ filter.pushwindow.clean="
want_in "(bs) ... called what it is"                      "$out" "names a PROGRAM git runs"
want_in "(bs) ... saying the push already happened"       "$out" "THE PUSH ALREADY HAPPENED"
want_in "(bs) ... and where to go next"                   "$out" "loom pin-config --accept-config"
want_eq "(bs) ... with the baseline NOT re-recorded"      "$(cat "$STATE/config")" "$bs_base"
want_ne "(bs) ... while the branch really is on origin, as it says" \
        "$(git -C "$TMP/origin-bs.git" rev-parse --verify --quiet refs/heads/agent/0083-bs3 || echo GONE)" "GONE"
rm -f "$REPO_REAL/.git/hooks/pre-push"
git config --unset filter.pushwindow.clean
"$LOOM" drop 0083-bs3 > /dev/null 2>&1 || true
git remote remove origin
"$LOOM" pin-config --accept-config > /dev/null 2>&1

# --- (bt) extensions.worktreeConfig is read the way git reads it ------------
# git decides whether the two worktree scopes are live with its own
# `git_config_bool`: case-insensitive, and a VALUELESS key is true. The
# snapshot matched the string against `true|yes|on|1`, so `True`, `ON` and the
# valueless form turned the worktree scopes OFF in the pin while git went on
# reading them — a `core.hooksPath` in `config.worktree` live and unpinned.
#
# The REPOSITORY baseline is the route these forms survive on: every task
# command reaches `fence_apply` -> `git sparse-checkout init`, and git rewrites
# `extensions.worktreeConfig` to its own lowercase `true` on the way past
# (measured, git 2.34.1). `loom pin-config` and `loom scout`'s refusal both read
# the config without touching a worktree, so the odd form is still standing when
# they look. (`worktree-task` is deliberately not in the repository baseline —
# there is no task here; (bm) is the case that covers that scope.)
BTCFG="$REPO_REAL/.git/config"
bt_set() { # bt_set <literal>   ("" writes the valueless form)
  python3 - "$BTCFG" "$1" << 'PY'
import re, sys
p, val = sys.argv[1], sys.argv[2]
out, skip = [], False
for ln in open(p).read().splitlines(True):
    if re.match(r'^\s*\[', ln):
        skip = re.match(r'^\s*\[extensions\]', ln, re.I) is not None
        if skip:
            continue
    if skip:
        continue
    out.append(ln)
out.append("[extensions]\n")
out.append("\tworktreeConfig\n" if val == "" else "\tworktreeConfig = %s\n" % val)
open(p, "w").writelines(out)
PY
}
for form in True ON ""; do
  label="${form:-<valueless>}"
  # The MAIN checkout's own scope — not the local one, and not any task's.
  git config --worktree core.hooksPath "$TMP/bt-hooks"
  bt_set "$form"
  want_eq "(bt) setup: git reads '$label' as true" \
          "$(git config --local --type=bool --get extensions.worktreeConfig 2>/dev/null || echo NONE)" "true"
  want_eq "(bt) setup: ... and the file really says '$label'" \
          "$(git config --local --get extensions.worktreeConfig 2>/dev/null || true)" "$form"
  out="$("$LOOM" pin-config --accept-config 2>&1)"; rc=$?
  want_eq     "(bt) the baseline records with extensions.worktreeConfig = $label" "$rc" "0"
  want_not_in "(bt) ... and does not report zero worktree entries"  "$out" "+ 0 worktree config entries"
  want_in     "(bt) ... with the main checkout's own scope really in it" \
              "$(tr '\0' '\n' < "$STATE/config.gitconfig")" "worktree-main:core.hookspath"
  # ... and a change to that scope is a refusal for the roles judged against it.
  git config --worktree core.hooksPath "$TMP/bt-hooks-2"
  out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
         "$LOOM" scout "where is main" 2>&1)"; rc=$?
  want_eq "(bt) ... a core.hooksPath planted in config.worktree is refused" "$rc" "1"
  want_in "(bt) ... named in the diff"     "$out" "+ core.hookspath=$TMP/bt-hooks-2"
  want_in "(bt) ... tagged with its scope" "$out" "[worktree-main]"
  git config --worktree --unset core.hooksPath
done
bt_set true
"$LOOM" pin-config --accept-config > /dev/null 2>&1

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
