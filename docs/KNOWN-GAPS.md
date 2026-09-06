# Known gaps

Holes an adversarial review found in the harness. Two of the six are **closed
on this branch** (gaps 1 and 5) and are kept here because each closure has a
cost or a residual worth naming; the rest are **not fixed**, and are written
down so that the fence-profile work is not mistaken for closing them and so
they are not re-discovered from scratch. Gap 6 is round 7's, narrowed again in
round 8: it is a residual by construction rather than a hole nobody got to.

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

**What closes it.** `bin/loom:137` (`ROOT="$(cd "$(dirname "$_common")" …)"`,
from `git rev-parse --git-common-dir` at `bin/loom:133`) and `bin/loom:153`
(`AGENTS_DIR="$ROOT/.agents"`); the guard's own reads are `bin/loom:2153`
onward. `$ROOT` is now the **main checkout** for every command:
`git rev-parse --git-common-dir` answers `.git` from the main checkout and the
absolute path of the main `.git` from a linked worktree, so its parent is the
main checkout either way — the same derivation the operator record is keyed by.
Everything policy-shaped is read from there: `zones.toml` (zones, fence,
profiles), `loom.env`, `.opencode/`, and `.agents/gate.sh`.

One thing still comes from the invoking tree, and only one: **`loom guard`'s
subject.** The commit is happening in that worktree, so the branch, the staged
file list and the tree the reconciler inspects are read from `$INVOKED_ROOT`
(`bin/loom:129`)
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

**Two more seatbelt limits, recorded rather than fixed.**

- **The installed hook exits 0 when `loom` is not on `PATH`.** It says so on
  stderr and carries on, so a repo whose `PATH` has lost `loom` commits
  hand-zone paths with no guard at all. That is main's decision and it stays:
  the alternative — failing every commit in a repo where the harness is simply
  not installed — is worse, and `loom doctor` FAILs on the pre-rename `aw`
  variant of exactly this branch for exactly this reason. Read it as: the
  guard's *absence* is a `doctor` finding, not a commit-time error.
- **`core.hooksPath` decides whether the hook runs at all**, and it lives in the
  shared `.git/config` (gap 6). One `git config core.hooksPath /dev/null` from
  inside a worktree disarms the guard — a strictly cheaper `--no-verify`.

---

## 2. `loom plan` runs the architect unfenced, in your own tree

**Where.** `bin/loom:3511`, in `cmd_plan` (`bin/loom:3492`):
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

**Where.** `bin/loom:227`:

```sh
if [ -f "$ROOT/.agents/loom.env" ]; then set -a; . "$ROOT/.agents/loom.env"; set +a; fi
```

This file is `.`-sourced, in your shell, with your environment: `$(…)` in it
executes, on every single `loom` invocation. The same file is present in every
agent worktree, and it is a *tracked* file, so an agent branch can carry a
change to it.

What has changed since this gap was first written is only the review boundary
around that fact, and it is worth being exact about how thin it is.
`.agents/loom.env` is a `[hand]` path in the **shipped** `zones.toml` template
now (it was not — `.agents/**` matched no zone at all, and unmatched paths
resolve to `assist`), so in a repo that uses the template the pre-commit guard
blocks the commit and `loom land` refuses the branch's commits. That is a
review boundary and nothing more: a consuming repo that has not copied the entry
has neither (`docs/fence-profile-consumer-snippet.md` § 1b), the guard is
skippable with `--no-verify`, and **the file still runs as shell when you type
any `loom` command**, landed or not — a change sitting uncommitted in your own
checkout has never needed to pass a review at all.

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

**A third set is cleared rather than restored**: git's own environment, unset
once both env files have been sourced. This file is `.`-sourced under `set -a`,
so one `GIT_DIR=` line in a landed `loom.env` re-aimed every git subprocess
`loom` runs: measured, the recorded base became a decoy repository's `HEAD` and
the worktree was cut from the decoy. Two halves:

- **the LOCATION variables** — `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`,
  `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
  `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`,
  `GIT_CEILING_DIRECTORIES`, plus the `GIT_AUTHOR_*`/`GIT_COMMITTER_*`
  identity;
- **the CONFIG variables**, which are a code channel rather than a location one:
  `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` and every
  `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` still standing, `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM`, `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`,
  `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`,
  `GIT_ASKPASS` and `SSH_ASKPASS`. Each of the last eight names a program git
  runs; the first four inject config at the highest precedence git has.

`loom` then exports **its own** `GIT_CONFIG_PARAMETERS` over the top — see
gap 6 and ARCHITECTURE.md § 5 for what is in it and what it cannot reach.

**One carve-out, and it is git's, not a caller's.** `GIT_INDEX_FILE` (with
`GIT_DIR`, `GIT_WORK_TREE`, `GIT_PREFIX` and the identity variables) is
snapshotted **before either env file is sourced** and restored **after** the
unset — the same shape the `OPENCODE_*` set has. Without that, round 6's
blanket unset broke `loom guard`: git runs a pre-commit hook with a
**temporary** index for `git commit -a`, `git commit -- <path>`, `--only` and
`--include`, and names it in `$GIT_INDEX_FILE`. Unset, `cmd_guard`'s
`git diff --cached --name-only` read the standard index, found nothing staged,
and exited 0 in silence — measured: a `git commit -a` touching a hand-zone path
committed cleanly, with the guard printing nothing at all
(`tests/fence-profiles.sh` (bg)). A landed `loom.env` still cannot inject any of
them, because the snapshot was taken before it was read; a *caller* that exports
`GIT_DIR` itself is indistinguishable from git doing so and wins, which is the
same rule `OPENCODE_CONFIG` has and the same residual gap 1 already concedes for
the hook's `$XDG_CONFIG_HOME`.

**What the record now carries, and what that is worth.** It is not just the
base any more. `base` is the commit every fence and hand history check is
measured from; `reviewed` is the tip `loom check` last handed to a reviewer,
and `loom land` refuses to publish any other; `origin`, `fetch` and `pushurl`
are the remote URL, the refspec and the **push destination** the task was
created against, and `loom rebase` / `loom land --pr` refuse a changed one
before they contact a remote at all. `pushurl` is round 7's, and it is a
separate fact from `origin` on purpose: `remote.origin.pushurl`, and a
`url.<decoy>.pushInsteadOf = <the real origin>` rewrite, each redirect a push
while `git remote get-url origin` goes on answering the URL the record pinned —
so a `loom land --pr` published the branch to a host of the worktree's choosing
and reported success (`tests/fence-profiles.sh` (bh)). The file is validated on
both sides — one field per line, each field once, every key in a fixed list, no
control character in any value — because all three of those arrive from
`.git/config`, where a newline inside a value would append a second field to
it.

**This gap is the residual all of that concedes.** The directory is in `$HOME`,
and the capability this gap describes — an agent that can write files in your
checkout, and a file in your checkout that runs as shell in your environment —
reaches `$HOME` too. The record is therefore **operator integrity, not
tamper-proofing**: it removes the class of "one `git config` or `git
update-ref` inside the worktree rewrites the input to its own security check",
which was a much cheaper attack than this one, and it now removes "a git config
VALUE writes a field of that record" as well. It does not claim more. An agent
that reaches `$HOME` can write the record, and then `reviewed` says whatever it
likes.

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

**Where.** `bin/loom:1215`, in `run_headless` (`bin/loom:1128`), the opencode leg:

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

`run_headless`'s opencode leg (`bin/loom:1246`) sets the **disable
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

**The residual.** `$ROOT/.opencode/opencode.json` is a file in *your* checkout,
and "your checkout" is not out of an agent's reach. Three routes lead there,
and only the third was ever narrow:

1. **A landed agent branch.** `loom land` merges the branch INTO your checkout,
   so a commit that rewrote `.opencode/opencode.json` on the branch becomes
   your copy — the one every later task's opencode runs against, provider
   `baseURL` and role prompts included. What stops it is the `[hand]` zone:
   `.opencode/**` is a hand path in the shipped `.agents/zones.toml`, the
   pre-commit guard blocks the commit, and `loom land` re-checks the branch's
   COMMITS against `[hand]` because the guard runs in the agent's own context
   where `--no-verify` exists. That check is the lock; the guard is the
   seatbelt. A consuming repo that has not copied the entry has neither
   (`docs/fence-profile-consumer-snippet.md` § 1b).
2. **`.agents/loom.env`**, which is `.`-sourced as shell in your environment —
   gap 3 above, and a `[hand]` path for the same reason.
3. **`loom plan`'s architect**, which runs unfenced in `$ROOT` — gap 2 above.

Closing this one does not close those, and the same file is the reason they
matter slightly more than they did.

---

## 6. `.git/config` is shared, and some of its keys name programs

**Status: narrowed in round 7, pinned in round 8, widened to every scope git
actually reads in round 9, and a residual by construction.** This one cannot be
closed from outside git; what follows is the boundary, drawn honestly.

**Where.** `bin/loom:366` (the `GIT_CONFIG_PARAMETERS` export) and
`bin/loom:376` (`GIT_PAGER=cat`); `bin/loom:752` onward (the config pin:
`config_sidecar`, `config_py`, `config_snapshot`, `require_recorded_config`);
and the `--no-ext-diff` / `--upload-pack=` / `--receive-pack=` spelled out at
the diff, fetch and push call sites.

**What it is.** A linked worktree shares the git directory with the main
checkout, so `.git/config` is writable from inside an agent's tree with one
command. Several of its keys do not describe a preference, they name a
**program git runs** — in your session, the next time `loom` touches the
repository: `core.pager`, `pager.<cmd>`, `core.fsmonitor`, `core.sshCommand`,
`diff.external`, `remote.<n>.uploadpack` / `receivepack`, `core.editor`,
`sequence.editor`, `core.hooksPath`, `gpg.program`, per-`.gitattributes`
`filter.*` / `diff.*.textconv` / `merge.*.driver`, and `include.path` /
`includeIf.*`, which pull in a whole further config file of the writer's
choosing and bring all of the above with it. Two of them are worse than a
program: **`credential.helper`** (a `!<command>` is a shell) and
**`core.askPass`** are handed your credential as well as executed, so they
harvest a token as readily as they run one — and `loom land --pr` is the one
command here that authenticates to a host.

Measured against the pre-fix dispatcher, a `core.fsmonitor`, a `diff.external`
and a `remote.origin.receivepack` planted from a worktree all executed during an
ordinary `loom check` / `loom diff` / `loom land --pr`
(`tests/fence-profiles.sh` (bi)); a `pager.log=<script>` survived
`core.pager=cat` (see below); and a `credential.helper` planted from a worktree
rode into `loom land --pr` untouched ((bk)).

**And it PERSISTS.** `.git/config` is not per-task and not per-worktree: it
outlives `loom drop`, it is the same file the next `loom new` sees, and nothing
in this system used to look at it as a whole. A key planted during task A was
still there for task B, C and every one after.

**What closes most of it.** Two layers.

*One:* `loom` exports its own `GIT_CONFIG_PARAMETERS` — the variable `git -c`
uses, which outranks every config *file* — for every git subprocess it spawns,
and clears git's own `GIT_*` environment first (gap 3). Three keys do not obey
that variable, and all three were measured rather than assumed:

- `diff.external=` (empty) is **not** "unset"; it is a command named `""`, and
  `git -c diff.external= diff` dies on every hunk. `--no-ext-diff`
  (`--no-textconv` alongside it) is the lever that works.
- `remote.<n>.uploadpack` / `receivepack` are collected into a list where git
  keeps the **first**, and config files are read before the variable — so the
  config wins. `--upload-pack=` / `--receive-pack=` on the fetch and the push
  are the lock.
- `pager.<cmd>` beats `core.pager`, because `git_pager()` consults
  `pager_program` — already set from `pager.<cmd>` by `check_pager_config()` —
  before it ever reads `core.pager`. `GIT_PAGER=cat` and a `pager.<cmd>=cat`
  per subcommand both win; loom sets both. A string-valued `pager.<cmd>` also
  turns paging *on* for subcommands that never page, plumbing included
  (`update-ref`, `merge-base`, `patch-id` all ran a planted pager).

*Two, and it is the one that changes the shape of the gap:* the **whole git
config is pinned to the task** — and "the whole git config" is not
`git config --local --list`. git reads **three** files here and a linked
worktree can write two of them:

- `local` — `$GIT_COMMON_DIR/config`, shared by every worktree;
- `worktree-main` — `$GIT_COMMON_DIR/config.worktree`, the **main checkout's**
  own scope. A `core.hooksPath` there runs your hooks, in your checkout, during
  `loom land`'s merge;
- `worktree-task` — `$GIT_COMMON_DIR/worktrees/<wt>/config.worktree`, the task
  worktree's own scope, one `git config --worktree <k> <v>` from inside the
  agent's tree.

Both `config.worktree` files are live whenever `extensions.worktreeConfig` is
enabled, and **loom itself enables it** on the first `git sparse-checkout init`
in a repository (measured, git 2.34). Neither appears in
`git config --local --list`. Nor do the keys an **include** brings: `--list`
prints `include.path=<file>` and `includeIf.<cond>.path=<file>` as *pointers*,
and only the full all-scopes `git config --list` shows the `core.hooksPath` the
target pulled in (measured, git 2.34.1) — so a pointer pinned once buys the
writer a target they can edit for free afterwards.

So `loom new` records `config=<sha256 of all three scopes' sorted,
NUL-separated `--list --null` output, each entry tagged with its scope, plus one
`include:<resolved path>:<sha256 of its raw bytes>` record for every file in the
include closure (recursively; `~` expanded; a relative path resolved against the
directory of the file that names it; a missing target recorded as
`(missing)`)>` in the operator record, with the full list beside it as
`<task>.gitconfig` (0600) so a mismatch is a diff — one that names the scope —
and not two digests. It is recomputed and compared **before the first fence
operation of every command**, before every model launch (per *attempt*), before
`land`'s merge and push, before `rebase`'s fetch and replay, and before
`check`/`diff` write the review patch. A change is a refusal that prints the
`-`/`+` lines; `--accept-config` is the only escape, and it prints the same diff
and re-records. `loom new` **refuses** `--accept-config` (it is the command that
pins) and instead says what it pinned: `loom: pinned N local + M worktree config
entries`, plus a WARN naming the targets whenever an include is present.
`loom drop` deliberately does not check the pin at all — it runs no model,
publishes nothing, and removes the worktree, branch and record, so refusing to
clean up over a moved config would strand released paths on disk.

*Why the ordering is part of it.* `fence_reconcile` -> `fence_apply` ->
`git sparse-checkout set` is a **working-tree update**: git materialises every
path the new pattern list admits, and materialising a path runs the **smudge**
side of whatever `filter.<d>` a `.gitattributes` in that worktree selects. That
file is agent-written and uncommitted is enough. With the pin read one line
*after* the reconcile, the planted program ran as the operator before the
refusal (measured; `tests/fence-profiles.sh` (bo)). Every command reads the pin
first now, and `run_role` reads it above its own per-attempt reconcile.

This is what makes `core.hooksPath`, `filter.*`, `merge.*.driver`,
`diff.*.textconv`, `gpg.program`, `credential.helper`, `core.askPass`,
`pager.*`, `include.path` / `includeIf.*` and `core.attributesFile` /
`core.excludesFile` **change-refused**. `core.hooksPath` is still not
*overridden* — the operator's hooks must run — but a worktree can no longer
re-point it under a running task without the next command refusing.

**What is still trusted.** ARCHITECTURE.md § 5 ("What `loom` trusts in
`.git/config`") enumerates it, and it is now three things rather than six:

1. **Whatever the config already said at `loom new`, in every scope the pin
   covers.** The pin is a *change* check, so a repository that already carried a
   hostile `filter.x.clean` — in `.git/config`, in either `config.worktree`, or
   in an included file — has it in the baseline, as does anything
   `--accept-config` was used to re-record. That flag is an operator act with
   the same weight as `--fence-profile`, and `loom` vouches for none of what it
   accepts.
2. **The operator's own `~/.gitconfig` and the system config, and any git config
   scope outside the three the pin covers.** None is in the shared `.git`, none
   is writable from a worktree, and none is pinned — they are the operator's;
   `core.sshCommand` is deliberately read from there.
3. **In-tree `.gitattributes`** — the file half of filter/merge-driver
   selection. It is a `[hand]` path in the shipped template (`.gitattributes`
   and `**/.gitattributes`), so `loom land` refuses a branch that changed it;
   the pre-commit guard is a seatbelt, that check is the lock.

`remote.origin.url`, `.fetch` and the push URL keep their own named checks on
top of the pin, because "the remote was re-aimed" is a clearer message than "the
config changed".

**The cost, stated.** `loom diff` no longer pages by default — `core.pager` is
pinned to `cat` and `GIT_PAGER` to `cat`, so a pager is operator-side now
(`export LOOM_DIFF_CMD="less -R"`). `core.sshCommand` is pinned to the value in
your **global/system** git config when you have one, and to a bare `ssh`
otherwise, so a repo-local identity file is ignored while a personal one is not.
And the pin has a running cost you will notice: `loom` writes local config on
your behalf in exactly two places (the first `sparse-checkout init` in a
repository, and `land --pr`'s `--set-upstream-to`), both of which re-pin
themselves — but **anything else that changes it is a refusal**, including an
agent that ran `git config user.name` in its worktree, and including your own
`git remote add`. `--accept-config`, once, per task, is the answer; it is
deliberately not silent.

**Suggested fix for the rest.** There isn't a variable-shaped one, and the pin
is as far as a *change* check goes. The honest answer for a repository whose
existing `.gitattributes` and filter drivers you would not want to run is the
same as caveat 1's answer to exfiltration: give the agent a separate clone, not
a sparse checkout.
