# Fence profile: the snippet for `graduated-wallet`

For the owner of the consuming repo to **commit by hand**. `.agents/zones.toml`
is itself a hand-zone file there ("an agent may propose a change here, never
commit one"), and this is a policy change: which provider may see the custody
core. Read it, do not paste it blind.

Requires a `loom` with fence profiles (this branch or later). Verify first:

```sh
loom doctor | grep -E 'fence:|fence profile'
```

## 1. `.agents/zones.toml` — add one table

Insert directly after the existing `[fence]` table, before `[hand]`:

```toml
# ---------------------------------------------------------------------------
# fence profile — a NAMED, per-provider relaxation of the fence above.
#
# The fence is one bit for all models. This is the finer decision the product
# owner actually made (2026-09): Codex (OpenAI, ChatGPT sub) and the Anthropic
# CLIs MAY read and edit core/**, and read the audit corpus; DeepSeek, GLM and
# Moonshot never may. Nothing changes for a task that does not opt in.
#
# A task opts in with `loom new <task> --fence-profile codex`, and EVERY later
# command for that task repeats the flag (run, check, loop, diff, rebase,
# land). `loom`
# then:
#   * builds the worktree fenced by [fence] MINUS `release` — so core/**,
#     docs/audits/** and docs/safety-assessment/** are present, ios/** and
#     spike/** are still absent;
#   * DIES before creating that worktree if any model in any chain that would
#     run there (implementer, reviewer, and loom loop's auto-fix rounds —
#     fallbacks included) is not one of `providers`;
#   * puts that worktree under a SEPARATE root (your $LOOM_WORKTREES with
#     "-profiled" appended), so nothing unprofiled is ever pointed at a
#     directory holding released paths;
#   * checks, before each later command and before every fallback attempt, that
#     what is ON DISK in that worktree matches the profile you named — a
#     released tree with no flag, or a flag whose paths are not there, is
#     refused, not quietly re-fenced;
#   * checks what the branch's COMMITS touch as well, since a worktree can be
#     re-fenced after the fact — loom check/diff/loop/rebase/land all refuse a
#     history carrying a fenced path the profile does not release, and loom land
#     additionally refuses any [hand] path it does not release;
#   * lets the pre-commit guard accept commits to the released paths on that
#     branch, while still blocking the rest of [hand] (zones.toml, the control
#     plane, backend/migrations/**, ...) — as a SEATBELT: the guard runs in the
#     agent's own context, where `git commit --no-verify` exists, which is why
#     `loom land` re-checks the commits themselves;
#   * tells the reviewer the released paths are authorised for the task, so
#     they do not come back as "unauthorized hand/fence changes".
#
# The record of which profile a task was created under is a consistency check
# only: it can refuse a command and never authorise one, and a MISSING record is
# a refusal too, with no escape (a worktree that happens to hold the released
# paths is not evidence: `git sparse-checkout disable` is one command). If a
# record was really yours and was lost, you re-create the task. It lives in the
# OPERATOR RECORD, outside every repo and outside the shared .git —
# ${XDG_CONFIG_HOME:-~/.config}/loom/repos/<sha256 of the repo path>/tasks/<task>
# — because everything under .git/ (branch config AND refs) is writable from any
# linked worktree. A `Fence-profile:` line in a task file is likewise honoured
# only when the same name is ALSO on the `loom new` command line: the file states
# intent, your flag is the consent.
#
# `release` entries must match [fence].paths verbatim, and must not be covered
# by another pattern that stays fenced — `loom` refuses anything else rather than
# half-releasing a subsystem.
#
# LIMIT, unchanged from the fence itself: the git object store is shared with
# every worktree. This scopes EXPOSURE (what an agent finds in front of it, and
# which provider is allowed to be that agent). It is not exfiltration defence.
[fence_profiles.codex]
reason = "Codex (ChatGPT sub) and the Anthropic CLIs may read and edit the custody core and read the audit corpus. Third-party API providers never may."
release = [
  "core/**",
  "docs/audits/**",
  "docs/safety-assessment/**",
]
providers = ["claude", "codex"]
```

`ios/**` and `spike/**` are deliberately NOT released: iOS is out of Loom's
scope v1 and cannot be gated locally at all, and `spike/**` is unreviewed
exploratory code including live-key harnesses.

## 1b. `.agents/zones.toml` — three paths that belong in `[hand]`

Check that `[hand].paths` in the consuming repo lists the control plane itself,
and add what is missing:

```toml
  ".agents/gate.sh",
  ".agents/zones.toml",
  ".agents/loom.env",
```

An agent may **propose** a change to any of the three — that is what the hand
zone means — and may never commit one, because each is an input to the checks
that judge the agent's own work:

* `.agents/gate.sh` decides "green, commit it" (`loom run`) and "green, land it"
  (`loom land`). `loom` runs the **main checkout's** copy for both, with the
  worktree as its cwd, precisely because the worktree's copy is a file the
  implementer edits — but a worktree copy that *landed* would become the main
  checkout's copy for the next task.
* `.agents/zones.toml` is the zones, the fence and the profiles. An agent able
  to commit it could widen its own zone, and the pre-commit guard is a seatbelt
  (`--no-verify`), not a lock.
* `.agents/loom.env` is `.`-sourced as shell, in your environment, on every
  `loom` invocation (`docs/KNOWN-GAPS.md` § 3).

`loom land` checks the branch's commits against `[hand]` regardless of what the
guard did, so this is the entry that actually holds.

## 2. The chains for a profiled task — per command, not in `loom.env`

The default implementer chain is GLM/DeepSeek/Kimi and the default reviewer
chain is `codex-sub moonshotai/kimi-k2.5 deepseek/deepseek-v4-pro
zai-coding-plan/glm-5.3`. **Neither is usable under this profile**, and that is
the point: `loom` walks the WHOLE chain, not the first entry, because a fallback
fires on a rate limit without asking anyone. A rate-limited Codex falling
through to DeepSeek inside a worktree holding `core/**` is exactly the event
the profile exists to prevent.

So a profiled task pins both chains **on the command line**, alongside the flag
that every command needs:

```sh
LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  loom new 0007-c --fence-profile codex

LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  loom loop 0007-c --fence-profile codex

LOOM_MODELS_reviewer="codex-sub claude-sub" \
  loom check 0007-c --fence-profile codex        # review only

LOOM_MODELS_implementer="claude-sub" \
  loom run 0007-c --fence-profile codex          # if Codex refuses the task
```

**Do not put those chains in `.agents/loom.env`.** That file applies to every
task in the repo, profiled or not, and pinning two subscription CLIs globally
would push all your unprofiled work onto them — the opposite of the billing
policy. Keep it per command, where the flag already is.

If you want a reminder rather than a setting, a comment in `.agents/loom.env`
is the honest form:

```sh
# Fence-profile tasks (profile `codex` in zones.toml) must pin BOTH chains to
# providers the profile allows, per command — never here, or every unprofiled
# task lands on the subscription CLIs too:
#   LOOM_MODELS_implementer="codex-sub claude-sub" \
#   LOOM_MODELS_reviewer="codex-sub claude-sub" \
#     loom loop <task> --fence-profile codex
```

## 3. `AGENTS.md` — one note

Under the existing zones section (the `**fence**` bullet):

```markdown
- **`fence_profiles.codex`** — a task may opt in with
  `loom new <task> --fence-profile codex` (a `Fence-profile: codex` line in the
  task file states the intent, but the flag is what consents to it) to get
  `core/**`, `docs/audits/**` and `docs/safety-assessment/**` back in its
  worktree. `ios/**` and `spike/**` stay fenced. **Every later command for that
  task repeats the flag** — `loom run|check|loop|diff|rebase|land <task>
  --fence-profile codex` — and both model chains must be pinned to providers
  the profile allows, per command. Only `claude-sub` and `codex-sub` may run
  against such a task: `loom` refuses to create the worktree otherwise, refuses
  any later command whose flag and worktree disagree, and the pre-commit guard
  accepts commits to exactly those released paths on that branch. Confirm the
  harness supports it before use: `loom doctor` must print a
  `fence profile 'codex'` line, exactly as it must print `fence: N pattern(s)`.
```

## 4. Check it took

```sh
loom doctor | grep "fence profile"
#   OK       fence profile 'codex': releases core/** docs/audits/** docs/safety-assessment/** to providers claude codex
#   WARN     fence profile 'codex': the implementer chain at tier standard reaches providers this profile does not allow: ... — a task on this profile needs LOOM_MODELS_implementer

# the refusal paths, before trusting anything:
loom new <some-task> --fence-profile codex        # must die naming the implementer chain
loom new <some-task> --fence-profile=             # must die: empty value

LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  loom new <some-task> --fence-profile codex      # must succeed
ls <worktree>/core <worktree>/ios               # core present, ios absent

loom check <some-task>                            # must die: the flag is missing
loom check <other-unprofiled-task> --fence-profile codex
                                                # must die: a profile cannot be
                                                # introduced after `loom new`

# and the record is not a key, in either direction:
rm "${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/"*"/tasks/<some-task>"
loom check <some-task> --fence-profile codex      # must STILL die, telling you to
                                                # loom drop && loom new the task
```

The record is a file you own, not a git object: `loom new` writes it, `loom rebase`
re-points its `base`, `loom drop` deletes it (with or without `--keep-branch`),
and `loom ls` shows the profile it names. A task created by an older `loom` has no
record, so `loom check|diff|loop|rebase|land` on it refuses with "no operator
record for task X" — `loom drop X && loom new X` is the fix, and there is no
migration to run beyond that.

## 5. One thing to check that is not about profiles

Every check of what a branch's **commits** touch is measured from the commit
your checkout was on when `loom new` created the task, recorded in the operator
record above. There is nothing to configure: no trunk to name, no
`LOOM_BASE_REF` (it is gone), and no dependence on `origin/main` being fetched
or up to date. Two consequences worth knowing before you rely on it:

* **Your own unpushed commits on `main` are not the task's.** The previous
  design measured from `merge-base(origin/main, agent/<task>)` and counted
  everything `main` had that `origin/main` did not as the branch's own work —
  a fenced path you committed yourself refused an agent task that never touched
  it.
* **A base is never derived from anything in `.git`.** Branch config and refs
  are both writable from inside a linked worktree (`git config
  branch.<br>.loombase <tip>`, `git update-ref refs/remotes/origin/main <tip>`),
  and either one emptied every check. So is the worktree's `HEAD`: the history
  endpoint is the branch ref `refs/heads/agent/<task>`, resolved to a SHA once
  per command and used as that sha for the checks, the review patch, the merge
  and the push; a worktree that is not on its own branch is refused.
* **`loom rebase` will not bury upstream commits under your base.** Moving the
  base makes everything between the old one and the new one upstream, i.e.
  invisible to every later check. If those commits touch a fenced or `[hand]`
  path, `loom rebase` refuses and prints them; `--accept-upstream` is the
  operator's "I have read those and I accept them under the base".
* **`loom check` stamps the tip it reviewed, and `loom land` refuses any other.**
  A commit added after the reviewer read the patch does not ride the review
  into the merge — re-run `loom check`. Landing also refuses a worktree with
  uncommitted changes (`.agents/reviews/` excepted, which is where `loom` writes
  the patch itself — gitignore that directory).

```sh
# the record for a task, if you ever want to read one:
cat "${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/"*"/tasks/<some-task>"
#   base=<commit>  profile=<name>  branch=agent/<task>  created=<iso>
#   origin=<remote.origin.url at loom new>  reviewed=<tip loom check last reviewed>
```

Then read [`docs/KNOWN-GAPS.md`](KNOWN-GAPS.md) in the harness repo, in full:
it is the list of what a profile does **not** close, and it is kept current
there rather than summarised here. None of it is fixed by this snippet.
