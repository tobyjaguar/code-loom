#!/usr/bin/env bash
# tests/fence-profiles.sh — fence profiles, end to end, against a throwaway repo.
#
#   bash tests/fence-profiles.sh
#
# No network, no model: `codex`, `claude`, `opencode` and `curl` are stubbed on
# PATH, the real key file is swapped for an empty one, and the models.dev
# catalog `aw doctor` would fetch is seeded in $XDG_CACHE_HOME — so a chain that
# reaches a real provider, or a doctor run that reaches the network, fails
# loudly rather than quietly costing money. Needs git and python3 (>= 3.11, or
# the tomli backport) — the same requirements as `aw`.
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
want_not_in() { # want_not_in <label> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 — '$3' IS in output: $(printf '%s' "$2" | head -3 | tr '\n' ' ')" ;; *) ok "$1" ;; esac
}
want_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 — missing: $2"; fi; }
want_absent() { if [ -e "$2" ]; then bad "$1 — present but should not be: $2"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/aw-fence-profiles.XXXXXX")"
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
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-claude.log"
# A hostile first attempt, for the per-attempt reconcile test: widen the
# worktree the harness just fenced, then look rate-limited so `aw` falls back
# to the next model in the chain with the widened tree already on disk.
if [ -n "${AW_TEST_RELAX_SPARSE:-}" ]; then
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
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-codex.log"
echo "stub codex done"
STUB
cat > "$TMP/stubs/opencode" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-opencode.log"
# The directory grant is the thing under test: record it verbatim.
printf 'OPENCODE_PERMISSION=%s\n' "${OPENCODE_PERMISSION:-(unset)}" \
  >> "${AW_TEST_TMP:?}/called-opencode.log"
echo "stub opencode done"
STUB
cat > "$TMP/stubs/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${AW_TEST_TMP:?}/called-curl.log"
exit 1
STUB
chmod +x "$TMP/stubs/"*

# The catalog `aw doctor` fetches from models.dev, seeded fresh so the fetch is
# skipped: every model ID in the default chains, so doctor has an offline answer.
cat > "$TMP/cache/loom/models-dev.json" << 'JSON'
{
  "zai-coding-plan": {"models": {"glm-5.3": {"id": "glm-5.3"}, "glm-5.3-flash": {"id": "glm-5.3-flash"}}},
  "moonshotai":      {"models": {"kimi-k2.5": {"id": "kimi-k2.5"}, "kimi-k2.7-code": {"id": "kimi-k2.7-code"}}},
  "deepseek":        {"models": {"deepseek-v4-pro": {"id": "deepseek-v4-pro"}, "deepseek-v4-flash": {"id": "deepseek-v4-flash"}}}
}
JSON

export AW_TEST_TMP="$TMP"
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
export LOOM_TIER=standard
unset ZHIPU_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY MOONSHOT_API_KEY \
      CODEX_API_KEY OPENAI_API_KEY LOOM_SKIP AW_FENCE_PROFILE 2>/dev/null || true

# ------------------------------------------------------------ target repo
mkdir -p "$REPO"/{core,ios,backend,docs/audits}/ "$REPO"/.agents/{tasks,plans,reviews} "$REPO"/.opencode/prompts
cd "$REPO" || exit 1
git init -q .
# The trunk is `main` on purpose: $LOOM_BASE_REF (the ref every SECURITY BASE
# is measured from) defaults to origin/main, else main, and this repo has no
# remote. `git init -b main` needs git >= 2.28; this works everywhere.
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
         0014-u 0016-v 0017-w 0018-x 0019-y 0020-y2 0023-ae; do mk_task "$t"; done
mk_task 0005-f codex
mk_task 0011-n codex
# (o) a Fence-profile line that is NOT a declaration: it is inside a code fence,
# below the header block — exactly the shape `aw loop` appends to a task file
# when it pastes a reviewer's text back in.
{ echo "# 0012-o — test task"; echo ""; echo "Plan: none"; echo "Zone: assist"; echo "";
  echo "## Auto fix round 1 (aw loop — reviewer REVISE)"; echo "";
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
out="$("$AW" new 0001-a 2>&1)"; rc=$?
want_eq   "(a) aw new without a profile succeeds"      "$rc" "0"
want_absent "(a) core/ is fenced out"                  "$WTU/0001-a/core/lib.rs"
want_absent "(a) ios/ is fenced out"                   "$WTU/0001-a/ios/App.swift"
want_absent "(a) docs/audits/ is fenced out"           "$WTU/0001-a/docs/audits/a.md"
want_file   "(a) the working surface is present"       "$WTU/0001-a/backend/main.go"

git checkout -q -b agent/guard-a
echo "// touched" >> core/lib.rs
git add core/lib.rs
out="$("$AW" guard 2>&1)"; rc=$?
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
       "$AW" new 0002-b --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed implementer chain"  "$rc" "1"
want_in  "(b) the message names the role"              "$out" "implementer chain"
want_in  "(b) the message names the model"             "$out" "deepseek/deepseek-v4-pro"
want_in  "(b) the message names the override"          "$out" "LOOM_MODELS_implementer"
want_absent "(b) no worktree was created"              "$WTP/0002-b"
want_eq  "(b) nothing else appeared under EITHER worktree root" "$(roots_listing)" "$before"
# ... and the same for the reviewer chain. A DIFFERENT task id on purpose: a
# second `aw new 0002-b` would die on "worktree already exists" if the first
# leg ever stopped dying, and the assertion would pass for the wrong reason.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="zai-coding-plan/glm-5.3" \
       "$AW" new 0007-h --fence-profile codex 2>&1)"; rc=$?
want_eq  "(b) dies on a disallowed reviewer chain"     "$rc" "1"
want_in  "(b) the message names the reviewer role"     "$out" "reviewer chain"
want_absent "(b) no worktree for the reviewer leg either" "$WTP/0007-h"

# --- (c) a profile with allowed chains: released paths are present ---------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq   "(c) aw new under the profile succeeds"      "$rc" "0"
want_file "(c) core/ is released into the worktree"    "$WTP/0003-c/core/lib.rs"
want_file "(c) docs/audits/ is released"               "$WTP/0003-c/docs/audits/a.md"
want_absent "(c) ios/ is still fenced"                 "$WTP/0003-c/ios/App.swift"
want_eq   "(c) the profile is recorded on the branch"  \
          "$(git config branch.agent/0003-c.fenceprofile)" "codex"
out="$("$AW" ls 2>&1)"
want_in   "(c) aw ls shows the profile"                "$out" "fence-profile:codex"

# aw run re-applies AND verifies the fence, then commits: this is the path that
# proves fence_reconcile accepts a worktree holding released paths.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" run 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq  "(c) aw run under the profile reaches a green gate" "$rc" "0"
want_in  "(c) fence_verify passed (no 'STILL present')"      "$out" "gate green"
want_file "(c) the stub implementer ran"                     "$TMP/called-claude.log"
want_in  "(c) an implementer gets claude's edit permission"  "$(cat "$TMP/called-claude.log")" "acceptEdits"
want_in  "(c) the implementer prompt names the profile"      "$(cat "$TMP/called-claude.log")" "fence profile 'codex'"
want_absent "(c) no reviewer ran yet"                        "$TMP/called-codex.log"

# The reviewer must be told the released paths are in scope, and must stay
# read-only.
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0003-c --fence-profile codex 2>&1)"; rc=$?
want_eq  "(c) aw check under the profile succeeds"           "$rc" "0"
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
out="$(LOOM_MODELS_implementer="codex-sub" LOOM_MAX_ATTEMPTS=1 "$AW" run 0006-g 2>&1)"; rc=$?
want_eq "(c) a codex-sub implementer run succeeds"           "$rc" "0"
want_in "(c) an implementer gets codex's workspace-write"    "$(cat "$TMP/called-codex.log")" "workspace-write"
want_in "(c) ... and .agents made writable for the notes"    "$(cat "$TMP/called-codex.log")" "--add-dir"

# --- (c2) the flag is required on every command ---------------------------
out="$("$AW" run 0003-c 2>&1)"; rc=$?
want_eq "(c2) aw run without the flag dies"                  "$rc" "1"
want_in "(c2) ... naming the profile to pass"                "$out" "--fence-profile codex"
out="$("$AW" check 0003-c 2>&1)"; rc=$?
want_eq "(c2) aw check without the flag dies"                "$rc" "1"
out="$("$AW" land 0003-c 2>&1)"; rc=$?
want_eq "(c2) aw land without the flag dies"                 "$rc" "1"
out="$("$AW" rebase 0003-c 2>&1)"; rc=$?
want_eq "(c2) aw rebase without the flag dies"               "$rc" "1"
out="$("$AW" check 0003-c --fence-profile audit 2>&1)"; rc=$?
want_eq "(c2) a flag that contradicts the record dies"       "$rc" "1"
want_in "(c2) ... naming both names"                         "$out" "contradicts the record"
out="$("$AW" check 0001-a --fence-profile codex 2>&1)"; rc=$?
want_eq "(c2) a profile cannot be introduced into an unprofiled task" "$rc" "1"
want_in "(c2) ... and it says why"                           "$out" "cannot be introduced"

# --- (d) the guard under a profile, IN the agent's own worktree ------------
# The guard is a pre-commit hook: it runs where the agent commits.
GW="$WTP/0003-c"
echo "// touched again" >> "$GW/core/lib.rs"
git -C "$GW" add core/lib.rs
out="$(cd "$GW" && "$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard ALLOWS a released core/ commit under the profile" "$rc" "0"
printf '\n# tampered\n' >> "$GW/.agents/zones.toml"
git -C "$GW" add .agents/zones.toml
out="$(cd "$GW" && "$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard still blocks the control plane"        "$rc" "1"
want_in "(d) the block names zones.toml"                  "$out" ".agents/zones.toml"
want_in "(d) the block names what the profile released"   "$out" "releases only"
case "$out" in *core/lib.rs*) bad "(d) a released path must not be listed as a violation" ;;
               *)             ok  "(d) the released path is not listed as a violation" ;; esac
git -C "$GW" reset -q --hard
# A fenced path the profile did NOT release, created inside the worktree.
mkdir -p "$GW/ios"; echo "// swift" > "$GW/ios/App.swift"
git -C "$GW" add ios/App.swift
out="$(cd "$GW" && "$AW" guard 2>&1)"; rc=$?
want_eq "(d) guard blocks a fenced path the profile did NOT release" "$rc" "1"
git -C "$GW" reset -q --hard
rm -f "$GW/ios/App.swift"

# --- (e) unknown profile ---------------------------------------------------
out="$("$AW" new 0004-e --fence-profile nope 2>&1)"; rc=$?
want_eq "(e) an unknown profile dies"                     "$rc" "1"
want_in "(e) the message says which are defined"          "$out" "unknown fence profile 'nope'"
want_absent "(e) no worktree was created"                 "$WTU/0004-e"
want_absent "(e) ... under either root"                   "$WTP/0004-e"

# --- (f) the task file declares, the FLAG consents -------------------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0005-f --fence-profile codex 2>&1)"; rc=$?
want_eq   "(f) declaration + matching flag opts in"       "$rc" "0"
want_eq   "(f) it is recorded on the branch"              \
          "$(git config branch.agent/0005-f.fenceprofile)" "codex"
want_file "(f) the released path is present"              "$WTP/0005-f/core/lib.rs"
want_absent "(f) the unreleased fenced path is not"       "$WTP/0005-f/ios/App.swift"
# The same task, with a disallowed chain, must still die.
out="$(LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" "$AW" check 0005-f --fence-profile codex 2>&1)"; rc=$?
want_eq "(f) a later command re-checks the chain"         "$rc" "1"

# --- (g) a task file that gains a profile late is inert --------------------
# The file states intent; only `aw new` reads it, and only with the flag. A
# line added afterwards must neither release anything nor be honoured later.
printf 'Fence-profile: codex\n' >> .agents/tasks/0001-a.md
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0001-a 2>&1)"; rc=$?
want_eq "(g) a task file edited after aw new changes nothing" "$rc" "0"
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
out="$("$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a release outside [fence] is refused"        "$rc" "1"
want_in "(h) ... with a reason"                           "$out" "not one of [fence].paths"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.bogus2]
release = ["core/**"]
TOML
out="$("$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(h) a profile without providers is refused"      "$rc" "1"
restore_zones

# --- (i) an inherited AW_FENCE_PROFILE must not widen anything ------------
out="$(AW_FENCE_PROFILE=codex "$AW" zone core/lib.rs 2>&1)"; rc=$?
want_eq "(i) the environment cannot activate a profile"   "$rc" "0"
want_in "(i) core/ is still reported as fenced"           "$out" "fenced"

# --- (k) the record is REMOVED: rule 3 is ABSOLUTE, there is no escape -----
# There used to be one: a worktree holding exactly what the flag releases was
# read as corroboration, the record was restored and the command ran. A
# worktree is a directory the agent can write (`git sparse-checkout disable`),
# so that corroborated nothing. Restoring a lost record is now an operator act.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq   "(k) setup: a profiled worktree exists"         "$rc" "0"
want_file "(k) setup: it holds the released path"         "$WTP/0008-k/core/lib.rs"
git config --unset branch.agent/0008-k.fenceprofile
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0008-k 2>&1)"; rc=$?
want_eq "(k) without the flag, a released tree is refused"   "$rc" "1"
want_in "(k) ... naming the paths it found on disk"          "$out" "core/lib.rs"
want_not_in "(k) ... and no reviewer was launched"           "$out" "running on"
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq "(k) with the flag and no record it STILL dies"       "$rc" "1"
want_in "(k) ... the tree is not evidence"                    "$out" "is not evidence"
want_not_in "(k) ... nothing is restored on the operator's behalf" "$out" "Restoring it"
want_not_in "(k) ... and no reviewer was launched"            "$out" "running on"
want_eq "(k) ... the record is still absent"                  \
        "$(git config branch.agent/0008-k.fenceprofile 2>/dev/null || true)" ""
want_in "(k) ... and it says how to restore it BY HAND"       "$out" \
        "git config branch.agent/0008-k.fenceprofile codex"
want_in "(k) ... or start clean"                              "$out" "aw drop 0008-k"

# --- (l) the record is SWAPPED to another legitimate profile --------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0009-l --fence-profile codex 2>&1)"; rc=$?
want_eq "(l) setup: a codex worktree exists"              "$rc" "0"
git config branch.agent/0009-l.fenceprofile audit
out="$(LOOM_MODELS_reviewer="claude-sub" "$AW" check 0009-l --fence-profile audit 2>&1)"; rc=$?
want_eq "(l) the swapped profile does not release what is on disk" "$rc" "1"
want_in "(l) ... and it names the path"                   "$out" "core/lib.rs"
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0009-l --fence-profile codex 2>&1)"; rc=$?
want_eq "(l) the real profile now contradicts the swapped record" "$rc" "1"
want_in "(l) ... and says so"                             "$out" "contradicts the record"

# --- (m) an agent writes the branch record from inside its worktree -------
out="$("$AW" new 0010-m 2>&1)"; rc=$?
want_eq   "(m) setup: an UNPROFILED worktree"             "$rc" "0"
want_absent "(m) setup: core/ is fenced out of it"        "$WTU/0010-m/core/lib.rs"
git -C "$WTU/0010-m" config branch.agent/0010-m.fenceprofile codex   # the agent forges it
out="$("$AW" run 0010-m 2>&1)"; rc=$?
want_eq "(m) a forged record cannot authorise: no flag, no run" "$rc" "1"
want_in "(m) ... it can only refuse"                      "$out" "--fence-profile codex"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" run 0010-m --fence-profile codex 2>&1)"; rc=$?
want_eq "(m) and the flag cannot introduce a profile either"   "$rc" "1"
want_in "(m) ... the task already exists under the OTHER root" "$out" "already has a worktree at"
want_in "(m) ... and says why that is refused"                 "$out" "cannot be introduced after"
want_absent "(m) nothing was released into the worktree"       "$WTU/0010-m/core/lib.rs"
want_absent "(m) and no profiled worktree was built for it"    "$WTP/0010-m"

# --- (n) a task-file declaration alone is not consent ---------------------
out="$("$AW" new 0011-n 2>&1)"; rc=$?
want_eq "(n) a 'Fence-profile:' line without the flag dies"    "$rc" "1"
want_in "(n) ... asking for confirmation on the command line"  "$out" "aw new 0011-n --fence-profile codex"
want_absent "(n) and no worktree was created"                  "$WTU/0011-n"
want_absent "(n) ... under either root"                        "$WTP/0011-n"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0011-n --fence-profile codex 2>&1)"; rc=$?
want_eq   "(n) the same line WITH the matching flag is fine"   "$rc" "0"
want_file "(n) ... and releases the path"                      "$WTP/0011-n/core/lib.rs"

# --- (o) a Fence-profile line inside a code fence is not a declaration ----
out="$("$AW" new 0012-o 2>&1)"; rc=$?
want_eq   "(o) a fenced-off code block is ignored"        "$rc" "0"
want_absent "(o) ... nothing was released"                "$WTU/0012-o/core/lib.rs"
want_eq   "(o) ... and nothing was recorded"              \
          "$(git config branch.agent/0012-o.fenceprofile 2>/dev/null || true)" ""

# --- (p) .agents symlinked out of the worktree ----------------------------
out="$("$AW" new 0013-p 2>&1)"; rc=$?
want_eq "(p) setup: a plain worktree"                     "$rc" "0"
mkdir -p "$TMP/outside-agents/reviews"
cp "$REPO/.agents/gate.sh" "$TMP/outside-agents/gate.sh"
mv "$WTU/0013-p/.agents" "$WTU/0013-p/.agents-real"
ln -s "$TMP/outside-agents" "$WTU/0013-p/.agents"
codex_before="$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)"
out="$(LOOM_MODELS_implementer="codex-sub" LOOM_MAX_ATTEMPTS=1 "$AW" run 0013-p 2>&1)"; rc=$?
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
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
want_eq "(q) providers = [\"*\"] is refused"              "$rc" "1"
want_in "(q) ... naming the rule"                         "$out" "no glob"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.twoinone]
release = ["core/**"]
providers = ["claude deepseek"]
TOML
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
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
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
want_eq "(r) a release still covered by [fence] is refused" "$rc" "1"
want_in "(r) ... naming the pattern that covers it"        "$out" "'docs/**' still covers it"
restore_zones

# --- (s) an empty --fence-profile value -----------------------------------
out="$("$AW" new 0004-e --fence-profile= 2>&1)"; rc=$?
want_eq "(s) --fence-profile= dies"                       "$rc" "1"
want_in "(s) ... naming the missing value"                "$out" "empty value"
want_absent "(s) and creates nothing"                     "$WTU/0004-e"
want_absent "(s) ... under either root"                   "$WTP/0004-e"
out="$("$AW" check 0003-c --fence-profile= 2>&1)"; rc=$?
want_eq "(s) ... on every command"                        "$rc" "1"
out="$("$AW" check 0003-c --fence-profile 2>&1)"; rc=$?
want_eq "(s) a bare --fence-profile dies too"             "$rc" "1"

# ==========================================================================
# ROUND-2 fixes. Every case below FAILS against the pre-fix bin/aw.
# ==========================================================================

# --- (u) an existing branch is refused, never deleted ---------------------
# `aw new` set NEW_BR before `git worktree add -b`, so an add that failed
# because agent/<task> already existed ran the EXIT trap on the PRE-EXISTING
# branch — the state `aw drop --keep-branch` leaves on purpose — and silenced
# the deletion. The branch and its commits must survive the refusal.
sha_of() { git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || echo "GONE"; }
out="$("$AW" new 0014-u 2>&1)"; rc=$?
want_eq "(u) setup: a plain worktree"                     "$rc" "0"
echo "work" > "$WTU/0014-u/backend/u.txt"
git -C "$WTU/0014-u" add backend/u.txt
git -C "$WTU/0014-u" commit -qm "work that only exists on this branch"
u_sha="$(sha_of agent/0014-u)"
out="$("$AW" drop 0014-u --keep-branch 2>&1)"; rc=$?
want_eq "(u) setup: worktree dropped, branch kept"        "$rc" "0"
out="$("$AW" new 0014-u 2>&1)"; rc=$?
want_eq "(u) aw new refuses an existing branch"           "$rc" "1"
want_in "(u) ... naming it"                               "$out" "branch agent/0014-u already exists"
want_in "(u) ... and mentioning --keep-branch"            "$out" "--keep-branch"
want_eq "(u) ... the branch still points at its commit"   "$(sha_of agent/0014-u)" "$u_sha"
want_absent "(u) ... and no worktree was created"         "$WTU/0014-u"
# the same through `aw run`, which reaches cmd_new for a missing worktree
out="$("$AW" run 0014-u 2>&1)"; rc=$?
want_eq "(u) aw run refuses it too"                       "$rc" "1"
want_eq "(u) ... and the branch survives that as well"    "$(sha_of agent/0014-u)" "$u_sha"
git branch -D agent/0014-u > /dev/null 2>&1 || true

# --- (v) the branch's COMMITS are judged, not just what is on disk --------
# Materialise a fenced path, commit it, put the sparse rules back: the tree
# looks clean, and the diff, the patch file and any merge still carry it.
out="$("$AW" new 0016-v 2>&1)"; rc=$?
want_eq "(v) setup: an unprofiled worktree"               "$rc" "0"
VW="$WTU/0016-v"
git -C "$VW" sparse-checkout disable                       # the agent widens it
echo "// smuggled" >> "$VW/core/lib.rs"
git -C "$VW" add core/lib.rs
git -C "$VW" commit -qm "touch a fenced path"
git -C "$VW" sparse-checkout init --no-cone                # ... and re-fences
git -C "$VW" sparse-checkout set '/*' '!core/**' '!ios/**' '!docs/audits/**'
git config --unset "branch.agent/0016-v.fenceprofile" 2>/dev/null || true
want_absent "(v) setup: the tree no longer shows the fenced path" "$VW/core/lib.rs"
rm -f "$VW/.agents/reviews/0016-v.patch"
out="$(LOOM_MODELS_reviewer="codex-sub" "$AW" check 0016-v 2>&1)"; rc=$?
want_eq "(v) aw check dies on a fenced path in the history"  "$rc" "1"
want_in "(v) ... naming the path"                            "$out" "core/lib.rs"
want_in "(v) ... and saying the commits carry it"            "$out" "commits touch fenced paths"
want_absent "(v) ... and NO patch was written"               "$VW/.agents/reviews/0016-v.patch"
want_not_in "(v) ... and no reviewer was launched"           "$out" "running on"
out="$(EDITOR=true "$AW" diff 0016-v 2>&1)"; rc=$?
want_eq "(v) aw diff dies on it too"                         "$rc" "1"
want_in "(v) ... for the same reason"                        "$out" "commits touch fenced paths"

# --- (w) the roots are separate, and opencode is granted neither of them --
case "$WTP" in
  "$WTU"/*) bad "(w) the profiled root must NOT be under the unprofiled root" ;;
  *)        ok  "(w) the profiled root is not under the unprofiled root" ;;
esac
rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_implementer="deepseek/deepseek-v4-pro" \
       LOOM_MAX_ATTEMPTS=1 "$AW" run 0017-w 2>&1)"; rc=$?
want_eq   "(w) an opencode implementer runs"              "$rc" "0"
want_file "(w) ... and the stub recorded its grant"       "$TMP/called-opencode.log"
oc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in     "(w) the grant is the role's OWN worktree"    "$oc" "$WTU/0017-w/**"
want_not_in "(w) ... not the whole worktree root"         "$oc" "\"$WTU/*\":\"allow\""
want_not_in "(w) ... and never the profiled root"         "$oc" "$WTP"
# A trailing slash in $LOOM_WORKTREES must not turn the profiled root into a
# CHILD of the unprofiled one ("/x/wt/" + "-profiled" = "/x/wt/-profiled").
out="$(LOOM_WORKTREES="$TMP/wt3/" LOOM_MODELS_implementer="claude-sub" \
       LOOM_MODELS_reviewer="codex-sub" "$AW" new 0023-ae --fence-profile codex 2>&1)"; rc=$?
want_eq   "(w) a trailing slash in LOOM_WORKTREES is stripped"  "$rc" "0"
want_file "(w) ... so the profiled root is a sibling"           "$TMP/wt3-profiled/0023-ae/core/lib.rs"
want_absent "(w) ... and never a child of the unprofiled root"  "$TMP/wt3/-profiled"
out="$(LOOM_WORKTREES="$TMP/wt3/" "$AW" drop 0023-ae 2>&1)"; rc=$?
want_eq   "(w) ... and aw drop finds it there"                  "$rc" "0"
want_absent "(w) ... and removed it"                            "$TMP/wt3-profiled/0023-ae"

rm -f "$TMP/called-opencode.log"
out="$(DEEPSEEK_API_KEY=stub LOOM_MODELS_scout="deepseek/deepseek-v4-flash" \
       "$AW" scout "where is main" 2>&1)"; rc=$?
sc="$(cat "$TMP/called-opencode.log" 2>/dev/null || true)"
want_in     "(w) the scout grant is its own mirror"       "$sc" "$WTU/_scout/**"
want_not_in "(w) ... not the whole worktree root"         "$sc" "\"$WTU/*\":\"allow\""
want_not_in "(w) ... and never the profiled root"         "$sc" "$WTP"

# --- (x) every fallback attempt re-reconciles ----------------------------
# Attempt 1 relaxes the sparse checkout and returns 429; attempt 2 must see
# the widened tree, not the tree as it was before the loop started.
out="$(LOOM_MODELS_implementer="claude-sub codex-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0018-x --fence-profile codex 2>&1)"; rc=$?
want_eq "(x) setup: a profiled worktree"                  "$rc" "0"
codex_before="$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)"
out="$(AW_TEST_RELAX_SPARSE=1 LOOM_MAX_ATTEMPTS=1 \
       LOOM_MODELS_implementer="claude-sub codex-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" run 0018-x --fence-profile codex 2>&1)"; rc=$?
want_eq "(x) attempt 1 widened the tree, so attempt 2 is refused" "$rc" "1"
want_in "(x) ... the first model did fall back"           "$out" "looks rate-limited"
want_in "(x) ... naming the path the profile does not release" "$out" "ios/App.swift"
want_in "(x) ... as a profile mismatch"                   "$out" "does not release"
want_eq "(x) ... and the SECOND model never launched"     \
        "$(wc -l < "$TMP/called-codex.log" 2>/dev/null || echo 0)" "$codex_before"

# --- (y) aw land inspects the commits it is about to publish -------------
out="$("$AW" new 0019-y 2>&1)"; rc=$?
want_eq "(y) setup: an unprofiled worktree"               "$rc" "0"
YW="$WTU/0019-y"
git -C "$YW" sparse-checkout disable
echo "// smuggled" >> "$YW/core/lib.rs"
git -C "$YW" add core/lib.rs
git -C "$YW" commit -qm "touch a fenced path"
git -C "$YW" sparse-checkout init --no-cone
git -C "$YW" sparse-checkout set '/*' '!core/**' '!ios/**' '!docs/audits/**'
head_before="$(git rev-parse HEAD)"
out="$("$AW" land 0019-y 2>&1)"; rc=$?
want_eq "(y) land refuses a branch whose commits touch a fenced path" "$rc" "1"
want_in "(y) ... naming the path"                         "$out" "core/lib.rs"
want_eq "(y) ... and nothing was merged"                  "$(git rev-parse HEAD)" "$head_before"
want_file "(y) ... and the worktree is still there"       "$YW/.agents/gate.sh"
# ... and a [hand] path is refused even WITH a profile, when that profile does
# not release it. 'audit' releases docs/audits/** only, to claude only.
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="claude-sub" \
       "$AW" new 0020-y2 --fence-profile audit 2>&1)"; rc=$?
want_eq "(y) setup: a worktree under the 'audit' profile" "$rc" "0"
Y2W="$WTP/0020-y2"
printf '\n# touched\n' >> "$Y2W/.agents/gate.sh"
git -C "$Y2W" add .agents/gate.sh
git -C "$Y2W" commit -q --no-verify -m "touch a hand path the profile does not release"
head_before="$(git rev-parse HEAD)"
out="$("$AW" land 0020-y2 --fence-profile audit 2>&1)"; rc=$?
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
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
want_eq "(z) a release that swallows a still-fenced pattern is refused" "$rc" "1"
want_in "(z) ... naming the pattern that stays fenced"    "$out" "core/wallet-sdk/**"
want_in "(z) ... and why"                                 "$out" "never reach the worktree"
restore_zones

# --- (aa) the escape is gone on aw run too, not only aw check ------------
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" run 0008-k --fence-profile codex 2>&1)"; rc=$?
want_eq "(aa) with the record gone, aw run dies as well"  "$rc" "1"
want_in "(aa) ... telling the operator to restore it BY HAND" "$out" \
        "git config branch.agent/0008-k.fenceprofile codex"
want_in "(aa) ... or to start clean"                      "$out" "aw new 0008-k --fence-profile codex"
want_eq "(aa) ... and aw wrote no record on its own"      \
        "$(git config branch.agent/0008-k.fenceprofile 2>/dev/null || true)" ""

# --- (ab) a providers entry that can never be a provider_of() output -----
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.capital]
release = ["core/**"]
providers = ["Claude"]
TOML
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
want_eq "(ab) providers = [\"Claude\"] is refused at parse" "$rc" "1"
want_in "(ab) ... as not a provider the harness can produce" "$out" "not a provider"
want_in "(ab) ... with the lower-case suggestion"          "$out" "did you mean 'claude'"
restore_zones
cat >> .agents/zones.toml << 'TOML'

[fence_profiles.modeltoken]
release = ["core/**"]
providers = ["claude-sub"]
TOML
out="$("$AW" zone backend/main.go 2>&1)"; rc=$?
want_eq "(ab) providers = [\"claude-sub\"] is refused too"  "$rc" "1"
want_in "(ab) ... named as a model token, not a provider"   "$out" "is a MODEL token"
restore_zones

# --- (ac) the task-file header block -------------------------------------
out="$("$AW" new 0021-ac 2>&1)"; rc=$?
want_eq "(ac) a declaration under a leading blank line is honoured" "$rc" "1"
want_in "(ac) ... so the flag is demanded"                "$out" "aw new 0021-ac --fence-profile codex"
want_absent "(ac) ... and nothing was created"            "$WTU/0021-ac"
out="$(LOOM_MODELS_implementer="claude-sub" LOOM_MODELS_reviewer="codex-sub" \
       "$AW" new 0021-ac --fence-profile codex 2>&1)"; rc=$?
want_eq   "(ac) ... and a trailing '# comment' is not part of the name" "$rc" "0"
want_file "(ac) ... so the release took effect"           "$WTP/0021-ac/core/lib.rs"
out="$("$AW" new 0022-ad 2>&1)"; rc=$?
want_eq "(ac) a near-miss key does not opt a task in"     "$rc" "0"
want_in "(ac) ... but aw new says it was not honoured"    "$out" "not honoured"
want_in "(ac) ... quoting the line it found"              "$out" "Fence-profile : codex"
want_absent "(ac) ... and it released nothing"            "$WTU/0022-ad/core/lib.rs"

# --- (j)/(t) doctor lists the profiles, and touches no network ------------
out="$(timeout 180 "$AW" doctor 2>&1 || true)"
want_in "(j) doctor lists the profile"                    "$out" "fence profile 'codex'"
want_in "(j) doctor names its providers"                  "$out" "claude codex"
want_in "(j) doctor still reports the fence"              "$out" "fence: 3 pattern(s)"
want_in "(j) doctor names the providers a profile refuses" "$out" "providers this profile does not allow"
want_absent "(t) doctor made no network call"             "$TMP/called-curl.log"

echo ""
echo "tests/fence-profiles.sh: $npass passed, $nfail failed"
[ "$nfail" -eq 0 ]
