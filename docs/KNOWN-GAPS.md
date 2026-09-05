# Known gaps

Holes an adversarial review found in the harness. Two of the five are **closed
on this branch** (gaps 1 and 5) and are kept here because each closure has a
cost or a residual worth naming; the rest are **not fixed**, and are written
down so that the fence-profile work is not mistaken for closing them and so
they are not re-discovered from scratch.

None of them is *caused* by fence profiles — but gap 4's consequence is
**widened** by profiles, because a worktree under a profile holds paths the
fence normally removes, and a grant that reaches another worktree therefore
reaches more than it used to. Round 2 narrowed that grant and split profiled
worktrees onto their own root; what is left of gap 4 is a confirmation, and it
is written up that way below.

Every gap carries a `bin/loom:<line>` anchor as of this commit. Line numbers
drift; the quoted text is the durable handle, so grep for it.

---

## 1. `loom guard` read the agent's own copy of `zones.toml` — CLOSED

**Status: fixed on this branch.** Kept here with its cost, and with the one
part of the lookup that is still the agent's.

**What it was.** `$ROOT` was `git rev-parse --show-toplevel` and `AGENTS_DIR`
was `$ROOT/.agents`, so a command running inside an agent worktree read that
worktree's copies. `cmd_guard` runs as a pre-commit hook there, so every zone
lookup read `<worktree>/.agents/zones.toml` — a file the agent can edit. The
same derivation had a bigger consequence than the guard: `cd <a worktree> && loom
new t5` fenced the new task with the agent's `zones.toml` (an emptied one means
no fence at all) and `.`-sourced the agent's `.agents/loom.env` as shell, in
your environment.

**What closes it.** `bin/loom:117` (`ROOT="$(cd "$(dirname "$_common")" …)"`,
from `git rev-parse --git-common-dir` at `bin/loom:113`) and `bin/loom:133`
(`AGENTS_DIR="$ROOT/.agents"`); the guard's own reads are `bin/loom:1536`
onward. `$ROOT` is now the **main checkout** for every command:
`git rev-parse --git-common-dir` answers `.git` from the main checkout and the
absolute path of the main `.git` from a linked worktree, so its parent is the
main checkout either way — the same derivation the operator record is keyed by.
Everything policy-shaped is read from there: `zones.toml` (zones, fence,
profiles), `loom.env`, `.opencode/`, and `.agents/gate.sh`.

One thing still comes from the invoking tree, and only one: **`loom guard`'s
subject.** The commit is happening in that worktree, so the branch, the staged
file list and the tree the reconciler inspects are read from `$INVOKED_ROOT`
(`bin/loom:109`)
while the zones they are judged by come from `$ROOT`. `loom` says so in one line
whenever the two differ. `tests/fence-profiles.sh` (av) asserts both halves:
`loom new` from inside a worktree with an emptied `zones.toml` still applies the
full fence, and a `loom.env` planted there is never sourced.

**The cost.** A repo whose `zones.toml` legitimately changes *on a branch* is
judged by the main checkout's copy until that change lands — which is the point
(it is a hand-zone file), but it does mean a zones change cannot be tested by
an agent from inside its own worktree.

**The residual.** The record lookup itself is still keyed by
`$XDG_CONFIG_HOME`, and the hook runs in the agent's session, so that variable
is the agent's. A process that sets it points the lookup at a record of its
own. That is not worth plugging: the entire hook is dominated by `git commit
--no-verify`, which needs no environment at all. The guard is a seatbelt;
`loom land`'s checks of the commits are the lock.

---

## 2. `loom plan` runs the architect unfenced, in your own tree

**Where.** `bin/loom:2593`, in `cmd_plan` (`bin/loom:2574`):
`run_role architect "$ROOT" "$prompt"` (and the
interactive leg, `claude --append-system-prompt … "$prompt"`, likewise in
`$ROOT`). The architect's chain at every tier ends in cheap third-party
providers — `zai-coding-plan/glm-5.3`, `moonshotai/kimi-k2.5`,
`deepseek/deepseek-v4-pro` — and none of the fence machinery is on this path:
no worktree, no sparse checkout, no `fence_reconcile`.

**Why it is not urgent.** The architect prompt tells it to use `loom scout`
(which *is* fenced, via the `_scout` mirror) rather than read source, and it is
told to write only under `.agents/`. That is a prompt, not a boundary.

**Suggested fix.** Give the architect the same fenced mirror the scout gets —
`scout_root` already builds and refreshes one; point `cmd_plan`'s headless leg
at it. The interactive `claude` leg is a deliberate exception (it is your own
CLI, on your own subscription, in your own tree) and should stay, but should
say so out loud.

---

## 3. `.agents/loom.env` is sourced as shell

**Where.** `bin/loom:168`:

```sh
if [ -f "$ROOT/.agents/loom.env" ]; then set -a; . "$ROOT/.agents/loom.env"; set +a; fi
```

`.agents/**` matches no zone in the shipped `zones.toml`, and unmatched paths
resolve to **assist** — so an agent may edit it, and this file is `.`-sourced,
in your shell, with your environment. `$(…)` in it executes. The same file is
present in every agent worktree.

**Why it is not urgent.** It only fires for a repo that has a `loom.env` at all,
it is a tracked file (so the change shows up in the diff you review), and an
agent that can write files in your checkout has other options.

**Some variables are carved out of it**, because for those the file is not
merely a risk, it is a bypass:

- `WT_ROOT_PROFILED` — where a profiled worktree's released paths land. It is
  derived from the normalised `$LOOM_WORKTREES` and a preset that differs is a
  refusal; `loom.env` may still set `LOOM_WORKTREES` itself, which moves both
  roots together and keeps them siblings.
- `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`,
  `OPENCODE_PERMISSION`, `OPENCODE_DISABLE_PROJECT_CONFIG` — which config
  opencode loads, and therefore `provider.<name>.options.baseURL` (the provider
  *identity* a fence profile's `providers` list is built on) and the role
  prompts. All five are snapshotted before this file is sourced and restored
  after, with a WARN naming any the file tried to set. A caller that exports
  them wins untouched, as before; it is the file that does not.
  `OPENCODE_CONFIG_CONTENT` — a whole config inline in a variable, with no file
  for `loom` to point at — is additionally stripped from every opencode launch,
  caller included.
- The file is also a `[hand]` path in the shipped `zones.toml` template now,
  alongside `.agents/gate.sh` and `.agents/zones.toml`, so `loom land` refuses a
  branch that changed it. That is a review boundary, not a sandbox: the file
  still runs as shell when you invoke `loom`.

There used to be a second, `LOOM_BASE_REF`: the ref the security base was
measured from, snapshotted before the file was sourced and restored after. That
variable no longer exists. The base every history check uses is the **operator
record** (`${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/<key>/tasks/<task>`),
written by `loom new`, which no file in the repository takes part in.

**This gap is the residual the operator record concedes.** That directory is in
`$HOME`, and the capability this gap describes — an agent that can write files
in your checkout, and a file in your checkout that runs as shell in your
environment — reaches `$HOME` too. The state directory is therefore **operator
integrity, not tamper-proofing**: it removes the class of "one `git config` or
`git update-ref` inside the worktree rewrites the input to its own security
check", which was a much cheaper attack than this one. It does not claim more.

The carve-out does not fix the gap either. Anything else in that file still
runs as shell, in your environment.

**Suggested fix.** Parse it instead of sourcing it: read `KEY=VALUE` lines,
reject anything else, and `export` the pairs. Losing shell syntax there costs
the `${VAR:-default}` idiom the README documents, so either the parser handles
that one form or the README changes with it.

---

## 4. The narrowed `OPENCODE_PERMISSION` grant is unconfirmed against a live opencode

**Status: narrowed in round 2, not yet confirmed on a live opencode.** This gap
used to read "granted for the whole worktree root". It is not that any more;
what is left is a confirmation.

**Where.** `bin/loom:615`, in `run_headless` (`bin/loom:528`), the opencode leg:

```sh
perm="$(printf '{"external_directory":{"%s/*":"allow","%s/**":"allow"}}' "$wd" "$wd")"
```

**What it was.** The grant named `$WT_ROOT`, i.e. *every* agent worktree, on
the argument that every path under that root is a fenced agent worktree and so
the grant "does not widen the read-fence". Fence profiles broke that argument:
another task's worktree under the same root may hold paths released by a
profile this run does not have, and the run that reads them may be on a
provider that profile does not allow. **Profiles widen this gap's
consequence** — which is why it was narrowed rather than left alone.

**What it is now.** Two changes, and the second is the load-bearing one:

1. the grant is the role's own resolved `$wd`, nothing else; and
2. a profiled task's worktree lives under a *separate* root
   (`${LOOM_WORKTREES}-profiled`, a sibling of the ordinary root, never a
   child), so an unprofiled run — or the shared `_scout` mirror, which stays
   under the ordinary root — cannot be granted a directory that *contains* a
   profiled worktree even if a future edit widens the grant again. The
   separation is the hard guarantee; the narrowing is defence in depth.
   `tests/fence-profiles.sh` (w) asserts both.

**What is still owed.** Narrowing to `$wd` was tried once before and is what
caused the failure the wide grant fixed: opencode's permission parser reported
the worktree's **parent** as the external directory, so a `cd <subdir> && perl
-pi …` edit inside the worktree was auto-REJECTED in a headless run. It was
narrowed anyway this time, because the root separation makes the wide grant
indefensible and the failure mode is loud rather than silent. It has **not**
been re-checked against a current opencode.

**The exact symptom to look for.** An opencode implementer that writes nothing
and whose log says the run was denied an external directory — typically a
rejected permission for the worktree's parent path, after a command that
changed directory inside the worktree (`cd <subdir> && …`, `perl -pi`, an
editor tool given a relative path). The gate then fails for want of any edit,
and `loom` burns every attempt. If that appears: add the minimum extra entry
opencode's parser needs (its *parent*, i.e. the worktree root of THAT task's
kind) rather than reverting to `$WT_ROOT`, and record here which one it was.

---

## 5. opencode's project config — CLOSED, with a cost and a residual

**Status: fixed on this branch.** Recorded here because the fix changes what
opencode reads, and because the residual is not zero.

**What it was.** opencode resolves its project config from the current working
directory, which for every opencode role is the agent's own worktree:
`<worktree>/opencode.json` and `<worktree>/.opencode/opencode.json`, both
tracked files the agent can rewrite mid-run. That file carries
`provider.<name>.options.baseURL` — the provider *identity* that a fence
profile's `providers` list is built on — and the agent definitions that supply
each role's prompt. An agent could therefore answer as `deepseek` from a host
of its choosing, or hand itself a different role prompt, and nothing in `loom`
would see a change: `loom` checks the model TOKEN against the profile, and the
token would still say `deepseek/deepseek-v4-pro`.

**What closes it.** opencode 1.x has two environment knobs, and both are
needed (verified against the installed 1.18 binary, whose config loader merges
`OPENCODE_CONFIG` *before* the project files — so that variable alone leaves
the worktree's copy winning key by key):

```sh
OPENCODE_CONFIG=$ROOT/.opencode/opencode.json     # (and OPENCODE_CONFIG_DIR)
OPENCODE_DISABLE_PROJECT_CONFIG=1
```

`run_headless`'s opencode leg (`bin/loom:646`) sets the **disable
unconditionally**, on every opencode invocation — implementer, reviewer, scout
and architect alike — and names the operator's config only when one exists.
That is a round-4 correction: the disable used to be conditional on
`$ROOT/.opencode/opencode.json` existing, which had it exactly backwards. A
repo with no operator config is the repo where the worktree's own
`opencode.json` is the ONLY config, i.e. the one place where an agent-written
project config would have been read in full. A caller that sets
`OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` itself wins untouched, the same rule
`OPENCODE_PERMISSION` already had; the disable is the one thing no caller turns
off. `tests/fence-profiles.sh` (ao) asserts both variables on all four legs and
asserts the disable in a repo with no operator config at all.

**The cost.** With the project config off, opencode no longer reads the
worktree's `AGENTS.md`/`CLAUDE.md`, the worktree's `.opencode/` directory, or a
project-local plugin. Role prompts now come from `$ROOT/.opencode/prompts/`
(via `{file:./prompts/…}` in the operator's config) — which is the copy the
`claude` and `codex` legs already used, so this makes the three legs agree
rather than diverge. If a repo's opencode roles depended on `AGENTS.md`
reaching the model, that content has to move into the role prompt. Since the
disable is unconditional, a repo with **no** `$ROOT/.opencode/opencode.json`
pays that cost with nothing to replace it: opencode there runs on its own
global config, and `--agent <role>` falls back to opencode's default agent. A
repo that wants role definitions must keep them in the operator's copy.

**The residual.** `$ROOT/.opencode/opencode.json` is a file in *your* checkout.
Nothing an agent runs touches your checkout — except `loom plan`'s architect,
which is gap 2 above, and anything that gets to `.agents/loom.env`, which is
gap 3. Closing this one does not close those, and the same file is the reason
they matter slightly more than they did.
