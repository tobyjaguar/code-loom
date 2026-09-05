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
   gitignore semantics (`*` stops at `/`); `loom zone` and `loom doctor` use
   `fnmatch` (`*` crosses `/`). They agree on the plain `subsystem/**` form.
   Stick to it. `loom doctor` flags a fence pattern that matches no tracked file,
   which catches the usual typo.
4. **It is per-worktree, not per-repo.** Your own working tree is untouched —
   the sparse config is written to the worktree-scoped config, so nothing
   disappears from under your editor.
5. **A worktree can predate the fence.** Sparse rules are applied when a
   worktree is built, so one created before `[fence]` existed — or before it
   was widened — still holds the paths you have since fenced. `loom run` and
   `loom scout` therefore re-apply and *verify* the fence on every call, and
   refuse to run if a fenced file survives (git will not remove a file with
   local modifications). Anything you drive by hand rather than through those
   commands gets no such refresh: after changing `[fence]`, treat existing
   worktrees in `loom ls` as stale and `loom drop` them.

Fencing `.agents/**` is refused outright, as is any pattern that would remove
`zones.toml`, `gate.sh` or the `reviews/` directory. Removing `zones.toml` from
a worktree would make every path resolve to `assist` and `loom guard` exit 0 —
the fence would quietly disarm the hand-zone boundary; removing `gate.sh` would
make the gate exit 127 and burn every retry; and removing `reviews/` would put
the gate log outside the sparse-checkout definition, so `git add -A` fails
after a green gate and nothing is committed.

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
