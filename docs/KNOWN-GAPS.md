# Known gaps

Holes an adversarial review found in the harness. Six of the ten are
**closed on this branch** (gaps 1, 5, 7, 8, 9 and 10) and are kept here because
each closure has a cost or a residual worth naming; the rest are **not fixed**,
and are written down so that the fence-profile work is not mistaken for closing
them and so they are not re-discovered from scratch. Gap 6 is round 7's,
narrowed again in rounds 8 through 12: it is a residual by construction rather
than a hole nobody got to.

§ 11 is a different kind of entry: not a gap of its own, but the
**reconciliation** of an INDEPENDENT external review (draft PR #7, pinned at
`7da0cc4`) against this tip — every id it raised, what it is now, and which
test case holds it.

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

**What closes it.** `bin/loom:164` (`ROOT="$(cd "$(dirname "$_common")" …)"`,
from `git rev-parse --git-common-dir` at `bin/loom:160`) and `bin/loom:189`
(`AGENTS_DIR="$ROOT/.agents"`); the guard's own reads are `bin/loom:3928`
onward. `$ROOT` is now the **main checkout** for every command:
`git rev-parse --git-common-dir` answers `.git` from the main checkout and the
absolute path of the main `.git` from a linked worktree, so its parent is the
main checkout either way — the same derivation the operator record is keyed by.
Everything policy-shaped is read from there: `zones.toml` (zones, fence,
profiles), `loom.env`, `.opencode/`, and `.agents/gate.sh`.

One thing still comes from the invoking tree, and only one: **`loom guard`'s
subject.** The commit is happening in that worktree, so the branch, the staged
file list and the tree the reconciler inspects are read from `$INVOKED_ROOT`
(`bin/loom:156`)
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

**Where.** `bin/loom:6253`, in `cmd_plan` (`bin/loom:6226`):
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

**Where.** `bin/loom:285`:

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

**And the gate is the same class of fact.** `.agents/gate.sh` is a `[hand]`
path and `loom` runs the *operator's* copy of it, never the worktree's — but
what the script itself runs is the repository's build (`make`, `cargo test`,
`go test`, `npm test`), and the repository's build is exactly what the agent
has been editing. A gate is therefore **your build, executing as you, on the
agent's code**, at two points: after every implementer attempt in `loom run`,
and once more before `loom land` merges or pushes. What loom does about it is
narrow and worth stating plainly, so nobody reads more into it: every exported
variable whose NAME matches, **case-insensitively**, `*api_key*`, `*token*`,
`*secret*`, `*password*`, `*passwd*`, `*auth*`, `*credential*`, `*access_key*`,
`*key_id*`, or a provider prefix (`aws_`, `anthropic_`, `openai_`, `codex_`,
`opencode_`, `zai_`, `zhipu_`, `deepseek_`, `moonshot_`) is dropped for the
length of the gate (`run_gate`, `env -u`). Round 17 widened that list from the
four SUFFIXES it used to be (`*_API_KEY`, `*_TOKEN`, `*_SECRET`,
`*_PASSWORD`): the measured survivors were `AWS_SECRET_ACCESS_KEY`,
`AWS_ACCESS_KEY_ID`, `NPM_CONFIG__AUTH`, `DOCKER_AUTH_CONFIG`, `PGPASSWORD`,
`GOOGLE_APPLICATION_CREDENTIALS` and a lowercase `openai_api_key` — every one
of them an ordinary way to hold a credential. The rest of the environment stays
— `PATH`, `HOME`, `GOPATH`, `CARGO_HOME` and everything else a build needs to
exist at all — and there is no sandbox. This is a **NAME-SHAPE filter and
nothing more**: keeping a credential out of a variable name that matches those
patterns, or out of the environment entirely, is not something loom can do for
you, and a credential in a file the gate can read was never in scope. The
comment above `run_gate` used to claim "every variable whose NAME looks like a
credential"; it now says what the code does.

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
unset — the same shape the `OPENCODE_*` set has, and the same shape `TMPDIR`
now has (round 13: `${TMPDIR:-/tmp}` is where every one of loom's own temps
lands, including the authoritative gate log and review patch on their way to
the state directory, so a landed `loom.env` must not be able to aim them at a
directory the agent owns — `tests/fence-profiles.sh` (by)). Without that, round 6's
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

**Where.** `bin/loom:2500`, in `run_headless` (`bin/loom:2395`), the opencode leg:

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

`run_headless`'s opencode leg (`bin/loom:2533`) sets the **disable
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
actually reads in round 9, extended in round 10 to the roles that have no task
(and to the one scope no task pin could reach), tightened in round 11 (the
extension is read as a BOOL, an include's own keys are named, and a repository
baseline no longer moves silently), and a residual by
construction.** This one cannot be
closed from outside git; what follows is the boundary, drawn honestly.

**Where.** `bin/loom:464` (the `GIT_CONFIG_PARAMETERS` export) and
`bin/loom:476` (`GIT_PAGER=cat`); `bin/loom:885` onward (the task pin:
`config_sidecar`, `config_py`, `config_snapshot`, `config_wt`,
`config_summary`, `config_programs` at `bin/loom:1594`,
`require_recorded_config`); `bin/loom:1735` onward (the REPOSITORY baseline:
`repo_config_file`, `repo_config_read`, `repo_config_write`,
`repo_config_repin`, and `require_recorded_config_repo` at `bin/loom:1945`),
read from `scout_root` (`bin/loom:6320`) and `cmd_plan`, written by
`cmd_pin_config` (`bin/loom:6121`); `scout_mirror_config_check`
(`bin/loom:6280`) for the one scope neither pin can cover; and the
`--no-ext-diff` / `--upload-pack=` / `--receive-pack=` spelled out at the diff,
fetch and push call sites.

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
`git config --local --list`. **Whether it is enabled is asked of git**
(`git config --local --type=bool --get`) rather than string-matched: git decides
with `git_config_bool`, which is case-insensitive and reads a *valueless* key as
true, so `True`, `ON` and a bare `worktreeConfig` line each turned both worktree
scopes **off in the pin** while git went on reading them — a `core.hooksPath` in
`config.worktree`, live and unpinned (`tests/fence-profiles.sh` (bt)). Nor do the keys an **include** brings: `--list`
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
entries`, a WARN naming the targets whenever an include is present, and a second
WARN naming every pinned key that names a **program git runs** —
`core.hooksPath`, `credential.*`, `core.askPass`, `filter.*`, `merge.*.driver`,
`diff.*.textconv`/`.command`, `gpg.program`, `pager.*`, `core.attributesFile`,
`core.sshCommand`, `include.*`/`includeIf.*` — values escaped, tagged with the
scope each came from, and **including the keys inside an included file**, tagged
`[include:<path>]`: `--list` shows an include as a pointer and never the keys it
brings, so a `core.hooksPath` one `include.path` away from `.git/config` was
pinned in full and named nowhere. That is residual 1 below, printed at the one
moment it is being adopted. `loom pin-config` prints both blocks too.
`loom drop` deliberately does not check the pin at all — it runs no model,
publishes nothing, and removes the worktree, branch and record, so refusing to
clean up over a moved config would strand released paths on disk.

*And the REPOSITORY baseline never moves silently.* `config_repin` re-records
the repository's baseline as a side effect of pinning a task — at `loom new`,
and at `land --pr` after its own `--set-upstream-to`. Both are places where
loom expects to be adopting its **own** writes, and "expects" is not "checked":
anything else that moved in the same window became the baseline the next
`loom scout` and `loom plan` are judged against, with nothing printed. Every
such re-record now prints the `-`/`+` delta first
(`loom: repository config baseline moved:`), and where the delta **adds** a key
that names a program git runs it is refused rather than adopted:

- **`loom new`** takes no `--accept-config` — it is the command that pins — so
  it cannot weigh such a move at all. It prints the delta, names the key, and
  points at `loom pin-config --accept-config`, which is the command that can.
  The half-built task is unwound.
- **`land --pr`** refuses the re-pin *after* the push, and says so: the branch
  is on origin and nothing about that is undone. What has not happened is the
  re-pin, so the next task-less role still refuses until the operator has read
  the lines and run `loom pin-config --accept-config`.

Additions only: a program key *going away* is not the danger, and refusing that
would turn "put it back" — the escape every one of these refusals names — into
a refusal of its own. A changed *value* is a `-` and a `+` together, so it is
still caught (`tests/fence-profiles.sh` (bs)).

*The include closure carries BYTES, and `includeIf` conditions are not
evaluated.* A digest alone made an edit to an included file print
`include:<path>:<sha-a>` against `include:<path>:<sha-b>` — a refusal with
nothing in it to read, in the one case where the changed bytes are in no file
`git config --list` will show. The record now carries the target's own bytes
beside its sha, so the change is a `-`/`+` **content** diff; path and bytes are
escaped on the way in, because the sidecar is NUL-framed with a newline between
a record's halves and a config file may contain both. The bytes are **capped at
64 KiB** per target: an include target is a config file and a config file is
small, so a bigger one is either a mistake or a way to bloat the sidecar and
drown a refusal in it. Past the cap the value half reads
`(<N> bytes, sha256 <hex>)` — the digest is what the change check runs on
either way, so the refusal still fires and still names the file; it just says
how big it is rather than showing it, and its own keys are not listed. And
**every**
`includeIf.<cond>.path` target is pinned whatever `<cond>` says: `loom` does not
test `gitdir:` / `onbranch:` / `hasconfig:`. That **over-refuses** by design, and
that is the direction to be wrong in — the conditions are evaluated against
state that moves under the agent (the branch, the directory, the config itself),
so "the include stopped applying" and "the include was never there" would look
identical.

*Two roles had no task, so they had no pin.* `loom plan`'s architect runs in
`$ROOT` and `loom scout` runs in the shared `$WT_ROOT/_scout` mirror, and the
scout's run is a **working-tree update** — `fence_apply` -> `sparse-checkout
set`, a `clean`, a `reset --hard` — which is exactly what runs a planted
`filter.<d>.smudge`, with the driver read out of the shared `.git/config`. The
repository now has a **baseline of its own**, `$STATE_DIR/config` plus
`config.gitconfig` beside it (0600), over the `local` and `worktree-main` scopes
and their include closure. It is written wherever a task is pinned and by the
new **`loom pin-config`** (bare: record, or print the diff and refuse;
`--accept-config`: print the diff and re-record), and it is checked by
`scout_root` before it touches the mirror, by `cmd_plan` before the architect
runs, and by `run_role` before every task-less launch, per attempt. `loom drop`
does not remove it: it is the repository's fact, not a task's
(`tests/fence-profiles.sh` (bp)).

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
2. **The operator's own `~/.gitconfig` and the system config.** Neither is in
   the shared `.git`, neither is writable from a worktree, and neither is
   pinned — they are the operator's; `core.sshCommand` is deliberately read
   from there.

   This entry used to say "and any git config scope outside the three the pin
   covers … none is in the shared `.git`", and that was **wrong**. One such
   scope was: `$GIT_COMMON_DIR/worktrees/_scout/config.worktree`, the shared
   `_scout` mirror's own worktree scope. It is in the shared `.git`, it is
   written by one `git -C <mirror> config --worktree`, and it belongs to no task
   — so no task pin covered it and the repository baseline cannot either. It is
   handled by its own check now: `loom scout` **refuses** a mirror whose private
   scope holds anything but the sparse keys git's own `sparse-checkout` writes.
   Refusing rather than silently deleting and recreating the scope is
   deliberate — both neutralise the plant, only one tells the operator that
   something wrote there. The mirror is also `git clean -xdff`'d before every
   reset, because it is shared by every task and every provider and `reset
   --hard` never touches an untracked file (`tests/fence-profiles.sh` (bp)).
3. **In-tree `.gitattributes`** — the file half of filter/merge-driver
   selection. It is a `[hand]` path in the shipped template (`.gitattributes`
   and `**/.gitattributes`), so `loom land` refuses a branch that changed it;
   the pre-commit guard is a seatbelt, that check is the lock.

`remote.origin.url`, `.fetch` and the push URL keep their own named checks on
top of the pin, because "the remote was re-aimed" is a clearer message than "the
config changed".

**AVAILABILITY, and the one thing loom cannot help with.** The pin is an
INTEGRITY check; it does not make git available. `include.path` names a file
git *opens and reads*, and git does that with no timeout — so
`git config --local include.path /path/to/a/fifo` (a FIFO with no writer, or
any other path that blocks on open) **wedges git itself**. Every git command in
that repository hangs, from `git status` to `git config --list` — including the
`git config --list --null` the pin takes its snapshot with, and including the
`git config --unset` you would type to undo it. Measured shape: the process
sits in `open()`, `Ctrl-C` kills the one command and nothing else changes.
`loom` cannot refuse its way out of this, because every path by which it could
notice runs git first; a check that read `.git/config` as bytes before asking
git would still not help, since it is the *next* git command that hangs. It is
also not a privilege escalation — nothing runs, nothing leaks — it is a
denial of service against your own repository, available to anything that can
write the shared `.git/config`, which is every linked worktree.

**loom's OWN reader, on the other hand, does not go near such a target.** The
FIFO above wedges *git*, and nothing loom can do changes that. But the include
closure is walked by `loom` itself — `config_py`'s `closure()` opens each
pointer and reads it — and it used to `open(); read()` whatever the value
named, unbounded. git refuses most of these when it reads the config, so the
pointer never reached loom; an **`includeIf.<cond>.path` whose condition does
not match** is the exception, and it is not an obscure one: git never opens the
target, and `--list` prints the directive as a pointer all the same (measured).
So `git config --local includeIf.gitdir:/nowhere/.path /dev/zero` handed
`closure()` an infinite file with nothing in front of it — not a hang so much
as a memory climb ending at the OOM killer, inside the snapshot whose job is to
REFUSE what the config now says. `closure()` now `os.stat`s the target first
and reads only a **regular file** — a directory, a device, a FIFO or a socket
is recorded as `(not a regular file)`, which is a distinct fact from
`(missing)` (a target that turns from a config file into a FIFO has CHANGED)
and counts as a program-naming hit, because "loom cannot read it" is not "it
contains nothing" — and it reads at most `CAP + 1` bytes, never the whole file
(`tests/fence-profiles.sh` (bv)).

**Recovery is by hand, and it does not involve git**: open
`$GIT_COMMON_DIR/config` (that is `.git/config`, or the absolute path
`git rev-parse --git-common-dir` printed *before* the plant) in an editor,
delete the `include.path` / `includeIf.<cond>.path` line, and save. git works
again on the next command, and the pin then refuses the change on its own terms
— the delta names the include that was there. Worth knowing before you meet it,
because the failure looks like a hung terminal rather than an attack.

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

---

## 7. A worktree was taken on trust — CLOSED

**Status: fixed on this branch (round 10), kept here with its residual.** The
narrative and the three checks live in ARCHITECTURE.md § 5 ("A worktree is
judged only once it is proved to be ours"); this entry exists so that the gap
list is the list, and so the trap is written down where the other traps are.

**Where.** `require_wt_is_ours` (`bin/loom:2229`), called from
`require_wt_on_branch` (which covers `require_worktree`, `loom run` and
`loom loop`), from `cmd_drop` before `git worktree remove`, and from
`scout_root` for the shared mirror.

**What it was.** Every check in this harness reads a worktree through
`git -C "$wt" …`, and *which repository that answers for* is decided by one
line of text in a file the agent owns: `$wt/.git` in a linked worktree is not a
directory, it is a file holding `gitdir: <path>`. Rewrite it and the directory
stops being this repository's worktree — every later `git -C "$wt" …` reads a
git directory of the writer's choosing, with its config (`filter.<d>.clean`,
`core.hooksPath`, `credential.helper`), its hooks, its refs and its objects,
while the path, the task id and the branch name go on reading exactly as they
did.

**Why nothing caught it.** A decoy repository built with the **same branch
name** answers `git -C "$wt" symbolic-ref HEAD` with `refs/heads/agent/<task>`
(measured) — so `require_wt_on_branch`, the check whose whole job is "is this
tree the branch's tree", passed it. `loom drop` could not clean up afterwards
either: git refuses to remove a worktree it does not own, the removal was
written `|| true`, and the command printed `dropped` over a directory that was
still there with the released paths still in it.

**What closes it.** Three facts, each asked of git and compared against a path
this process resolved at startup, realpath'd on both sides (so a repo under a
symlinked `/tmp` cancels out while a symlink planted at one of them does not):
`--git-common-dir` is this repository's shared `.git`; `--show-toplevel` is the
directory we asked about; `--git-dir` is under `$GIT_COMMON_DIR/worktrees/`,
i.e. git knows it as a linked worktree **of this repository**. And `loom drop`
no longer prints `dropped` on faith — the directory is asserted **gone** before
the record and the branch are touched (`tests/fence-profiles.sh` (bq)).

**The residual.** Nothing is done to a foreign worktree automatically: loom
refuses, names the git directory it found, and leaves both the directory and
the operator record standing, because the record is the only thing that says
what that directory is. Cleaning it up is the operator's, by hand.

---

## 8. `.agents/reviews` is loom's write into a tree the agent owns — CLOSED

**Status: fixed on this branch (round 11).** Kept here because the shape
generalises: it is the only directory in this system that loom writes to on the
agent's side of the fence.

**Where.** `reviews_dir` (`bin/loom:4082`), the write sites in `cmd_run`
(gate log), `cmd_check` (patch + review), `cmd_diff` (patch) and `cmd_loop`
(the review text it appends to the task spec), the `--add-dir` sandbox root in
`run_headless` (`bin/loom:2395`), and the pathspec in `wt_dirty`.

**What it was.** `reviews_dir` was `mkdir -p "$wt/.agents/reviews"` and nothing
else, and every caller then spelled the path out again. `mkdir -p` on a path
that already resolves to a directory succeeds silently, so a symlink there —
`.agents/reviews`, with `.agents` itself left intact and tracked — redirected
loom's own writes out of the worktree. The review **patch** is the one that
matters: it carries the full content of every path in the diff, released paths
included, so a profiled task's patch could be written into an *unprofiled*
worktree under the other root, which a provider that profile does not allow is
about to run in. `wt_dirty` excluded `.agents/reviews` by pathspec, so the
status lines that would have shown the swap were excluded too, and `loom land`
carried on.

**What closes it.** The directory is resolved physically before every write and
refused unless the resolved path is inside the resolved worktree, at **two**
levels — `.agents` (checked *before* the `mkdir`, which would otherwise create
the directory at the far end of a link) and `.agents/reviews` (the stealth
variant every `.agents`-level check walks past) — and the callers write to what
it resolved to rather than re-deriving the path. `run_headless` applies the
same rule to the `--add-dir` sandbox root it grants an implementer, and
`wt_dirty` drops its exclusion whenever `.agents/reviews` is not a real
directory inside the worktree, so the link counts as dirty and landing refuses
(`tests/fence-profiles.sh` (br)).

That tripwire is **two steps**, because dropping the exclusion is not enough in
the repo this file asks you to run: one that gitignores `.agents/reviews/`.

1. `git status --porcelain -- .`, carrying `:(exclude).agents/reviews` only
   while that directory is loom's own plain scratch;
2. and, **only when that exclusion was not applied**,
   `git status --porcelain --ignored=matching -- .agents/reviews` — whose `!!`
   lines are appended to the first step's output.

Without step two the plant is an IGNORED path: `git status` says nothing about
it with or without the pathspec, `wt_dirty` returned nothing, and `loom land`
published over it. With it, the plant reads as `!! .agents/reviews/<name>` and
landing refuses (`tests/fence-profiles.sh` (bw)).

Neither step is the lock. `place_file` closes the write path and
`probe_agent_file` the read path (gap 9), regardless of what any repo ignores;
`wt_dirty` is what stops `loom land` publishing over a tree somebody has been
playing with.

**Round 15 — the alarm's own blind spots.** A review pass went at the tripwire
itself rather than at what it watches, and found three ways to make it answer
"clean" without touching a single file it looks at. All three are measured on
git 2.34.1 and closed on this branch.

1. **An unreadable directory read as a clean one.** `.agents/reviews` at mode
   `0300` (`-wx------`) still answers `cd` and `pwd -P`, but a shell glob over
   it matches NOTHING — so `reviews_entries_plain` walked an empty list,
   answered "all plain", the `:(exclude).agents/reviews` pathspec stayed on, and
   everything planted inside was excluded from the one command meant to see it.
   Dropping the exclusion would not have saved it: `git status --porcelain -- .`
   over a tree with an unreadable directory prints
   `warning: could not open directory '.agents/reviews/': Permission denied` on
   STDERR, exits 0, and lists nothing from inside — the same for `.agents`
   itself at `0300`, where untracked entries under it vanish while
   modifications to tracked files still show. `wt_dirty` now refuses on the MODE
   of either directory before it asks anything else, `reviews_entries_plain`
   refuses a directory it can neither read nor search, and — the general form,
   which covers an unreadable directory ANYWHERE in the tree — both `git status`
   calls capture stderr and any of it at all is a refusal
   (`tests/fence-profiles.sh` (bz)).
2. **A swallowed `fatal:`, and the config key that provokes it.** With
   `status.showUntrackedFiles=no` in any scope, step one prints nothing for
   untracked files and step two dies `fatal: Unsupported combination of ignored
   and untracked-files arguments`, rc=128 — which
   `2>/dev/null | grep '^!! ' || true` swallowed whole, so both halves of the
   tripwire reported a clean tree. Step two now runs into a variable with its
   own `|| die` before the grep, both calls spell out
   `--untracked-files=normal`, and `'status.showUntrackedFiles=normal'` joins
   `'core.untrackedCache=false'` in `GIT_CONFIG_PARAMETERS` (gap 6). The config
   pin is no defence here by itself: the key can sit in `--global`, a scope the
   pin does not read, and it can be the baseline the pin ADOPTS at `loom new`
   — which is the shape the test drives (`tests/fence-profiles.sh` (ca)). A
   `core.excludesFile` (or `.git/info/exclude`) of `*` blinds step one the same
   way, but step two's `--ignored=matching` still lists the plant as
   `!! .agents/reviews/<name>`, so the tripwire already held there; noted, not
   changed.
3. **The message named a directory where the operator needed a file.** git names
   an individual entry only when a TRACKED file inside the directory makes it
   descend. In the shape this file asks a consumer for — `.agents/reviews/`
   gitignored, nothing tracked inside — `--ignored=matching` collapses to the
   single line `!! .agents/reviews/`, with and without `-uall`; the assertion in
   (bw) that reads a name only reads one because the harness repo tracks
   `.agents/reviews/.gitkeep`. The refusal fires either way, so this is
   legibility rather than a bypass. `reviews_entries_plain` now records WHICH
   entry it refused on and why, and `wt_dirty` appends one line of its own,
   `!! .agents/reviews/<name>  (not loom's plain scratch: <why>)`, keeping the
   `!! ` prefix (`tests/fence-profiles.sh` (cb)).

**The residual.** A consuming repo should still gitignore `.agents/reviews/`
(README § The loop) — the tripwire now holds either way, but an unignored
scratch directory makes every task's diff noisy. And the fence itself is
unchanged: this closes a redirect of loom's writes, not the question of what an
agent may read. It also closed the DIRECTORY and nothing below it — the FILE is
gap 9. Round 15's config parameter is **one key, not the class**:
`GIT_CONFIG_PARAMETERS` outranks every config file, `--global` included, so
`status.showUntrackedFiles` is now closed against both a planted `--global` and
an adopted baseline — but the pin behind it still trusts whatever was recorded
at `loom new` and still never reads `--global` at all. The general form of that
is gap 6's residual, and it is unchanged.

---

## 9. ... and one level down, the FILE was followed too — CLOSED

**Status: fixed on this branch (round 12).** The sibling of gap 8, found by
asking the same question one level lower.

**Where.** `place_file`, `resolve_under_wt`, `probe_agent_file`, `link_count`
and `reviews_entries_plain` (`bin/loom:4337`), the write sites in `cmd_run`
(the gate log, and the `-blocked.md` probe), `cmd_check` (patch + review),
`cmd_diff` (patch) and `cmd_loop` (the append to `.agents/tasks/<task>.md`),
the artifact copies at `state_artifact` (`bin/loom:2026`), and the pathspec in
`wt_dirty`.

**What it was.** Gap 8 resolved the DIRECTORY before every write and had each
caller write to what it resolved to. The path it then wrote was
`"$rdir/<task>.patch"`, with `>` — and `>` opens with `O_CREAT|O_TRUNC` and
**follows a symlink at the leaf**. So the redirect gap 8 closed at
`.agents/reviews` was still open at `.agents/reviews/<task>.patch`, with the
same target (another task's worktree, under the other root, that a provider
this profile does not allow is about to run in) and the same payload (the patch
carries the content of every path in the diff, released paths included).

A **hard link** is the same redirect with nothing to see: two names for one
inode, `ls -l` showing an ordinary file, and every byte `>` writes visible at
the other name. Neither `[ -L ]` nor a resolved directory says anything about
it.

Three more sites had the same shape. The **gate log** is written *after* the
implementer's turn, into a directory resolved *before* it — the window is the
turn itself, and one `ln -s` inside it moved loom's next write out of the tree.
`<task>-blocked.md` is read for its EXISTENCE alone and turned into an exit
code the operator acts on, so a link there answers "is the implementer stuck?"
with a file from somewhere else. And `loom loop` **appends** the reviewer's
REVISE text to `.agents/tasks/<task>.md` in the worktree — the spec the
implementer reads next — with `>>`, which follows a link exactly as `>` does.

**What closes it.** Every loom write into a worktree goes through `place_file`,
whose contract is four steps: (1) the worktree and the target's whole parent
chain are RE-RESOLVED immediately before the write, never trusted from earlier
in the command; (2) that resolved parent is then HELD as the working directory
and the content is written to a fresh `mktemp` named relative to it
(`./.loom-place.XXXXXX`) — a cwd is an INODE, so renaming `reviews` or
`.agents` aside after the check moves nothing under loom's feet, which spelling
the path out again at every syscall would have let it do; (3) the temp is
**renamed** onto the target (relative to the same held directory) — rename(2)
replaces the target's directory ENTRY, so a symlink there is overwritten as a
link and a hardlinked name keeps its old inode and its old bytes, and neither
ever sees what loom wrote; (4) the post-conditions are asserted rather than
assumed — after the rename the target must not be a symlink and must have
exactly one hard link, or the file is removed and the command dies. `mv -T` is
the rename (`-T` is what stops `mv` moving INTO a symlink-to-a-directory), with
python3's `os.rename` as the fallback for a `mv` that has no `-T`.

`probe_agent_file` guards the one file loom reads back out of the worktree: a
symlinked, non-regular or multiply-linked `-blocked.md` is a refusal, never
"blocked". `wt_dirty`'s exclusion now also requires every entry inside
`.agents/reviews` to be a plain one-link file. And the copies loom ACTS on are
not in the worktree at all: the patch, the review and the gate log are written
to `$STATE_DIR/tasks/<task>.artifacts/` first (0700/0600, removed by
`loom drop`), the worktree copies are courtesy placements — 0600 as well, since
`place_file` renames a `mktemp` into place and that is mktemp's mode —
`loom loop` reads
its verdict and its REVISE text from the operator's copy, and `loom land` takes
`reviewed` from the record (`tests/fence-profiles.sh` (bu)).

**The residual.** The same one the operator record has carried since it was
introduced, and it is not new here: an unsandboxed agent can write `$HOME`
(gap 3), and `$STATE_DIR` is in it. This is **operator integrity, not
tamper-proofing** — what it removes is the class of "the tree loom is judging
rewrites the thing loom judges it by", which needed no capability at all and
cost one `ln -s`.

---

## 10. `loom new _scout` would have built a task on the scout mirror — CLOSED

**Status: fixed on this branch (round 12).** Small, and written down because
the shape recurs: loom keeps directories of its own beside the task worktrees
under `$LOOM_WORKTREES`, and a task id is a directory name there.

**Where.** `state_file` (`bin/loom:611`), asked by `cmd_new` before anything is
created (`bin/loom:4838`).

**What it was.** `_scout` is the shared scout mirror — one directory, reset,
`clean -xdff`'d and re-fenced on every `loom scout`, deliberately under the
UNPROFILED root because it is shared by every task. `loom new _scout` would
have put a task worktree at exactly that path, with a branch and an operator
record, and the next `loom scout` would then have cleaned and reset the task's
tree from under it — losing uncommitted work, and quietly, since neither
command has a reason to mention the other.

**What closes it.** `state_file` refuses the whole `_` prefix rather than the
one name, so the next directory loom keeps there needs no second refusal, and
`loom new` asks it first — before the worktree, the branch and the record
(`tests/fence-profiles.sh` (bv)). It sits beside the existing refusal of an id
ending in `.gitconfig` or `.artifacts`, which are the sidecar names a record's
own directory would collide with.

**The residual.** None worth the word: an operator who wants a task called
`_scout` renames it.

---

## 11. External review (PR #7 @ `7da0cc4`) — reconciliation

An independent review of `feat/fence-profiles` (three reviewers, three
verifiers, one delta pass; throwaway repos, stubbed `claude`/`codex`/
`opencode`/`curl`, scratch `XDG_CONFIG_HOME`; no model or network call) was
opened as a draft PR against `tobyjaguar/coding-harness`, pinned at `7da0cc4`.
Its Status table is reproduced here in full, with what each id is at THIS tip
— round 17 — and the test letter that holds it. "Round N" is the fix round in
this branch's history; a letter in brackets is a case in
`tests/fence-profiles.sh`.

The three blockers it named — `refs/replace`, root verification at file scope,
and a widened `[fence]` stranding a worktree — are all closed here. The one
thing it asks for that is deliberately NOT closed is P1(e), which is a claim
rather than a bug: see the row, and the README sentence it is now stated in.

| id | the review's verdict on `7da0cc4` | at this tip |
|---|---|---|
| P1 (a) `update-ref` on trunk refs | RESOLVED | closed before this round — the base is a literal OID in the operator record |
| P1 (b) `refs/replace` blinds every diff | **OPEN — blocker**, reproduced to origin | **CLOSED, round 16 (cc)** — `core.useReplaceRefs=false` + `GIT_NO_REPLACE_OBJECTS=1` on every git loom spawns, and `require_no_replace_refs` refuses while any such ref exists (check, diff, land, run, loop, rebase, new) |
| P1 (c) — | not raised separately | — |
| P1 (d) remote swap | RESOLVED (`require_recorded_origin`) | closed, unchanged |
| P1 (e) the record file is writable by an unsandboxed role | OPEN — "docs honest below the fold, headline false" | **documented residual, not a defect.** The record is 0600 outside every repo and `require_sane_record` is a shape check; an agent running as the operator with no OS sandbox can write `$HOME` (gap 3) and therefore this file. There is no same-uid-proof fix — an HMAC key is readable by the same uid. What round 16 changed is the CLAIM: "operator integrity, not tamper-proofing" is now in the README paragraph that states the base guarantee, not only in the section below it |
| P2a gate ran from the worktree | RESOLVED | closed, unchanged — the gate is the operator's copy |
| P2b provider keys in the gate's environment | OPEN — 56 vars, `ZHIPU_API_KEY` among them | **CLOSED, round 16, WIDENED round 17 (ce)** — one `run_gate` for both sites, `env -u` for every exported name matching (case-insensitively) `*api_key*`/`*token*`/`*secret*`/`*password*`/`*auth*`/`*credential*`/`*access_key*`/`*key_id*` or a provider prefix; never `env -i`. Round 16's four suffixes let `AWS_SECRET_ACCESS_KEY`, `PGPASSWORD`, `DOCKER_AUTH_CONFIG` and a lowercase `openai_api_key` through. KNOWN-GAPS 3 says what the gate is, and the comment above `run_gate` no longer claims more |
| P2c `.agents/gate.sh` edit auto-committed | PARTIAL — no hook ⇒ committed, `check` reviews it, only `land` refuses | **CLOSED, round 16 (cf)** — `cmd_run` applies the guard's rule itself between `git add -A` and the commit; `check`, `diff` and each `loop` round run `hand_reconcile_history`. Round 17 (cn) added `--no-renames` to both staged-path reads: a `git mv` out of the zone reported only the destination |
| P3 opencode project config | RESOLVED | closed, unchanged |
| C1 root verification at file scope | **OPEN — blocker (regression)**: `help`, `zone`, `tier`, `guard` and the operator's own `git commit` all die | **CLOSED, round 16 (cd)** — normalisation stays at file scope, the verdict moved into `require_roots`; `doctor` reports a bad root as one FAIL and finishes. Round 17 (co) made that ONE message: `resolve_root`'s `die` ends only the command substitution, so the function used to carry on with an empty root and die again about a root it had invented |
| C2 unpushed trunk commits | RESOLVED | closed, unchanged |
| C3 widened fence strands worktrees | **OPEN — blocker (regression)** | **CLOSED, round 16 (ci)** — operator-side discriminator: `[fence]` now vs `git show <recorded base>:.agents/zones.toml`. Added-since-the-base ⇒ re-fence + one note; already-there ⇒ dies as before. Round 17 (cm) made the discriminator fail CLOSED when the base has no `[fence]` at all, which it did not |
| C4 arg-position `security_base` | RESOLVED | closed, unchanged |
| C5 `review_base` clamp / PR #5 dead code | RESOLVED | closed, unchanged |
| C6 doctor vs `LOOM_BASE_REF` | MOOT — variable gone | moot |
| C7 no way back after `drop --keep-branch` | OPEN — loom recommends the step that makes the task unreachable | **CLOSED, round 16 (cj)** — `loom attach <task>`: fresh worktree, fresh record, base = merge-base with the trunk, `reviewed=` empty. The `land --pr` hint names it |
| C8 | nit, unchanged | open, nit |
| C9 `writes_role` `build` | not a defect | not a defect |
| C10 | nit, unchanged | open, nit |
| N1, N2, N4, N5 landing hazards | MOOT — the branch merged `main` itself, cleanly | moot |
| N3 `cmd_doctor`'s `bad` shadow | OPEN, worse — `unbound variable` with no summary, or a model name in the failures slot and exit 2 with zero real failures | **CLOSED, round 16 (cg)** — the loop variable is `chainbad`; the summary's shape and the exit code are asserted together |
| P4 committed symlink at an assist path | OPEN — `create mode 120000`, every future worktree reads `core/` through it | **CLOSED, round 16 (ch), REOPENED and re-closed in round 17 (ck)(cl)(cp)(cq)** — round 16's escape test was LEXICAL and per-link, which a two-hop chain walked straight through (B1 below); targets are now resolved within the tree's own link map, only what the branch added or changed is refused, and what the trunk carries is fenced out of the worktree instead. Both legs, plus `attach` and `rebase` |
| P6 docs overclaim | PARTIAL — confinement table honest, base sentences false | **CLOSED, round 16** — README's two base sentences carry the `refs/replace` caveat and the "operator integrity, not tamper-proofing" statement |
| P7 | nit, unchanged | open, nit |
| T1/T2 suite portability (macOS) | OPEN — 13 `$TMPDIR` + 4 `timeout` failures | **CLOSED, round 16** — `$TMP` is resolved with `pwd -P`; `timeout` is shimmed when absent. No change on Linux |
| T5 `loop` coverage | improved — 1 invocation | open, nit |
| T6, T8, T10, T11 | nit, unchanged | open, nit |
| T12 `TASK_TEMPLATE` "DOCUMENTATION ONLY" | OPEN — a declaration turns `loom new` into a refusal | **CLOSED, round 16** — the template says what the key does |
| T13–T16 landing hazards | MOOT | moot |

### Round 17 — the adversarial pass on round 16's own fixes

Round 16's closure pass PASSED; the adversarial pass reproduced two more, both
against code round 16 had just written. Both are closed here, with `(ck)`
through `(cq)` in `tests/fence-profiles.sh`.

**B1 — a two-hop symlink chain defeated the lexical escape check (fence
breach).** `link_target_escapes` counted `..` against an assumed directory
depth, so each mode-120000 entry was judged on its OWN text with every
component treated as a real directory. A committed `d1/d2/l1 -> ../..`
(depth 2 → 0: "inside") plus `backend/loot -> ../d1/d2/l1/../../repo/core`
(never below 0: "inside") composed into `<the worktree root's parent>/repo/core`
— the operator's own checkout. Reproduced: `loom check` rc 0, `loom land`
merged both `120000` entries, a fresh unprofiled worktree read `core/**`
through it, a profiled task read a path its profile does not release, and an
agent WROTE the operator's `.agents/gate.sh` — the script `run_gate` executes
as the operator. Closed by resolving targets **within the tree's own link
map**: `links_py` builds `{path: target}` for every mode-120000 entry of the
subject (the index for the disk leg, `git ls-tree -r -z <tip>` for the history
leg, targets through one `git cat-file --batch`) and walks each target
component by component over a stack rooted at the tree root, substituting any
component — a prefix of the walked path included — that is itself a link. An
absolute target, or `..` at the root, is the escape, and the refusal names the
ORIGINAL link and the resolved escape. A cycle, or a chain past 40 hops, is
refused as "unresolvable" rather than guessed at. `(ck)`.

**B2 — a trunk that already carried an escaping symlink was permanently
unusable, and the printed remedy was wrong (availability).** With
`backend/hostname -> /etc/hostname` committed on the trunk before the branch
existed, `loom new` succeeded and then `run`/`check`/`diff`/`land` all died
("has tracked symlinks that point OUTSIDE it … Remove them, or start clean:
`loom drop <task-id>`") — and `loom drop` + `loom new` provably did not help,
because the link is not the branch's. `doctor` said nothing. The doorway is
real whoever opened it, but loom cannot rewrite the consumer's trunk. So what
is JUDGED is now what the branch ADDED or CHANGED relative to its recorded base
(same path AND same target at the base ⇒ inherited), on both legs, while the
resolution MAP still holds every link at the subject so a chain through an
inherited link is still caught; and what the trunk carries is **fenced out** —
the exact paths are appended to the sparse rules after the profile-filtered
patterns, so no profile releases them, and `fence_verify` proves them absent on
disk. `loom new` and `loom attach` print one WARN naming them, `loom doctor` a
warn line, and the refusal for an agent-introduced link names it as the
branch's own and no longer offers `loom drop`. `(cl)`, `(cp)`.

**The non-blocking items, all in.**

* **N1 — the widening discriminator failed OPEN on a base with no `[fence]`.**
  `_bd.get("fence", {}).get("paths", [])` yields `[]`, a valid list, so
  `base_fence` stopped being the `None` sentinel and every current pattern read
  as added; the bash half wrote an EMPTY FILE when `git show` failed, which
  parses to the same thing. Measured: an agent's `git sparse-checkout disable`
  came back as "[fence] has been widened … + core/** + ios/**" and the command
  carried on (`fence_enforce` still re-fenced, so nothing was released — but
  the tripwire and the message were both wrong). The sentinel now survives
  unless `[fence].paths` is actually there, and a failed `git show` leaves no
  temp at all. `(cm)`.
* **N2 — `git mv` out of the `[hand]` zone was invisible.**
  `hand_reconcile_staged` and `cmd_guard` read `git diff --cached --name-only`
  without `--no-renames`, so with git's default rename detection only the
  DESTINATION was reported: `loom run` committed the rename and the hook let it
  through. Both now spell `--no-renames`, as `history_paths` already did.
  `(cn)`.
* **N3 — `require_no_replace_refs` ended `2>/dev/null || true`**, the one
  permissive-on-error answer in the file, on the query whose empty result means
  "no replacements". It dies now.
* **N4 — `require_roots` produced two messages for one fault.** The `die`
  inside `resolve_root` ends only the command substitution, so the function
  carried on with an empty `WT_ROOT` and died again with a fabricated "the
  profiled worktree root … is inside " — both on `doctor`'s single FAIL line.
  Each resolve is followed by an `exit`. `(co)`.
* **N5 — the gate's environment scrub, widened and made honest.** See § 3: the
  four suffixes became case-insensitive substrings plus provider prefixes, and
  the comment no longer claims more than the code does. `(ce)`.
* **N6 — `loom attach` built the worktree and stopped.** A kept branch carrying
  `backend/etc -> /etc` was checked out and the live link materialised on disk;
  only the NEXT command refused. It now runs the disk-leg link check and
  `fence_reconcile` before it declares the attach done, with the EXIT trap
  still armed, so a refusal unwinds the worktree and the record. `(cp)`.
* **N7 — `loom rebase` had no history link check** while `check`/`loop`/`diff`/
  `land` all did, and it is the command that rewrites the history and re-points
  the base. Added after the replay, judged against the base about to be
  recorded, with the branch put back at `$PINNED_TIP` before the refusal. In
  practice the disk leg inside `fence_reconcile` refuses first in every state we
  could construct (the worktree's index carries the tip's tree), so this is
  defence in depth rather than the only lock. `(cq)`.
* **N8** — an unused `CE=` in the test file, removed. **N9** — README and
  ARCHITECTURE now state the lazy root verdict, the gate scrub, the
  mode-120000 rule with B1/B2's semantics, and `loom run`'s own `[hand]`
  refusal; and both stop saying `land` is the only command that refuses a
  `[hand]` path in the history.

**What round 17 did NOT change.** The exfiltration class (gap 4), the gate as
your build running as you (gap 3), `.agents/loom.env` as `.`-sourced shell, and
P1(e) below. An inherited escaping symlink is a **residual by design**: loom
closes the doorway in the worktrees it builds and tells you three times, but
the link is still in your trunk and in every clone of it, and loom will not
rewrite a file it does not own.

**What is open, in one place.** P1(e) as a documented residual (above);
C8, C10, P7, T5, T6, T8, T10 and T11 as nits the review itself left as nits.
Everything else on that table is closed or moot.

**The honest limits that did not change.** A diff between two endpoints still
says nothing about a fenced path added and removed again between two `loom`
commands, and nothing at all about what a model *read* — that is gap 4's
exfiltration class, and no check of this shape reaches it. The gate is still
your build running as you (gap 3). And `.agents/loom.env` is still `.`-sourced
shell from a tracked path.
