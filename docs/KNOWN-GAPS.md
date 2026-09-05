# Known gaps

Holes an adversarial review found in the harness that are **not fixed** in the
branch that added this file. All of them pre-date fence profiles and none is
caused by them; they are written down here so that the fence-profile work is
not mistaken for closing them, and so they are not re-discovered from scratch.

Line numbers are as of the commit that added this file; grep the quoted text if
they have drifted.

---

## 1. `aw guard` reads the agent's own copy of `zones.toml`

**Where.** `bin/aw`, top of file: `ROOT="$(git rev-parse --show-toplevel)"`,
then `AGENTS_DIR="$ROOT/.agents"`. `cmd_guard` runs as a pre-commit hook inside
the agent's worktree, so `$ROOT` is that worktree and every zone lookup reads
`<worktree>/.agents/zones.toml` — a file the agent can edit.

**Why it is not urgent.** The guard is a pre-commit hook running in the agent's
own context, where `git commit --no-verify` skips it outright. It is a seatbelt,
not a lock. An agent that edits `zones.toml` to widen its own zone still has to
get that edit past you in the diff, and `.agents/zones.toml` is itself a
hand-zone path, so the guard blocks committing it.

**Suggested fix.** Have `cmd_guard` read the zones file from the *main*
checkout — resolve `git rev-parse --git-common-dir`, take its parent, and read
`<main>/.agents/zones.toml` — falling back to the local copy only when the two
are the same tree. Cost: a repo whose `zones.toml` legitimately changes on a
branch would be judged by main's copy, which is arguably the point.

---

## 2. `aw plan` runs the architect unfenced, in your own tree

**Where.** `bin/aw`, `cmd_plan`: `run_role architect "$ROOT" "$prompt"` (and the
interactive leg, `claude --append-system-prompt … "$prompt"`, likewise in
`$ROOT`). The architect's chain at every tier ends in cheap third-party
providers — `zai-coding-plan/glm-5.3`, `moonshotai/kimi-k2.5`,
`deepseek/deepseek-v4-pro` — and none of the fence machinery is on this path:
no worktree, no sparse checkout, no `fence_reconcile`.

**Why it is not urgent.** The architect prompt tells it to use `aw scout`
(which *is* fenced, via the `_scout` mirror) rather than read source, and it is
told to write only under `.agents/`. That is a prompt, not a boundary.

**Suggested fix.** Give the architect the same fenced mirror the scout gets —
`scout_root` already builds and refreshes one; point `cmd_plan`'s headless leg
at it. The interactive `claude` leg is a deliberate exception (it is your own
CLI, on your own subscription, in your own tree) and should stay, but should
say so out loud.

---

## 3. `.agents/loom.env` is sourced as shell

**Where.** `bin/aw`, near the top:

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

**Suggested fix.** Parse it instead of sourcing it: read `KEY=VALUE` lines,
reject anything else, and `export` the pairs. Losing shell syntax there costs
the `${VAR:-default}` idiom the README documents, so either the parser handles
that one form or the README changes with it.

---

## 4. `OPENCODE_PERMISSION` is granted for the whole worktree root

**Where.** `bin/aw`, `run_headless`, the opencode leg:

```sh
perm="$(printf '{"external_directory":{"%s/*":"allow","%s/**":"allow"}}' "$WT_ROOT" "$WT_ROOT")"
```

The comment says allowing `$WT_ROOT` "does not widen the read-fence" because
every path under it is a fenced agent worktree. With fence profiles that is no
longer exactly true: another task's worktree under the same root may hold paths
released by a profile this task does not have.

**Why it is not urgent.** It grants opencode's *external directory* permission,
not a sandbox root; the agent must still go looking. Narrowing it to `$wd` was
tried upstream of this note and is what caused the failure the wide grant fixed
(opencode reported the worktree's *parent* as the external directory), so the
fix needs a check against a current opencode, not a one-line edit.

**Suggested fix.** Grant `$wd/*` and `$wd/**` plus whatever minimum makes
opencode's parser happy, and confirm against a live opencode that a
`cd <subdir> && perl -pi …` edit inside the worktree still runs.
