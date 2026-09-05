# Known gaps

Holes an adversarial review found in the harness that are **not fixed** on this
branch. All four pre-date fence profiles and none is *caused* by them — but
gap 4's consequence is **widened** by profiles, because a worktree under a
profile holds paths the fence normally removes, and a grant that reaches
another worktree therefore reaches more than it used to. Round 2 narrowed that
grant and split profiled worktrees onto their own root; what is left of gap 4
is a confirmation, and it is written up that way below.

They are written down here so that the fence-profile work is not mistaken for
closing them, and so they are not re-discovered from scratch.

Every gap carries a `bin/aw:<line>` anchor as of this commit. Line numbers
drift; the quoted text is the durable handle, so grep for it.

---

## 1. `aw guard` reads the agent's own copy of `zones.toml`

**Where.** `bin/aw:59` (`ROOT="$(git rev-parse --show-toplevel …)"`) and
`bin/aw:63` (`AGENTS_DIR="$ROOT/.agents"`); the reader is `cmd_guard`,
`bin/aw:1020`. `cmd_guard` runs as a pre-commit hook inside
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

**Where.** `bin/aw:1709`, in `cmd_plan` (`bin/aw:1690`):
`run_role architect "$ROOT" "$prompt"` (and the
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

**Where.** `bin/aw:84`:

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

## 4. The narrowed `OPENCODE_PERMISSION` grant is unconfirmed against a live opencode

**Status: narrowed in round 2, not yet confirmed on a live opencode.** This gap
used to read "granted for the whole worktree root". It is not that any more;
what is left is a confirmation.

**Where.** `bin/aw:288`, in `run_headless` (`bin/aw:201`), the opencode leg:

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
and `aw` burns every attempt. If that appears: add the minimum extra entry
opencode's parser needs (its *parent*, i.e. the worktree root of THAT task's
kind) rather than reverting to `$WT_ROOT`, and record here which one it was.
