# Loom: a multi-provider agent harness

A design for coding with AI agents where the repository stays the only source of
truth, the harness is driven entirely from the command line, and model choice is
a config value rather than a lock-in.

Built around four goals, in priority order:

1. **No usage lockout.** Structurally reduce how many tokens the expensive model
   sees, and keep a working fallback when any single provider is unavailable.
2. **Lower cost.** Route by difficulty, not by habit.
3. **Provider flexibility.** Swap Anthropic, Z.ai, Moonshot, DeepSeek without
   touching workflow.
4. **Keep hand-programming alive.** Some code is yours to write. The system
   enforces that rather than hoping you remember.

---

## 1. The core idea

Most agent tooling has the same flaw: the agent holds state nothing else can
see. Conversation history, file context, pending edits, the plan — all of it
lives inside one vendor's chat session. When that session ends, or that vendor
is rate-limited, or you want a second model to check the first, the state does
not come with you.

Invert it. **Every durable artifact is a file in the repo.** Plans, task specs,
architecture decisions, review notes, the agent's own instructions. If it only
exists in a session, it does not exist.

That single constraint gets you everything else:

- Any tool can read and edit any of it, because it is all text on disk — your
  editor, `grep`, a script, a different agent next week.
- Agents are interchangeable, because they read and write files rather than
  holding proprietary state.
- Cost drops, because a plan written once is re-read for a few hundred tokens
  instead of re-derived for fifty thousand.
- Lockout risk drops, because the expensive model rarely needs the whole codebase
  in context.

The second constraint follows from the first: **agents never write to your
working tree.** They get git worktrees. You review by diff. Nothing changes
under the file you have open.

---

## 2. Layers

```
┌──────────────────────────────────────────────────────┐
│  You + your editor       edit, review, hand-write    │
├──────────────────────────────────────────────────────┤
│  Contract layer          .agents/{plans,tasks,...}   │  ← plain markdown
├──────────────────────────────────────────────────────┤
│  Execution layer         opencode agents, per-role   │  ← model routing
│                          model assignment            │
├──────────────────────────────────────────────────────┤
│  Isolation layer         git worktrees, one per task │
├──────────────────────────────────────────────────────┤
│  Gate                    fmt / clippy / test / check │  ← deterministic
└──────────────────────────────────────────────────────┘
```

Nothing crosses a layer except through files and git.

---

## 3. Roles and model assignment

Four roles. The point of the split is that intelligence and token volume are
inversely correlated in real coding work.

| Role | Model tier | Token share | Writes to |
|---|---|---|---|
| `architect` | Claude sub (`claude` CLI) | ~5% | `.agents/**` only |
| `scout` | cheap, read-only | ~50% | nothing |
| `implementer` | GLM Coding Plan / Kimi / DeepSeek | ~35% | one worktree, declared files |
| `reviewer` | mid-tier, *different provider* | ~10% | `.agents/reviews/**` |

### architect

Reads the plan request, consults `scout` for facts, writes a plan file and a set
of task files. Has `edit` permission scoped to `.agents/`. It cannot touch source.
This is not a safety measure so much as a cost measure: an architect that cannot
edit code will not be tempted to read all of it.

Its output is a durable artifact. That is the whole economic argument. You pay
premium rates once for a design, then re-read it for pennies on every subsequent
session.

### scout

Read-only exploration. "Where is the resampler called from, what does it assume
about sample rate, which tests cover it." Runs on a cheap model.

This is the single biggest cost lever in the system. Codebase exploration is the
majority of tokens in agentic coding and needs a fraction of the intelligence.
Sending `grep`-and-summarize work to a frontier model is where large-codebase
sessions burn quota.

### implementer

Gets exactly one task file and one worktree. Its instructions name the files it
may touch. It is not done until the gate passes.

### reviewer

Reads `git diff` against the task spec. Deliberately runs on a **different
provider than the implementer**, so failure modes are decorrelated. A GLM
implementation reviewed by GLM will share blind spots. Reviewed by DeepSeek or
Kimi, it will not.

---

## 4. Why this works especially well for Rust

Cheap models make more mistakes. The question is whether the mistakes are caught
for free.

In Rust they largely are. `rustc` plus `clippy -D warnings` is a deterministic,
zero-cost reviewer that rejects most of what a weaker model gets wrong: lifetime
errors, ownership confusion, unhandled `Result`, missing match arms, type
mismatches at boundaries. The gate turns model weakness into a compile loop
rather than a bug you find in three weeks.

The practical consequence: **you can push the implementer tier lower in Rust than
you could in Python.** Budget accordingly.

For `audat` specifically, the useful boundary is roughly:

- Numeric correctness of DSP is *not* well covered by the type system. Keep that
  in the hand zone, and back it with property tests and known-signal fixtures.
- Everything structural — trait plumbing, CLI parsing, file format decoding,
  error types, test scaffolding, benchmark harnesses — is well covered. Delegate it.

---

## 5. Hand zones

The skill-maintenance goal needs enforcement, not intention. `.agents/zones.toml`
declares three zones:

- **`hand`** — agents may read and may propose, never edit. Your learning surface.
- **`assist`** — agents edit, you review every diff.
- **`auto`** — agents edit, you review the summary.

A pre-commit hook rejects any commit on an `agent/*` branch that touches a `hand`
path. Convention alone drifts within a month; the hook does not.

### Tutor mode

Hand zones still get leverage, just inverted. Ask the architect to write:

- the failing test,
- the doc comment stating the contract and invariants,
- the type signatures,

and leave the body as `todo!()`. You fill it in. You get the design conversation
and the specification for free, and you still write the code. For learning Rust
this is better than either extreme, because the hard part of Rust is not
syntax — it is knowing what shape the solution should take.

### Read fences

`hand` is an *edit* boundary: agents still read those files, which is fine when
the only thing at stake is your own practice. It is not fine when the thing at
stake is a path you are contractually or ethically unwilling to send to a
third-party model. The optional `[fence]` section is that second axis:

```toml
[fence]
reason = "Client work under NDA — no third-party model sees this tree."
paths = ["crates/audat-nda/**", "docs/audits/**"]
```

Fenced paths are **removed from agent worktrees**. `loom new` creates the worktree
with `--no-checkout`, applies a non-cone sparse checkout (`/*` plus one
`!<glob>` per fenced set), and only then checks out — so fenced content never
lands in the agent's tree at all. `loom scout`, which otherwise reads your working
tree directly, is redirected to a persistent detached mirror at
`$LOOM_WORKTREES/_scout` under the same rules, reset to `HEAD` on each call.
The implementer and scout prompts say the paths are absent by policy, so a
confused agent asks instead of digging.

**What this is and is not.** Five caveats, all of them load-bearing:

1. **The object store is shared.** A worktree is a checkout, not a clone;
   `.git` still holds every fenced blob, and `git show`, `git cat-file` or
   `git sparse-checkout disable` reach them. The fence removes the files an
   agent would stumble into — a `grep -r`, a directory listing, an over-eager
   "let me read the whole repo" pass. It is a guard against **incidental
   exposure, not against exfiltration by an adversarial agent.** If your threat
   model includes the model actively trying to read what it was told not to,
   you need a separate repository, not a sparse checkout.

   Be precise about where the line now falls, because the reconciler moved it
   once. `fence_reconcile` asks "which fenced paths are present in this
   worktree" of **both** the index and the filesystem: a path under a fenced
   pattern is caught whether it is tracked, untracked, or a symlink standing
   where the directory should be — so `git show HEAD:core/lib.rs >
   core/copy.rs` is a dead stop, not an invisible one. What is still **not**
   covered, and never will be by a check of this shape, is the same content
   written to a path the fence does not name (`… > backend/notes.txt`), or
   simply held in the model's context. That is the exfiltration class above.
2. **Fenced code is genuinely missing from the build.** A fenced cargo
   workspace member, python package or npm workspace will fail to build *in the
   worktree*, because it is not there. Fence whole subsystems that you also
   exclude from the gate, and scope agent tasks so they never need to compile
   across the fence. A fence through the middle of a build graph produces an
   agent that cannot pass a gate it cannot fix.
3. **Matching is approximate in two dialects.** Sparse checkout applies
   gitignore semantics (`*` stops at `/`); `loom zone` and `loom doctor` use
   `fnmatch` (`*` crosses `/`). They agree on the plain `subsystem/**` form.
   Stick to it. `loom doctor` flags a fence pattern that matches no tracked file,
   which catches the usual typo.
4. **It is per-worktree, not per-repo.** Your own working tree is untouched —
   the sparse config is written to the worktree-scoped config, so nothing
   disappears from under your editor. The *definition* of the fence is
   per-repo and comes from ONE place: `.agents/zones.toml` in the MAIN
   checkout, which `loom` finds as the parent of `git rev-parse
   --git-common-dir` whichever tree the command was typed in. A command run
   from inside an agent worktree used to read that worktree's copy — the
   file the agent can edit — and fence the next task with it.
5. **A worktree can predate the fence.** Sparse rules are applied when a
   worktree is built, so one created before `[fence]` existed — or before it
   was widened — still holds the paths you have since fenced. `loom scout`
   re-applies and *verifies* the fence on every call. Every command that runs a
   role in a task worktree goes through `fence_reconcile` instead (see "Fence
   profiles" below), which is stricter: a worktree holding fenced paths that no
   `--fence-profile` on the command line accounts for is **refused**, not
   quietly re-fenced, because the tree's own diff would carry the content to
   the next model regardless. Either way, after changing `[fence]`, treat
   existing worktrees in `loom ls` as stale and `loom drop` them.

Fencing `.agents/**` is refused outright, as is any pattern that would remove
`zones.toml`, `gate.sh`, the `reviews/` directory or `.opencode/`. Removing
`zones.toml` from a worktree would make every path resolve to `assist` and
`loom guard` exit 0 — the fence would quietly disarm the hand-zone boundary;
removing `gate.sh` would make the gate exit 127 and burn every retry; removing
`reviews/` would put the gate log outside the sparse-checkout definition, so
`git add -A` fails after a green gate and nothing is committed; and removing
`.opencode/` would take away every role prompt and the provider identity
(`provider.<name>.options.baseURL`) that a fence profile's `providers` list is
built on.

The four control-plane paths an agent must be able to READ and must never
COMMIT — `.agents/zones.toml`, `.agents/gate.sh`, `.agents/loom.env` and
`.opencode/**` — are `[hand]` paths in the shipped template, which is what makes
`loom land` refuse a branch that changed them. They are each an input to the
checks that judge the agent's own work: the zones and the fence, the script
whose exit status means "commit it" and "land it", a file `loom` `.`-sources as
shell in your environment on every invocation, and the config that decides which
host answers as a given provider together with the prompt every role runs under.

### What `loom` trusts in `.git/config`, and what it does not

A linked worktree shares the git directory with the main checkout, so
`.git/config` is writable by anything running in an agent's tree —
`git -C <worktree> config core.pager /tmp/x` is one command. Several of its keys
name a **program git then runs**, in your session, the next time `loom` touches
the repository. `loom` therefore exports its own `GIT_CONFIG_PARAMETERS` (the
variable `git -c` uses, which outranks every config *file*) for every git
subprocess it spawns — including `git -C <worktree> …`, the operator's
`.agents/gate.sh`, and any hook git runs underneath them:

```
core.pager=cat          core.fsmonitor=false     protocol.ext.allow=never
core.editor=true        sequence.editor=true     core.sshCommand=<your global one, or `ssh`>
remote.origin.uploadpack=git-upload-pack         remote.origin.receivepack=git-receive-pack
pager.<cmd>=cat         for every subcommand loom runs (see below)
```

and it exports `GIT_PAGER=cat` alongside them.

and it clears git's own environment (`GIT_DIR`, `GIT_WORK_TREE`,
`GIT_OBJECT_DIRECTORY*`, `GIT_CONFIG_*`, `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`,
`GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `GIT_EDITOR`, `GIT_ASKPASS`, …) once both env
files have been sourced, because `.agents/loom.env` is `.`-sourced shell from a
tracked path (KNOWN-GAPS 3). Two measured exceptions to "the variable is
enough":

- **`diff.external` cannot be neutralised that way.** An empty value is not
  "unset", it is a command named `""`, and `git -c diff.external= diff` dies
  with `cannot run : No such file or directory` on every hunk. `--no-ext-diff`
  (with `--no-textconv`) on each diff-producing command is the lever that works,
  and it covers per-attribute `diff.<driver>.command` too.
- **`remote.<n>.uploadpack` / `receivepack` do not obey it either.** git
  collects those into a list and keeps the **first** value — a config file is
  read before `GIT_CONFIG_PARAMETERS`, so the config wins ("more than one
  receivepack given, using the first"). The lock is `--upload-pack=` on the
  fetch and `--receive-pack=` on the push, which do win; the config parameter is
  only a floor.
- **`core.pager=cat` does not cover `pager.<cmd>`.** Measured, git 2.34.1, in a
  pty: with `pager.log=<script>` in `.git/config` and `core.pager=cat` in the
  variable, the script *ran*. `git_pager()` reads `$GIT_PAGER`, then
  `pager_program`, then `core.pager` — and `check_pager_config()` has already
  set `pager_program` from `pager.<cmd>`, so `core.pager` is never reached. And
  `pager.<cmd>` with a *string* value turns paging **on** for a subcommand that
  never pages by default: `status`, `remote`, `branch`, `worktree`, `ls-files`,
  `show-ref`, `merge-base`, `rev-list`, `update-ref`, `add`, `commit`,
  `checkout`, `reset`, `diff`, `log`, `show`, `ls-remote`, `symbolic-ref`,
  `sparse-checkout` and `patch-id` all ran the planted pager; only `rev-parse`
  did not. `git config` **splits**: `config --get` does not page, but
  `config --list` **does** (measured in a pty, git 2.34.1) — and `--list` is the
  form the config pin itself reads with, so `pager.config=cat` is load-bearing
  rather than belt-and-braces. Both levers that do win are used — `GIT_PAGER=cat` (the
  complete one: it beats `pager.<cmd>` for every subcommand, including ones loom
  does not run today) and one `pager.<cmd>=cat` per subcommand loom runs (the
  floor). `--no-pager` on every call site also works and was rejected: ~100
  sites, and a site added later would silently have no pin.

**The whole git config is pinned, because the keys that matter cannot be
enumerated.** `filter.<anything>.clean`, `merge.<anything>.driver`,
`pager.<anything>`, `includeIf.<anything>` put the attack **in the key name**,
so there is no finite list for `GIT_CONFIG_PARAMETERS` to override, and
`credential.helper` / `core.askPass` are worse than a program: git hands them
the credential as well as running them.

**And "the whole git config" is not `git config --local --list`.** git reads
three files here, a linked worktree can write two of them, and a fourth channel
hides behind a pointer:

| scope | file | who can write it |
|---|---|---|
| `local` | `$GIT_COMMON_DIR/config` | every worktree — it is shared |
| `worktree-main` | `$GIT_COMMON_DIR/config.worktree` | the main checkout's own scope; a `core.hooksPath` here runs **your** hooks, in **your** checkout, during `loom land`'s merge |
| `worktree-task` | `$GIT_COMMON_DIR/worktrees/<wt>/config.worktree` | the task worktree's own scope — `git config --worktree <k> <v>` from inside the agent's tree |
| `include` | every file an `include.path` / `includeIf.<cond>.path` names, recursively | whoever can write that file, which is not necessarily anyone in this repository |

**`includeIf` conditions are not evaluated, on purpose.** git decides whether an
`includeIf.<cond>.path` applies by testing `<cond>` — `gitdir:`, `onbranch:`,
`hasconfig:` — against the repository at the moment it reads the config. `loom`
does not test it: **every** `includeIf` target is resolved, digested and pinned,
whatever its condition says. That **over-refuses** by construction — an edit to
a file whose condition does not currently match is still a refusal — and that is
the direction to be wrong in. The conditions are evaluated against state that
moves (the branch you are on, the directory the command ran in, the config
itself), so a closure that honoured them would be a closure that changed shape
under the agent, and "the include stopped applying" would look identical to "the
include was never there".

**An included file's BYTES are pinned, not only its digest.** A digest alone
made an edit to an included file print `include:<path>:<sha-a>` against
`include:<path>:<sha-b>` — a refusal with nothing in it to read, in the one case
where the changed bytes are not in a file `git config --list` will show. The
record is `include:<path>:<sha256>` plus the target's own bytes, so the same
change renders as a `-`/`+` **content** diff. Path and bytes are escaped on the
way *in*, with the escaper values are rendered with, because the sidecar is
NUL-framed with a newline between a record's halves and an included config file
may contain both.

Both `config.worktree` files are live whenever `extensions.worktreeConfig` is
enabled — which **loom itself enables**, on the first `git sparse-checkout init`
in a repository (measured, git 2.34) — and **neither of them appears in
`git config --local --list`**. Nor do the keys an include brings: `--list`
prints `include.path=<file>` as a *pointer*, and only the full, all-scopes
`git config --list` shows the `core.hooksPath` it pulled in (measured, git
2.34.1). A pin taken over the local listing therefore pinned one file out of
three and one pointer instead of a file.

So `loom new` records `config=<sha256 of the sorted, NUL-separated union of all
three scopes' `--list --null` output, each entry tagged with its scope, plus one
`include:<resolved path>:<sha256 of its bytes>` record per file in the include
closure>` as a field of the operator record, and the full list beside it as
`<task>.gitconfig` (mode 0600) so a mismatch can be shown as a diff — one that
names the scope — rather than two digests. A missing include target is recorded
as `(missing)`, because "the target appeared" is as much of a change as "its
contents changed". It is recomputed and compared:

- **before the first fence operation of every command**, which is `loom run`,
  `check`, `loop`, `diff`, `land` and `rebase` — see the ordering note below;
- before **every** model launch (in `run_role`, per *attempt* — attempt 1 can
  plant a config and hit a rate limit, and attempt 2 would inherit it);
- before `loom land`'s **merge** and before its **push**;
- before `loom rebase`'s **fetch** and again before its **replay**;
- in `loom check` and `loom diff` before the **review patch** is written.

**The ordering is part of the check.** `fence_reconcile` calls `fence_apply`,
whose `git sparse-checkout set` is a *working-tree update*: git materialises
every path the new pattern list admits, and materialising a path runs the
**smudge** side of whatever `filter.<d>` a `.gitattributes` in that worktree
selects. The `.gitattributes` is a file the agent writes (uncommitted is
enough), and `filter.<d>.smudge` is one `git config` away — so with the pin
checked one line *after* the reconcile, the planted program ran as the operator
before the refusal it exists for. Every command now reads the pin first, and
`run_role` reads it above its own per-attempt reconcile.

A change is a dead stop that prints the `-`/`+` lines and names the one escape,
`--accept-config`, which prints the same diff and re-records it as the new
baseline. **`loom new` refuses `--accept-config`**: it is the command that
*pins*, so it has nothing to accept, and swallowing the flag would read as "the
config was re-pinned". It says what it pinned instead — one line,
`loom: pinned N local + M worktree config entries`, a WARN naming the targets
whenever an `include.path`/`includeIf` is present (an included file's bytes are
now part of this task's baseline, and the operator should meet that fact before
they meet the refusal), and a second WARN naming **every pinned key that names a
program git runs** — `core.hooksPath`, `credential.*`, `core.askPass`,
`filter.*`, `merge.*.driver`, `diff.*.textconv`/`.command`, `gpg.program`,
`pager.*`, `core.attributesFile`, `core.sshCommand`,
`include.*`/`includeIf.*` — values escaped, tagged with the scope each came
from. That list is residual 1 below, printed at the one moment it is being
adopted; an operator who is never shown it has no way to know they accepted it.
`loom pin-config` prints both blocks too. **`loom drop` deliberately does not
check the pin at all**: it runs no model, publishes nothing, and removes the
worktree, the branch and the record — refusing to clean up because the config
moved would strand released paths on disk, which is the opposite of what the
check is for. `loom` writes config on your behalf in exactly two places and
both re-pin themselves: `loom new`'s first `git sparse-checkout init` in a
repository adds `extensions.worktreeConfig` to the shared `.git/config` and
`core.sparseCheckout` to the new worktree's own `config.worktree` (measured, git
2.34), and `loom land --pr`'s `--set-upstream-to` adds
`branch.<br>.remote`/`.merge`. Everything else that changes it is you or an
agent — an agent's `git config user.name` in its worktree **will** trip this,
and that is the intended shape, because it is the same command as
`git config credential.helper '!sh -c …'`.

`core.hooksPath`, `filter.*`, `merge.*.driver`, `diff.*.textconv`,
`gpg.program`, `credential.helper`, `core.askPass`, `pager.*`,
`include.path`/`includeIf.*` and `core.attributesFile`/`excludesFile` are
therefore **change-refused**. `core.hooksPath` is still not *overridden* — the
operator's hooks must run, `loom install-hooks` puts the hand-zone guard in one
— but a worktree can no longer re-point it under a running task without the
command refusing.

**What is still trusted, honestly enumerated.** The residual is three things,
and it is a residual by construction rather than an oversight:

1. **Whatever the config already said at `loom new`, in every scope the pin
   covers.** The pin is a *change* check. A repository that already had a
   hostile `filter.x.clean` in `.git/config`, in either `config.worktree`, or in
   an included file when the task was created has it in the baseline. So is
   whatever `--accept-config` was used to re-record — that flag is an operator
   act with the same weight as `--fence-profile`, and `loom` vouches for none of
   what it accepts.
2. **The operator's own `~/.gitconfig` and the system config**, and any git
   config scope outside the three above. None of them is in the shared `.git`,
   none is writable from a worktree, and none is pinned — they are the
   operator's. `core.sshCommand` is deliberately *read* from there (see the cost
   below).
3. **In-tree `.gitattributes`.** The driver lives in the config, which is
   pinned; the *attribute* that selects it for a path lives in the tree. It is a
   `[hand]` path in the shipped template (`.gitattributes` and
   `**/.gitattributes`, because git reads one in any directory), so `loom land`
   refuses a branch that changed it — which is the lock, since the pre-commit
   guard is a seatbelt. An *uncommitted* one still selects a driver for a
   working-tree update, which is why the pin is read before the reconcile.

#### The roles with no task, and the repository baseline

The pin above is **per task**, and two roles do not have one: `loom plan`'s
architect, which runs in `$ROOT` — your own checkout — and `loom scout`, which
runs in the shared `$WT_ROOT/_scout` mirror. Both are model launches, and the
scout is a **working-tree update** as well: `fence_apply` -> `sparse-checkout
set`, the `clean` and the `reset --hard`/`checkout` beside it each materialise
paths, and materialising a path runs the **smudge** side of whatever `filter.<d>`
a `.gitattributes` in the mirror selects — with the driver read out of the
**shared** `.git/config`, one `git config` from inside any agent's worktree. So
the whole argument for the pin applied to `loom scout`, and `loom scout` had no
pin.

The **repository** therefore has a baseline of its own, beside the task records
and never inside one:

```
${XDG_CONFIG_HOME:-~/.config}/loom/repos/<key>/config            the digest, 0600
${XDG_CONFIG_HOME:-~/.config}/loom/repos/<key>/config.gitconfig  the dump it was
                                                                 taken over, 0600
```

covering the scopes that belong to the **repository** — `local` and
`worktree-main` — and their include closure. The `worktree-task` scope is
deliberately absent: there is no task here, and folding one in would make the
baseline move whenever any task's worktree gained a sparse rule.

- **Written** wherever a task is pinned (`loom new`, `--accept-config`, and
  `land --pr`'s re-pin after its own `--set-upstream-to`), and by
  **`loom pin-config`**, the explicit operator command — and the answer for a
  repository with no tasks at all. Its grammar is the same consent shape as
  everything else here: bare, it records a missing baseline, says so when the
  baseline is current, and prints the diff and **refuses** when it is not;
  `loom pin-config --accept-config` prints the same diff and re-records.
- **Read** by `scout_root` before it touches the mirror at all, by `cmd_plan`
  before the architect runs, and by `run_role` before every task-less launch,
  per *attempt*. A missing baseline is its own refusal, in its own words.
- **Not removed by `loom drop`.** It is a fact about the repository rather than
  about a task, and a `loom scout` after the last task was dropped still has to
  be judged against something.

`git config --worktree` is an **alias for `--local`** when
`extensions.worktreeConfig` is off, so the two worktree scopes are read only
when git would read them. That is fail-closed, not a relaxation: turning the
extension on is itself a write to the local scope, which this same pin refuses.

`scout_root` re-pins the repository baseline after **creating** the mirror, for
the same reason `loom new` re-pins after its own worktree setup — the first
`sparse-checkout init` in a repository writes `extensions.worktreeConfig` to the
shared `.git/config`. The baseline was checked at the top of that function,
before anything was created, so a config an agent moved is refused above and
never reaches the re-pin.

#### The scout mirror is disposable

`$WT_ROOT/_scout` is shared by every task and every provider, which makes
anything that survives a call a channel between them.

- Its **own worktree-scope config**, `$GIT_COMMON_DIR/worktrees/_scout/config.worktree`,
  is the one scope no baseline can cover — it is not `local`, not the main
  checkout's, and not any task's — and `git -C <mirror> config --worktree` writes
  it. `loom` **refuses** a mirror whose private scope holds anything but the
  sparse keys git's own `sparse-checkout` writes. Refusing rather than
  deleting-and-recreating the scope is deliberate: both neutralise the plant,
  only one tells the operator that something wrote there.
- `reset --hard` never touches an **untracked** file, so a previous run's
  scratch — or a copy of a fenced path made with `git show HEAD:core/lib.rs >
  notes.txt`, which the index never sees — sat in the mirror for the next
  provider to read. `git clean -xdff` now runs before the reset.

`remote.origin.url` / `.fetch` / the push URL keep their own named checks on
top of the pin, because "the remote was re-aimed" is a clearer message than "the
config changed"; they are pinned in the operator record at `loom new` and
re-checked before `loom rebase` fetches and before `loom land --pr` pushes.

A repository whose `.gitattributes` and filter drivers you would not run is a
repository to give an agent a separate clone of, not a sparse checkout — the
same answer caveat 1 gives for exfiltration.

### A worktree is judged only once it is proved to be ours

Every check above reads a worktree through `git -C "$wt" …`, and *which
repository that answers for* is decided by one line of text in a file the agent
owns. `$wt/.git` in a linked worktree is not a directory; it is a file holding
`gitdir: <path>`. Rewrite it and the directory stops being this repository's
worktree: every later `git -C "$wt" …` reads a git directory of the writer's
choosing — its config (filter drivers, `core.hooksPath`, `credential.helper`),
its hooks, its refs, its objects — while the path, the task id and the branch
name go on reading exactly as they did.

Nothing caught it, and the shape of the trap is why: a decoy repository built
with the **same branch name** answers `git -C "$wt" symbolic-ref HEAD` with
`refs/heads/agent/<task>` (measured), so `require_wt_on_branch` — the check
whose whole job is "is this tree the branch's tree" — passed it. `loom drop`
could not clean up afterwards either: git refuses to remove a worktree it does
not own, the removal was written `|| true`, and the command printed `dropped`
over a directory that was still there with the released paths still in it.

`require_wt_is_ours` asks git three things and compares each against a path this
process resolved at startup, realpath'd on both sides (so a repo under a
symlinked `/tmp` cancels out while a symlink planted at one of them does not):

1. `--git-common-dir` is this repository's shared `.git`;
2. `--show-toplevel` is the directory we asked about — not a tree elsewhere
   that a moved gitdir or a `core.worktree` re-aimed it at;
3. `--git-dir` is under `$GIT_COMMON_DIR/worktrees/`, i.e. git knows it as a
   linked worktree **of this repository**.

It runs at the top of `require_wt_on_branch` (which covers `require_worktree`,
`loom run` and `loom loop`), in `loom drop` **before** `git worktree remove`,
and in `scout_root` for the mirror. And `loom drop` no longer prints `dropped`
on faith: the directory is asserted **gone** before the record and the branch
are touched, and if anything remains loom prints what and exits 1 — leaving the
operator record, which is the only thing that says what that directory is.

### Fence profiles

The fence answers "may a model read this?" with one bit for all models. The
question is usually finer: a custody core can be fine for the two subscription
CLIs whose vendors already hold the rest of the repo, and not fine for a
per-token API in a third jurisdiction. A **fence profile** is a named, opt-in,
per-provider relaxation of the fence. Schema, in full:

```toml
[fence]
reason = "..."
paths  = ["core/**", "ios/**", "spike/**", "docs/audits/**"]

# zero or more profiles; the name is the opt-in token
[fence_profiles.codex]
reason    = "Anthropic + OpenAI may read and edit the custody core."   # optional
release   = ["core/**", "docs/audits/**"]   # REQUIRED. Each entry must appear
                                            # verbatim in [fence].paths.
providers = ["claude", "codex"]             # REQUIRED. provider_of() values:
                                            # claude, codex, zai-coding-plan,
                                            # deepseek, moonshotai, ...
```

Semantics:

- **Effective fence** = `[fence].paths` minus the *asserted* profile's
  `release`. The sparse checkout at `loom new` and the re-apply/verify inside
  `fence_reconcile` answer with that set. `loom zone` and `loom doctor` are **not**
  task-scoped and never assert a profile: they always report the full `[fence]`,
  which is the honest answer to "what does this repo fence?" — the release is a
  property of one task's worktree, not of a path.
- **The opt-in is a fresh operator act, on every command.** `--fence-profile
  <name>` is REQUIRED by `loom new`, `run`, `check`, `loop`, `diff`, `rebase` and
  `land` for any task under a profile. `loom new` also writes the profile into
  the **operator record** (below) — and is the only thing that ever writes it —
  but that record is a **consistency check, never an authorisation**: three
  rules, all fail-closed, and there is no fourth —
  1. a record exists and the flag is absent → die, naming the flag to pass:
     "this task was created under fence profile X; pass --fence-profile X";
  2. both exist and differ → die;
  3. the flag is given and no record exists → **die, always**, with the
     recreate instruction (`loom drop <task> && loom new <task> --fence-profile
     <name>`). A profile cannot be introduced after `loom new`. This rule had an
     exception until round 2: a worktree already holding exactly what the
     profile releases was read as corroboration, the record was restored and
     the command ran. That rested on the claim that a materialised tree costs
     "a checkout nobody but `loom new` performs", which is false — `git
     sparse-checkout disable` is one command, and so is `git checkout <ref> --
     core/`. A tree can refuse; it can never vouch.

  `branch.agent/<task>.fenceprofile` is neither read nor written any more, and
  the reason is unglamorous: **branch config is agent-writable state.** Anything
  running inside the worktree could `git config branch.agent/<task>.fenceprofile
  codex`, because branch config lives in the shared `.git/config`. A design that
  read the profile from there let an agent widen its own fence and have the next
  `loom run` honour it.

  A `Fence-profile: <name>` line in the task file is a third, weakest form: it
  documents intent — an architect agent may have written it — and `loom new`
  honours it only when the same name is passed on the command line. It is read
  from the task file's **header block** alone, so a line inside a code fence
  (the shape `loom loop` appends when it pastes a reviewer's text back into the
  task file) is not a declaration.
- **A profiled task's worktree lives under its own root.**
  `${LOOM_WORKTREES}-profiled`, a sibling of the ordinary root and never a
  child of it. Nothing that runs unprofiled is ever handed a directory that
  *contains* released paths: not another task's role, not the shared `_scout`
  mirror (which stays under the ordinary root at the full fence), and not
  opencode, whose `external_directory` grant is the role's own worktree rather
  than the worktree root. `loom ls`, `loom drop`, `loom rebase` and `run_role`'s
  defence-in-depth check all know both roots, and a task that exists under one
  cannot be re-created under the other.

  "Sibling" is a claim about a path, so both paths are checked rather than
  assumed. `$LOOM_WORKTREES` must be absolute and is normalised first (trailing
  `/` **and** `/.` stripped repeatedly — `/x/wt/.` would otherwise derive
  `/x/wt/.-profiled`, a child); the profiled root is then derived from that and
  from nothing else, and a `WT_ROOT_PROFILED` preset in the environment or in
  `.agents/loom.env` that differs is a refusal, not a redirection. Both roots
  are resolved with `pwd -P` (through the parent chain, so a repo under a
  symlinked `/tmp` stays ordinary) and refused when the final component is not
  the real directory its name claims — an agent that plants
  `$WT_ROOT-profiled -> $WT_ROOT/T5` would otherwise have every released path
  checked out inside the directory unprofiled runs are pointed at. Neither root
  may contain the other or sit inside `$ROOT`. And because a verified directory
  is not a promise, every `git worktree add` re-resolves the parent of the path
  it is about to create against this command's root, and re-resolves the
  worktree afterwards.
- **opencode reads the operator's config.** opencode resolves its project
  config from the cwd, which is the agent's worktree:
  `<worktree>/.opencode/opencode.json` is a tracked file the agent can rewrite,
  and it carries `provider.<name>.options.baseURL` — the provider identity the
  whole `providers` rule is built on — as well as the agent definitions that
  supply the role prompt. Every opencode invocation therefore runs with
  `OPENCODE_DISABLE_PROJECT_CONFIG=1`, **unconditionally**, plus
  `OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` pointing at the operator's copy when
  one exists: the config variables alone are not a fix (they are merged
  *before* the project files, so the worktree copy would still win key by key),
  and making the disable conditional on the operator having a config was
  backwards — a repo with no `$ROOT/.opencode/opencode.json` is exactly the
  repo where the worktree's copy is the only config there is. A caller that
  sets `OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` wins untouched; the disable is
  the one thing no caller turns off. The cost is that opencode no longer reads
  the worktree's `AGENTS.md`/`CLAUDE.md` or a project-local plugin; the role
  prompt now comes from `$ROOT/.opencode`, which is the copy the `claude` and
  `codex` legs already used.
- **Enforcement is a consistency check against the tree AND the commits.**
  `fence_reconcile <wt> <asserted>` runs before any role in
  `run`/`check`/`loop`/`diff`/`rebase`/`land` — `diff` included, because it
  writes the same `.agents/reviews/<task>.patch` a reviewer is handed — and
  again inside `run_role` for any
  workdir under either worktree root — **before every fallback attempt**, not
  once before the loop: attempt 1 can relax the sparse checkout and then hit a
  rate limit, and attempt 2 is a different provider. It computes "which fenced
  paths are on disk here" against the **full** `[fence]` — never the effective
  set, which would be the profile vouching for itself — from the index *and*
  from the filesystem under each pattern (tracked or not; caveat 1 above), and
  then: released
  paths on disk with no assertion covering them is a **dead stop**, not a
  silent re-fence (the worktree's diff and `.agents/reviews/<task>.patch` carry
  the content into the next model even after the files are gone); an assertion
  whose released paths are nowhere on disk is a dead stop too, because that
  tree was not built under the profile.

  The tree alone is not enough, because a tree can be re-fenced after the fact.
  `fence_reconcile_history <task> <base> <asserted>` therefore judges what the
  branch's **commits** touch — `git diff --no-renames --name-only <base>
  $PINNED_TIP`, a rename counted on both sides — against the full `[fence]`
  minus the asserted release, wherever history is handed to a role or to the
  operator: `loom check` before the patch is written, each round of `loom loop`,
  `loom diff`, `loom rebase`, and `loom land`. The endpoint is `$PINNED_TIP`, the
  **sha** this command resolved `refs/heads/agent/<task>` to, once, before any
  of it — never the ref name re-read per use, and never the worktree's `HEAD`.
  With nothing asserted, nothing is released, so any fenced path in the history
  is a dead stop; with no fenced path touched it is a no-op.

  Two limits of a two-endpoint diff, stated so they are not mistaken for
  coverage. A fenced path **added and deleted again on the same branch** is not
  in `git diff <base> <tip>` even though both commits are in the history and
  `git log -p` carries the content: the tree reconciler catches it while it is
  on disk, and the first `loom` command after the add sees it in the range, but a
  branch that does both between two commands is invisible to this check. And a
  diff says nothing about what was *read* — that is caveat 1's exfiltration
  class, and no check of this shape reaches it.
- **One base, and it is the operator's — kept outside the repo.** `<base>`
  above is `security_base <task>`: the commit `$ROOT` was checked out at when
  `loom new` created the task, read from the **operator record**

  ```
  ${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/<sha256 of the main checkout's
      real path>/repo                 <- that path, for humans
      .../tasks/<task>                <- base=<commit>
                                         profile=<name>
                                         branch=agent/<task>
                                         created=<iso>
                                         reviewed=<tip loom check last read>
                                         origin=<remote.origin.url at loom new>
                                         fetch=<remote.origin.fetch at loom new>
                                         pushurl=<the PUSH url of origin, ditto>
  ```

  written 0700/0600, by `loom new` alone; re-pointed by `loom rebase` (an operator
  command, and the only thing that moves a base); deleted by `loom drop`, with or
  without `--keep-branch`; read by every security check, by `cmd_guard` (which
  runs as the same OS user, and finds the same directory from a linked worktree
  because the key is the **main** checkout's path via `git rev-parse
  --git-common-dir`) and by `loom ls`.

  Those are all eight fields, and they are the whole file: one field per line,
  each field once, every key in that fixed list. `state_put` refuses anything
  else on the way in and `state_read` refuses it on the way out, because three
  of the values arrive from `.git/config` — `origin` via `git remote get-url`,
  `fetch` via `git config`, `pushurl` via `git remote get-url --push` — where a
  worktree can put a NEWLINE inside a value and forge a second field.
  `reviewed` is written above those three on purpose, so that even a reader
  taking the first match for a duplicated key takes the honest one. `reviewed`
  is what `loom check` stamps and `loom land` refuses to publish anything else
  against; `origin`/`fetch`/`pushurl` are what `loom rebase` and
  `loom land --pr` check before they contact a remote at all.

  `pushurl` is a separate fact from `origin` and not a duplicate of it: a
  `remote.origin.pushurl`, and a `url.<decoy>.pushInsteadOf = <the real
  origin>` rewrite, each send a push somewhere else while `git remote get-url
  origin` goes on answering the URL the record pinned. `loom land --pr` is the
  one command in this system that publishes an agent's commits to a host, so
  where a push actually GOES is pinned in its own right.

  The location is the point. Everything under `.git/` is writable from any
  linked worktree — config *and* refs — so none of it can carry a security
  input. `branch.agent/<task>.loombase` was one `git config` away from the
  branch's own tip, which emptied every history diff above, and an unresolvable
  sha made `history_paths` answer "no paths"; `merge-base($LOOM_BASE_REF, <br>)`
  replaced it and was one `git update-ref refs/remotes/origin/main <tip>` away
  from the same collapse — while *also* false-refusing an honest task whenever
  the operator had unpushed commits on `main`. `$LOOM_BASE_REF` is gone with it.
  Not knowing a base is a refusal in every direction: no record, unresolvable
  base, a base that is not an ancestor of the branch, a branch with nothing past
  its branch point ("nothing to review/land"), unresolvable rev, failed diff.

  There is no second base. The review patch `loom check` and `loom diff` write is
  cut from the same range the history check just cleared, so there is nothing
  left to clamp — and nothing for an agent to shrink.
- **The endpoint is the branch ref, never the worktree's HEAD — and it is
  resolved to a SHA exactly once per command.**
  `fence_reconcile_history` and the review-patch cut both read
  `refs/heads/agent/<task>` in `$ROOT` — the ref `loom land` merges and `loom land
  --pr` pushes. Measuring from the worktree's `HEAD` meant `git checkout
  --detach HEAD~1` after a fenced commit left every check looking at a clean
  history while the branch still carried the commit onward. A worktree whose
  `HEAD` is not `refs/heads/agent/<task>` (`git symbolic-ref -q HEAD`) is
  refused outright as well: it is not a state `loom` produces.

  Naming the ref was not enough either, because a name is resolved at the
  moment it is used and `refs/heads/*` is in the shared `.git`. A command that
  said `agent/<task>` four times — the history check, the patch, the merge, the
  push — resolved it four times, and one `git update-ref` between any two of
  them (the gate script `loom land` used to run out of the worktree is one line
  of shell) landed something other than what was checked. `pin_branch_tip
  <task>` resolves it once into `$PINNED_TIP`, and every one of the four uses
  that sha: `git merge --no-ff <sha>`, `git push origin
  <sha>:refs/heads/agent/<task>`.
- **What was reviewed is recorded, and landing refuses anything else.**
  `loom check` writes `reviewed=<sha>` into the operator record after the review
  is saved; `loom land` refuses when `$PINNED_TIP` is not that sha, naming both
  and asking for a fresh `loom check`. `--force` skips the gate, not this. A
  rebase clears the stamp, because the sha a reviewer read does not exist on a
  rebased branch. Landing also refuses a worktree with uncommitted changes —
  what the reviewer read and what a merge would carry have come apart —
  excluding `.agents/reviews/`, which is where `loom check` and `loom diff` write
  the review patch themselves (consumers should gitignore that directory).
- **The gate `loom` acts on is the operator's.** `loom run` (green -> commit) and
  `loom land` (green -> merge/push) execute `<main checkout>/.agents/gate.sh`
  with the worktree as its cwd, never `<worktree>/.agents/gate.sh`. The
  worktree's copy is a file the implementer edits — the `claude` leg allowlists
  running it by name, and under a fence profile that releases it the guard
  would even accept committing it — so a gate that rewrites itself to `exit 0`,
  or that re-points the branch on the way past, is one line of shell. The
  implementer still runs the worktree's copy for its own iteration; that is its
  business. `.agents/gate.sh`, `.agents/zones.toml` and `.agents/loom.env`
  belong in `[hand]` for the same reason, and the shipped template lists them.
- **A rebase does not bury upstream commits under the base.** `loom rebase` is
  the one command that moves a recorded base, and everything in
  `old_base..new_base` stops being the branch's work: it is upstream now, below
  the base, where no fence check, no hand check and no review patch looks
  again. `refs/remotes/origin/main` is one `git update-ref` from any commit —
  and unlike `refs/heads/main`, which is the branch the operator is standing on
  and moves in front of them, a moved `origin/main` is visible nowhere. So the
  range is mapped through the **full** `[fence]` and the **full** `[hand]` (a
  profile releases paths for the *task's* commits; nobody released anything for
  what arrives from upstream), and a hit refuses the rebase, leaving the
  recorded base untouched and resetting the branch back to `$PINNED_TIP`, so
  the refusal leaves the task exactly as it found it. `--accept-upstream` is
  the operator's "I have read those commits and I accept them under the base".

  The range itself — `git log --oneline old_base..new_base` **and** the
  fenced/hand path lists — is printed **whenever the base moves**: on the
  refusal and under `--accept-upstream` alike, and whether or not anything is
  in those lists. Consent to bury commits is only consent if the operator was
  shown what they are; the accept leg used to print subjects with no lists at
  all, because it never computed them, and both legs were gated on the range
  touching a path, so a range of merge commits slid under in silence. It will
  fire on ordinary work too — your own `[hand]` commits, merged upstream while
  the task ran, are a hit — and that is the intended shape: the flag is a
  confirmation, not an override, and the alternative is a base that moves over
  unread commits.

  `git fetch` losing its `|| true` belongs to the same rule: replaying onto a
  stale upstream succeeds quietly. So does the SHAPE of the fetch. For an
  `origin/<branch>` upstream `loom` writes the refspec out itself —
  `git fetch origin +refs/heads/<b>:refs/remotes/origin/<b>` — rather than
  letting `remote.origin.fetch` decide what a fetch is for. That setting lives
  in the shared `.git/config`: pointed at `refs/remotes/decoy/*` it makes the
  fetch succeed while updating nothing under `refs/remotes/origin/`, so a
  forged `origin/main` survives it intact, and forged at the branch's own tip
  that re-points the base onto the branch's own work. Both halves of the remote
  — `remote.origin.url` and `remote.origin.fetch` — are also recorded at
  `loom new`, with `loom rebase` (before the fetch) and `loom land --pr`
  (before the push) refusing when either has changed.
- **Landing inspects what it is about to publish.** Before it merges and before
  it pushes, `loom land` maps every path in `<security base>..agent/<task>` through
  `zone_of` and the asserted profile's release list: a fenced path the profile
  does not release, or ANY `[hand]` path it does not release, refuses the
  landing by name. The guard is supposed to have stopped these, but the guard
  runs in the agent's own context where `--no-verify` exists, so landing is
  where it is actually caught. `--force` skips the gate, not this.
- **Provider rule.** Before a worktree is created, and again before each role
  runs, `loom` walks the *entire* model chain of every role that will run there
  (implementer, reviewer, and the auto-fix rounds through the implementer) and
  dies unless `provider_of(model)` is in `providers` for all of them. Chains,
  not first entries: a fallback fires on a rate limit without asking. The scout
  is exempt because it is never given a profiled tree — its mirror is shared by
  every task and always carries the full fence.
- **The guard follows, as a seatbelt.** Fenced paths are conventionally
  duplicated into `[hand]` so that a *commit* to them is blocked even where the
  fence is not applied. Under a profile, `loom guard` accepts exactly the released
  patterns and keeps blocking the rest of `[hand]`. But be clear about what it
  is: the guard is a pre-commit hook that runs **in the agent's own context**,
  where `git commit --no-verify` exists. It is a seatbelt, not a lock.

  Two things follow from "the agent's own context", and they point in opposite
  directions. The zones it applies are the **main checkout's**: `$ROOT` is
  derived from `git rev-parse --git-common-dir`, so a `.agents/zones.toml` the
  agent edited in its own worktree is not the file the guard reads — only the
  staged files, the branch and the tree it inspects come from the invoking
  worktree, because that is what the commit is. But the operator record it looks
  up is found through `$XDG_CONFIG_HOME`, which is *the agent's* environment: a
  process that can set that variable can point the lookup at a record of its
  own. That is not a hole to plug so much as the shape of the thing — the whole
  hook is dominated by `--no-verify`, which needs no environment at all.
  `loom land`'s checks are the lock; this is the seatbelt. It is
  therefore allowed to read the operator record for the released set — it runs
  as the same OS user, and resolves the same state directory from inside the
  worktree — and it checks that record against the tree before trusting it: a
  record whose released paths are absent from the worktree, or a worktree
  holding fenced paths the record's profile does not release, refuses the
  commit rather than widening the guard. Be plain about what that check is
  worth: it is a **consistency check an agent that is trying can satisfy** —
  making the tree agree costs one `git sparse-checkout disable`, and an
  unsandboxed agent can write `$HOME` (KNOWN-GAPS 3), so the state directory is
  **operator integrity, not tamper-proofing**. It catches a stale worktree and
  an honest mistake. What actually decides whether released content reaches a
  provider is the operator's flag on `loom new`, re-checked on every later
  command, and `loom land`'s inspection of the commits. The reviewer prompt is
  told the same fact, so a released path is not reported as an unauthorized
  change.
- **Fail-closed parsing.** Unknown profile name, unknown key in the table, a
  `release` entry that is not a `[fence]` pattern, a `release` entry another
  still-fenced pattern covers *or that swallows a pattern which stays fenced*
  (both directions: `release = ["core/**"]` with `core/wallet-sdk/**` still in
  the fence is the same trap upside down), a `providers` entry with whitespace
  or a glob character in it, a `providers` entry that is not a name
  `provider_of()` can return (`claude`, `codex`, `zai`, `zai-coding-plan`,
  `moonshotai`, `deepseek`, plus anything under `provider` in
  `.opencode/opencode.json` — so `Claude` and `claude-sub` are refused, not
  silently allowed to match nothing), a missing or empty list, a
  `[fence_profiles]` that is not a table — each one dies, in every mode, before
  any answer is given.
  `LOOM_FENCE_PROFILE` from the environment is ignored and cleared at startup —
  and so is `AW_FENCE_PROFILE`, the name it had before the dispatcher was
  renamed, because a shell that still exports the old one is exactly the shell
  this rule exists for. A profile is something an operator types, not something
  a variable carries.

The caveats of § 5 all still apply, caveat 1 above all: the object store is
shared, so a profile scopes **exposure**, not exfiltration. What it buys is
that the exposure is now a written, checked, reviewable decision — which
provider may see which subsystem — instead of an all-or-nothing switch that
pushes you into doing the work by hand.

See also [`docs/KNOWN-GAPS.md`](docs/KNOWN-GAPS.md) for the gaps in the
surrounding machinery that a fence profile does **not** close.

### Write-capable sandboxes for implementer-class roles

This is independent of fence profiles. It applies to **every** run, profiled or
not, and it changed at the same time only because a profiled task is the first
place `codex-sub` is an obvious implementer.

The edit permission is granted per ROLE, never per model:

| role | codex-sub | claude-sub | opencode providers |
|---|---|---|---|
| implementer / build | `codex exec --sandbox workspace-write --add-dir <wt>/.agents` | `claude -p --permission-mode acceptEdits --allowedTools 'Bash(./.agents/gate.sh…)'` | no OS sandbox |
| reviewer / scout / architect | `codex exec --sandbox read-only` | `claude -p` (no mode flag: every prompt is denied) | no OS sandbox |

Four things this table does *not* say:

1. **The opencode leg has no OS sandbox at all**, in either row. An opencode
   reviewer is held by its role prompt, by the fence applied to the worktree,
   and by the profile's provider rule — not by the process.
2. **`--allowedTools` does not confine a claude implementer's shell.** It names
   `.agents/gate.sh`, which is a file the implementer can edit. It is a
   convenience boundary that lets the implementer protocol run at all; what
   actually confines that leg is the worktree and the fence applied to it.
3. **`--add-dir` names a writable root**, so `<wt>/.agents` is resolved with
   `pwd -P` and refused unless it is still under the resolved worktree — a
   tracked directory can be replaced with a symlink out of the tree.
4. **Neither `codex-sub` nor `claude-sub` is in a default implementer chain**
   (they are `zai-coding-plan/glm-5.3`, `deepseek/deepseek-v4-pro`,
   `moonshotai/kimi-*`). Reaching this code path takes an explicit
   `LOOM_MODELS_implementer`.

---

## 6. Lockout avoidance, concretely

Two lockouts on large codebases is a symptom with a specific cause: a single
agent repeatedly pulling large amounts of the codebase into a frontier model's
context. Four mitigations, in order of effectiveness.

**1. Structural — the architect rarely sees code.** It sees plan files, a repo
map, and scout summaries. This is worth an order of magnitude more than the
other three combined.

**2. Billing — flat subscriptions first, per-token APIs as the relief valve.**
Anthropic API pricing is skewed enough against the subscription that "fall back
to the API key" is a trap: one heavy task can cost a meaningful fraction of a
month's sub. So this system uses **no `ANTHROPIC_API_KEY` at all**. The
architect runs on the Claude subscription through the `claude` CLI; the token
bulk (scout + implementer) runs on a second flat subscription (the GLM Coding
Plan); cheap per-token keys (DeepSeek, Moonshot) exist only as the fallback
when a subscription window is exhausted — and as the decorrelated reviewer.
A rate limit on either sub degrades the chain; it never opens a metered tap.

**3. Tiering — one env var drops the whole system a level.**

```sh
export LOOM_TIER=lean      # everything cheap, architect on GLM/Kimi — sub untouched
export LOOM_TIER=standard  # default: architect on the Claude sub, rest on GLM sub
export LOOM_TIER=deep      # architect AND reviewer on the Claude sub
```

When you hit a wall, `LOOM_TIER=lean` and keep working, degraded.

**4. Fallback chain.** Each role names an ordered list in `loom`. A model is
skipped when its key/CLI is absent, when `LOOM_SKIP` names its provider, or —
detected at runtime — when its output looks rate-limited (429 / quota /
overloaded). If the Claude sub is limited, the architect runs on GLM. The plan
will be worse. You will not be stopped.

---

## 7. The contract format

A plan is a markdown file with a fixed shape. Fixed shape matters because it is
what lets a cheap model act on it reliably.

```markdown
# Plan 0007 — Streaming resampler

## Goal
One paragraph. What is true after this is done.

## Constraints
- No allocation in the hot path
- Must handle 44.1k ↔ 48k exactly
- Public API stays additive

## Design
The reasoning. This is the expensive part and the part worth keeping.

## Interfaces
```rust
pub trait Resampler { ... }
```

## Tasks
- [ ] 0007-a  Trait + error types        assist  crates/audat-dsp/src/resample/mod.rs
- [ ] 0007-b  Sinc kernel                HAND    crates/audat-dsp/src/resample/sinc.rs
- [ ] 0007-c  CLI wiring                 auto    crates/audat-cli/src/cmd/resample.rs
- [ ] 0007-d  Property tests             assist  crates/audat-dsp/tests/resample.rs

## Acceptance
`./.agents/gate.sh` green, plus `cargo test -p audat-dsp resample::` covers
round-trip error < -96 dBFS.
```

Each unchecked task becomes a task file. Each task file is one worktree, one
implementer run, one diff to review.

Note task `0007-b` is marked `HAND`. The sinc kernel is the interesting part.
You write that one.

---

## 8. No editor integration, on purpose

The harness ships no editor plugin, and that is a design position rather than an
omission. An editor layer is the one part of a system like this that is
guaranteed to rot: it tracks a plugin API you do not control, it duplicates
state the files already hold, and it quietly becomes the thing you have to fix
before you can work.

The interface is instead the two things every editor already has:

**Files.** Plans, tasks, reviews, decisions and the gate log are markdown and
plain text under `.agents/`. Opening one is `:e`, `Cmd-P`, or `cat`. The gate
writes native tool output to `.agents/reviews/<task>-gate.log`, so any error
parser — quickfix, the VS Code Problems panel, a CI annotation — reads it
without translation.

**Commands.** Every action is one shell command with a task id. Nothing is
hidden behind a keybinding, which means everything is equally available from a
terminal, a task runner, a Makefile, a script, or an ssh session on a machine
you have never configured.

Two optional conveniences ship with the harness. Both are ~40 lines, nothing
else reads them, and deleting either from your repo changes no behaviour:

- **`.vscode/tasks.json`** — the gate as the default build task, wired to the
  `$rustc` problem matcher, plus prompted tasks for `loom scout`, `loom run`,
  `loom check` and `loom doctor`.
- **`loom-session`** — a tmux window with `$EDITOR`, a shell for `loom`
  commands, and a gate/watch pane. `LOOM_SESSION_EDITOR` overrides the left
  pane for anyone whose editor is not in the terminal.

Diff review has one seam worth naming: `loom diff` writes the patch to
`.agents/reviews/<task>.patch` and shows it through git's own pager, honouring
your `color.diff` and `core.pager` config. `LOOM_DIFF_CMD` replaces the viewer
outright (`delta`, `bat`, `code --wait`, an editor in read-only mode); the patch
path is appended as the last argument. The file is written either way, so a tool
that wants to open it can, and a machine with no viewer configured still works.

---

## 9. Session loop

```
  you ──▶ architect ──▶ .agents/plans/0007.md      [premium, ~5% of tokens]
                    └─▶ .agents/tasks/0007-*.md
                             │
                    ┌────────┴────────┐
              HAND tasks         assist/auto tasks
                    │                 │
                  you              loom run 0007-c  [cheap]
                  by hand             │
                    │            worktree + gate
                    │                 │
                    │              reviewer         [mid, other provider]
                    │                 │
                    └───────▶  loom check / loom land
```

`loom land` merges into your current branch and ticks the plan checkbox. In a
repo with review gates, land in PR mode instead — `loom land <task> --pr`, or
`LOOM_LAND=pr` in the environment — which runs the same gate, pushes
`agent/<task>` to `origin`, and prints the `gh pr create` line for you to run.
It merges nothing, keeps the branch and the worktree, and leaves the checkbox
for you to tick when the PR actually merges. `loom drop <task> --keep-branch`
reclaims the worktree afterwards without deleting the branch you just pushed.

The architect is invoked at the start of a feature and when a plan turns out to
be wrong. Not otherwise. If you find yourself in a long conversation with the
expensive model, that is the signal to stop and write a plan file instead.

---

## 10. What this costs

Rough shape, not a quote. Assume a feature that would be 200k tokens of
single-agent frontier work:

| Approach | Frontier tokens | Cheap tokens |
|---|---|---|
| One frontier agent | 200k | 0 |
| This system | ~12k (plan + review of plan) | ~190k |

The frontier share drops by more than an order of magnitude, which is the
lockout fix. Absolute cost drops by roughly the ratio of the price difference on
the 95% you moved.

The second-order saving is larger and harder to quantify: plan files mean the
next session starts from a written design rather than re-deriving it.

---

## 11. Failure modes to watch

**Plan rot.** A plan file that no longer matches the code is worse than none.
Land plan updates in the same commit as the code, and treat a stale plan as a bug.

**Cheap model thrash.** If an implementer fails the gate three times, stop. Do
not let it loop. The task spec is probably wrong, which is an architect problem.
`loom run` enforces a retry cap for this reason.

**Zone creep.** Watch for `hand` paths quietly getting reclassified because a task
was inconvenient. Review `zones.toml` diffs like you would review a security
policy.

**Scout hallucination.** A cheap model summarizing a codebase will occasionally
invent a function. Require scout to return file:line citations and have the
architect treat uncited claims as unknown.

---

## 12. Setup order

1. `bin/loom` on your `PATH`, `.agents/gate.sh` executable.
2. `.agents/zones.toml` — five minutes, do it honestly.
3. `AGENTS.md` at repo root. Keep it under 100 lines. It is read on every call.
4. `.opencode/opencode.json` — set your API keys as env vars, run
   `opencode models` to confirm current model IDs before trusting the ones in the
   config.
5. Install the pre-commit hook: `bin/loom install-hooks`. An existing hook is
   moved to `.git/hooks/pre-commit.pre-loom` and chained after the guard, so
   installing Loom never disables the hook you already had.
6. Run one small feature end to end before trusting it with anything real.

Model IDs move quickly. Verify them with `loom doctor`: it checks every ID in
the routing chains and `opencode.json` against the public models.dev catalog
and, where a key is set, against the provider's live `/models` endpoint.
