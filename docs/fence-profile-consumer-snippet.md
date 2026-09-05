# Fence profile: the snippet for `graduated-wallet`

For the owner of the consuming repo to **commit by hand**. `.agents/zones.toml`
is itself a hand-zone file there ("an agent may propose a change here, never
commit one"), and this is a policy change: which provider may see the custody
core. Read it, do not paste it blind.

Requires an `aw` with fence profiles (this branch or later). Verify first:

```sh
aw doctor | grep -E 'fence:|fence profile'
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
# A task opts in with `aw new <task> --fence-profile codex`, and EVERY later
# command for that task repeats the flag (run, check, loop, diff, rebase,
# land). `aw`
# then:
#   * builds the worktree fenced by [fence] MINUS `release` — so core/**,
#     docs/audits/** and docs/safety-assessment/** are present, ios/** and
#     spike/** are still absent;
#   * DIES before creating that worktree if any model in any chain that would
#     run there (implementer, reviewer, and aw loop's auto-fix rounds —
#     fallbacks included) is not one of `providers`;
#   * puts that worktree under a SEPARATE root (your $LOOM_WORKTREES with
#     "-profiled" appended), so nothing unprofiled is ever pointed at a
#     directory holding released paths;
#   * checks, before each later command and before every fallback attempt, that
#     what is ON DISK in that worktree matches the profile you named — a
#     released tree with no flag, or a flag whose paths are not there, is
#     refused, not quietly re-fenced;
#   * checks what the branch's COMMITS touch as well, since a worktree can be
#     re-fenced after the fact — aw check/diff/loop/rebase/land all refuse a
#     history carrying a fenced path the profile does not release, and aw land
#     additionally refuses any [hand] path it does not release;
#   * lets the pre-commit guard accept commits to the released paths on that
#     branch, while still blocking the rest of [hand] (zones.toml, the control
#     plane, backend/migrations/**, ...) — as a SEATBELT: the guard runs in the
#     agent's own context, where `git commit --no-verify` exists, which is why
#     `aw land` re-checks the commits themselves;
#   * tells the reviewer the released paths are authorised for the task, so
#     they do not come back as "unauthorized hand/fence changes".
#
# The branch record (branch.agent/<task>.fenceprofile) is a consistency check
# only. It is agent-writable — anything running in the worktree can `git config`
# it — so it can refuse a command and never authorise one; and a MISSING record
# is a refusal too, with no escape (a worktree that happens to hold the released
# paths is not evidence: `git sparse-checkout disable` is one command). If a
# record was really yours and was lost, you restore it by hand. A
# `Fence-profile:` line in a task file is likewise honoured only when the same
# name is ALSO on the `aw new` command line: the file states intent, your flag
# is the consent.
#
# `release` entries must match [fence].paths verbatim, and must not be covered
# by another pattern that stays fenced — `aw` refuses anything else rather than
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

## 2. The chains for a profiled task — per command, not in `loom.env`

The default implementer chain is GLM/DeepSeek/Kimi and the default reviewer
chain is `codex-sub moonshotai/kimi-k2.5 deepseek/deepseek-v4-pro
zai-coding-plan/glm-5.3`. **Neither is usable under this profile**, and that is
the point: `aw` walks the WHOLE chain, not the first entry, because a fallback
fires on a rate limit without asking anyone. A rate-limited Codex falling
through to DeepSeek inside a worktree holding `core/**` is exactly the event
the profile exists to prevent.

So a profiled task pins both chains **on the command line**, alongside the flag
that every command needs:

```sh
LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw new 0007-c --fence-profile codex

LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw loop 0007-c --fence-profile codex

LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw check 0007-c --fence-profile codex        # review only

LOOM_MODELS_implementer="claude-sub" \
  aw run 0007-c --fence-profile codex          # if Codex refuses the task
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
#     aw loop <task> --fence-profile codex
```

## 3. `AGENTS.md` — one note

Under the existing zones section (the `**fence**` bullet):

```markdown
- **`fence_profiles.codex`** — a task may opt in with
  `aw new <task> --fence-profile codex` (a `Fence-profile: codex` line in the
  task file states the intent, but the flag is what consents to it) to get
  `core/**`, `docs/audits/**` and `docs/safety-assessment/**` back in its
  worktree. `ios/**` and `spike/**` stay fenced. **Every later command for that
  task repeats the flag** — `aw run|check|loop|diff|rebase|land <task>
  --fence-profile codex` — and both model chains must be pinned to providers
  the profile allows, per command. Only `claude-sub` and `codex-sub` may run
  against such a task: `aw` refuses to create the worktree otherwise, refuses
  any later command whose flag and worktree disagree, and the pre-commit guard
  accepts commits to exactly those released paths on that branch. Confirm the
  harness supports it before use: `aw doctor` must print a
  `fence profile 'codex'` line, exactly as it must print `fence: N pattern(s)`.
```

## 4. Check it took

```sh
aw doctor | grep "fence profile"
#   OK       fence profile 'codex': releases core/** docs/audits/** docs/safety-assessment/** to providers claude codex
#   WARN     fence profile 'codex': the implementer chain at tier standard reaches providers this profile does not allow: ... — a task on this profile needs LOOM_MODELS_implementer

# the refusal paths, before trusting anything:
aw new <some-task> --fence-profile codex        # must die naming the implementer chain
aw new <some-task> --fence-profile=             # must die: empty value

LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw new <some-task> --fence-profile codex      # must succeed
ls <worktree>/core <worktree>/ios               # core present, ios absent

aw check <some-task>                            # must die: the flag is missing
aw check <other-unprofiled-task> --fence-profile codex
                                                # must die: a profile cannot be
                                                # introduced after `aw new`

# and the record is not a key, in either direction:
git config --unset branch.agent/<some-task>.fenceprofile
aw check <some-task> --fence-profile codex      # must STILL die, and tell you
                                                # to restore the record by hand
git config branch.agent/<some-task>.fenceprofile codex   # your act, not aw's
```

Then read [`docs/KNOWN-GAPS.md`](KNOWN-GAPS.md) in the harness repo, in full:
it is the list of what a profile does **not** close, and it is kept current
there rather than summarised here. None of it is fixed by this snippet.
