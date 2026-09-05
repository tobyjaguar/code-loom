# Loom: a Vim-native agent system

A design for coding with AI agents where the repository stays the only source of
truth, Vim stays a first-class client, and model choice is a config value rather
than a lock-in.

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

Most agent tooling fails Vim users for one reason: the agent holds state the
editor cannot see. Conversation history, file context, pending edits, plan — all
of it lives inside a chat session. Vim becomes a spectator.

Invert it. **Every durable artifact is a file in the repo.** Plans, task specs,
architecture decisions, review notes, the agent's own instructions. If it only
exists in a session, it does not exist.

That single constraint gets you everything else:

- Vim can read and edit any of it, because it is all text on disk.
- Agents are interchangeable, because they read and write files rather than
  holding proprietary state.
- Cost drops, because a plan written once is re-read for a few hundred tokens
  instead of re-derived for fifty thousand.
- Lockout risk drops, because the expensive model rarely needs the whole codebase
  in context.

The second constraint follows from the first: **agents never write to your
working tree.** They get git worktrees. You review by diff. Your buffer is never
mutated underneath you.

---

## 2. Layers

```
┌──────────────────────────────────────────────────────┐
│  You + Vim/Neovim        edit, review, hand-write    │
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

Fenced paths are **removed from agent worktrees**. `aw new` creates the worktree
with `--no-checkout`, applies a non-cone sparse checkout (`/*` plus one
`!<glob>` per fenced set), and only then checks out — so fenced content never
lands in the agent's tree at all. `aw scout`, which otherwise reads your working
tree directly, is redirected to a persistent detached mirror at
`$LOOM_WORKTREES/_scout` under the same rules, reset to `HEAD` on each call.
The implementer and scout prompts say the paths are absent by policy, so a
confused agent asks instead of digging.

**What this is and is not.** Four caveats, all of them load-bearing:

1. **The object store is shared.** A worktree is a checkout, not a clone;
   `.git` still holds every fenced blob, and `git show`, `git cat-file` or
   `git sparse-checkout disable` reach them. The fence removes the files an
   agent would stumble into — a `grep -r`, a directory listing, an over-eager
   "let me read the whole repo" pass. It is a guard against **incidental
   exposure, not against exfiltration by an adversarial agent.** If your threat
   model includes the model actively trying to read what it was told not to,
   you need a separate repository, not a sparse checkout.
2. **Fenced code is genuinely missing from the build.** A fenced cargo
   workspace member, python package or npm workspace will fail to build *in the
   worktree*, because it is not there. Fence whole subsystems that you also
   exclude from the gate, and scope agent tasks so they never need to compile
   across the fence. A fence through the middle of a build graph produces an
   agent that cannot pass a gate it cannot fix.
3. **Matching is approximate in two dialects.** Sparse checkout applies
   gitignore semantics (`*` stops at `/`); `aw zone` and `aw doctor` use
   `fnmatch` (`*` crosses `/`). They agree on the plain `subsystem/**` form.
   Stick to it. `aw doctor` flags a fence pattern that matches no tracked file,
   which catches the usual typo.
4. **It is per-worktree, not per-repo.** Your own working tree is untouched —
   the sparse config is written to the worktree-scoped config, so nothing
   disappears from under your editor.
5. **A worktree can predate the fence.** Sparse rules are applied when a
   worktree is built, so one created before `[fence]` existed — or before it
   was widened — still holds the paths you have since fenced. `aw scout`
   re-applies and *verifies* the fence on every call. Every command that runs a
   role in a task worktree goes through `fence_reconcile` instead (see "Fence
   profiles" below), which is stricter: a worktree holding fenced paths that no
   `--fence-profile` on the command line accounts for is **refused**, not
   quietly re-fenced, because the tree's own diff would carry the content to
   the next model regardless. Either way, after changing `[fence]`, treat
   existing worktrees in `aw ls` as stale and `aw drop` them.

Fencing `.agents/**` is refused outright. Removing `zones.toml` from a worktree
would make every path resolve to `assist` and `aw guard` exit 0 — the fence
would quietly disarm the hand-zone boundary — and removing `gate.sh` would make
the gate exit 127 and burn every retry.

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
  `release`. The sparse checkout at `aw new` and the re-apply/verify inside
  `fence_reconcile` answer with that set. `aw zone` and `aw doctor` are **not**
  task-scoped and never assert a profile: they always report the full `[fence]`,
  which is the honest answer to "what does this repo fence?" — the release is a
  property of one task's worktree, not of a path.
- **The opt-in is a fresh operator act, on every command.** `--fence-profile
  <name>` is REQUIRED by `aw new`, `run`, `check`, `loop`, `diff`, `rebase` and
  `land` for any task under a profile. `aw new` also writes
  `branch.agent/<task>.fenceprofile` — and is the only thing that ever writes
  it — but that record is a **consistency check, never an authorisation**:
  three rules, all fail-closed, and there is no fourth —
  1. a record exists and the flag is absent → die, naming the flag to pass,
     and saying that a record is agent-writable so the flag should be passed
     only if the operator created the task under it;
  2. both exist and differ → die;
  3. the flag is given and no record exists → **die, always.** A profile
     cannot be introduced after `aw new`. This rule had an exception until
     round 2: a worktree already holding exactly what the profile releases was
     read as corroboration, the record was restored and the command ran. That
     rested on the claim that a materialised tree costs "a checkout nobody but
     `aw new` performs", which is false — `git sparse-checkout disable` is one
     command, and so is `git checkout <ref> -- core/`. A tree can refuse; it
     can never vouch. If a record really was the operator's and was lost, the
     operator restores it by hand (`git config branch.agent/<task>.fenceprofile
     <name>`), which is an act with the same weight as the flag.

  The reason is unglamorous: **branch config is agent-writable state.** Anything
  running inside the worktree can `git config branch.agent/<task>.fenceprofile
  codex`, because branch config lives in the shared `.git/config`. A design that
  read the profile from that record let an agent widen its own fence and have
  the next `aw run` honour it. It can now only refuse a command.

  A `Fence-profile: <name>` line in the task file is a third, weakest form: it
  documents intent — an architect agent may have written it — and `aw new`
  honours it only when the same name is passed on the command line. It is read
  from the task file's **header block** alone, so a line inside a code fence
  (the shape `aw loop` appends when it pastes a reviewer's text back into the
  task file) is not a declaration.
- **A profiled task's worktree lives under its own root.**
  `${LOOM_WORKTREES}-profiled`, a sibling of the ordinary root and never a
  child of it. Nothing that runs unprofiled is ever handed a directory that
  *contains* released paths: not another task's role, not the shared `_scout`
  mirror (which stays under the ordinary root at the full fence), and not
  opencode, whose `external_directory` grant is the role's own worktree rather
  than the worktree root. `aw ls`, `aw drop`, `aw rebase` and `run_role`'s
  defence-in-depth check all know both roots, and a task that exists under one
  cannot be re-created under the other.
- **Enforcement is a consistency check against the tree AND the commits.**
  `fence_reconcile <wt> <asserted>` runs before any role in
  `run`/`check`/`loop`/`rebase`/`land`, and again inside `run_role` for any
  workdir under either worktree root — **before every fallback attempt**, not
  once before the loop: attempt 1 can relax the sparse checkout and then hit a
  rate limit, and attempt 2 is a different provider. It computes "which fenced
  paths are on disk here" against the **full** `[fence]` — never the effective
  set, which would be the profile vouching for itself — and then: released
  paths on disk with no assertion covering them is a **dead stop**, not a
  silent re-fence (the worktree's diff and `.agents/reviews/<task>.patch` carry
  the content into the next model even after the files are gone); an assertion
  whose released paths are nowhere on disk is a dead stop too, because that
  tree was not built under the profile.

  The tree alone is not enough, because a tree can be re-fenced after the fact.
  `fence_reconcile_history <wt> <base> <asserted>` therefore judges what the
  branch's **commits** touch — `git diff --no-renames --name-only <loombase>
  HEAD`, a rename counted on both sides — against the full `[fence]` minus the
  asserted release, wherever history is handed to a role or to the operator:
  `aw check` before the patch is written, each round of `aw loop`, `aw diff`,
  `aw rebase`, and `aw land`. With nothing asserted, nothing is released, so
  any fenced path in the history is a dead stop; with no fenced path touched it
  is a no-op.
- **Landing inspects what it is about to publish.** Before it merges and before
  it pushes, `aw land` maps every path in `<loombase>..agent/<task>` through
  `zone_of` and the asserted profile's release list: a fenced path the profile
  does not release, or ANY `[hand]` path it does not release, refuses the
  landing by name. The guard is supposed to have stopped these, but the guard
  runs in the agent's own context where `--no-verify` exists, so landing is
  where it is actually caught. `--force` skips the gate, not this.
- **Provider rule.** Before a worktree is created, and again before each role
  runs, `aw` walks the *entire* model chain of every role that will run there
  (implementer, reviewer, and the auto-fix rounds through the implementer) and
  dies unless `provider_of(model)` is in `providers` for all of them. Chains,
  not first entries: a fallback fires on a rate limit without asking. The scout
  is exempt because it is never given a profiled tree — its mirror is shared by
  every task and always carries the full fence.
- **The guard follows, as a seatbelt.** Fenced paths are conventionally
  duplicated into `[hand]` so that a *commit* to them is blocked even where the
  fence is not applied. Under a profile, `aw guard` accepts exactly the released
  patterns and keeps blocking the rest of `[hand]`. But be clear about what it
  is: the guard is a pre-commit hook that runs **in the agent's own context**,
  where `git commit --no-verify` exists. It is a seatbelt, not a lock. It is
  therefore allowed to read the agent-writable branch record for the released
  set — and it checks that record against the tree before trusting it: a record
  whose released paths are absent from the worktree, or a worktree holding
  fenced paths the record's profile does not release, refuses the commit rather
  than widening the guard. Be plain about what that check is worth: it is a
  **consistency check an agent that is trying can satisfy** — forging the
  record costs one `git config`, and making the tree agree costs one `git
  sparse-checkout disable`. It catches a careless forgery, a stale worktree and
  an honest mistake. What actually decides whether released content reaches a
  provider is the operator's flag on `aw new`, re-checked on every later
  command, and `aw land`'s inspection of the commits. The reviewer prompt is
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
  `AW_FENCE_PROFILE` from the environment is ignored and cleared at startup: a
  profile is something an operator types, not something a variable carries.

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

**4. Fallback chain.** Each role names an ordered list in `aw`. A model is
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

## 8. Vim integration, three tiers

**Tier 0 works in plain Vim, no plugins.** This is the baseline and it is
genuinely sufficient.

```
tmux window
┌────────────────────┬──────────────────┐
│                    │  opencode TUI    │
│   vim              ├──────────────────┤
│                    │  cargo watch     │
└────────────────────┴──────────────────┘
```

- `:cfile` the gate output into quickfix, `]q` / `[q` to walk errors.
- `:!git diff agent/0007-c` to review, or `:Gdiffsplit` with fugitive.
- `:e .agents/plans/0007-*.md`, then `gf` on a path to jump to the source.
- `:r !aw scout "where is decode_flac called"` to drop an answer into a buffer.

**Tier 1 adds Neovim terminal management.** `agents.nvim` gives each CLI agent a
persistent terminal buffer you can hide, cycle, and send prompts to without
losing the running job. It does not invent a chat UI or own your layout, which is
what you want.

**Tier 2 adds `opencode.nvim`** for a chat panel that captures buffer and
selection context automatically. Useful, optional, and the thing most likely to
break on upgrade. Do not build the workflow on it.

Included keymaps in `nvim/loom.lua`:

| Key | Action |
|---|---|
| `<leader>ag` | run gate, results into quickfix |
| `<leader>ap` | open current plan |
| `<leader>ar` | review current task diff in a vertical split |
| `<leader>as` | ask scout about the word under cursor |
| `<leader>az` | show which zone the current file is in |

---

## 9. Session loop

```
  you ──▶ architect ──▶ .agents/plans/0007.md      [premium, ~5% of tokens]
                    └─▶ .agents/tasks/0007-*.md
                             │
                    ┌────────┴────────┐
              HAND tasks         assist/auto tasks
                    │                 │
                  you              aw run 0007-c    [cheap]
                  in vim               │
                    │            worktree + gate
                    │                 │
                    │              reviewer         [mid, other provider]
                    │                 │
                    └───────▶  aw review / aw land
```

`aw land` merges into your current branch and ticks the plan checkbox. In a
repo with review gates, land in PR mode instead — `aw land <task> --pr`, or
`LOOM_LAND=pr` in the environment — which runs the same gate, pushes
`agent/<task>` to `origin`, and prints the `gh pr create` line for you to run.
It merges nothing, keeps the branch and the worktree, and leaves the checkbox
for you to tick when the PR actually merges. `aw drop <task> --keep-branch`
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
`aw run` enforces a retry cap for this reason.

**Zone creep.** Watch for `hand` paths quietly getting reclassified because a task
was inconvenient. Review `zones.toml` diffs like you would review a security
policy.

**Scout hallucination.** A cheap model summarizing a codebase will occasionally
invent a function. Require scout to return file:line citations and have the
architect treat uncited claims as unknown.

---

## 12. Setup order

1. `bin/aw` on your `PATH`, `.agents/gate.sh` executable.
2. `.agents/zones.toml` — five minutes, do it honestly.
3. `AGENTS.md` at repo root. Keep it under 100 lines. It is read on every call.
4. `.opencode/opencode.json` — set your API keys as env vars, run
   `opencode models` to confirm current model IDs before trusting the ones in the
   config.
5. Install the pre-commit hook: `bin/aw install-hooks`. An existing hook is
   moved to `.git/hooks/pre-commit.pre-loom` and chained after the guard, so
   installing Loom never disables the hook you already had.
6. Run one small feature end to end before trusting it with anything real.

Model IDs move quickly. Verify them with `aw doctor`: it checks every ID in
the routing chains and `opencode.json` against the public models.dev catalog
and, where a key is set, against the provider's live `/models` endpoint.
