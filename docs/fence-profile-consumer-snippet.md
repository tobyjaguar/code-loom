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
# A task opts in with `aw new <task> --fence-profile codex` or a
# `Fence-profile: codex` line in its task file. `aw` then:
#   * builds the worktree fenced by [fence] MINUS `release` — so core/**,
#     docs/audits/** and docs/safety-assessment/** are present, ios/** and
#     spike/** are still absent;
#   * DIES before creating that worktree if any model in any chain that would
#     run there (implementer, reviewer, and aw loop's auto-fix rounds —
#     fallbacks included) is not one of `providers`;
#   * lets the pre-commit guard accept commits to the released paths on that
#     branch, while still blocking the rest of [hand] (zones.toml, the control
#     plane, backend/migrations/**, ...);
#   * tells the reviewer the released paths are authorised for the task, so
#     they do not come back as "unauthorized hand/fence changes".
#
# `release` entries must match [fence].paths verbatim — `aw` refuses anything
# else rather than half-releasing a subsystem.
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

## 2. `.agents/loom.env` — one line

The default implementer chain is GLM/DeepSeek/Kimi, none of which the profile
allows, so a profiled task needs an explicit chain. Keep the default-if-unset
idiom so a per-command override still wins:

```sh
# Fence-profile tasks only (profile `codex` in zones.toml): the implementer and
# reviewer must both be a provider the profile allows. Codex first — it is the
# decorrelated lineage; claude-sub is the fallback when Codex refuses a
# remediation prompt, which it has done. Unprofiled tasks keep the normal
# chains: this is the *profiled* pin, applied per command, not a global.
#   LOOM_MODELS_implementer="codex-sub claude-sub" aw run <task>
#   LOOM_MODELS_implementer="claude-sub" aw run <task>     # if Codex refuses
LOOM_MODELS_reviewer="${LOOM_MODELS_reviewer:-codex-sub deepseek/deepseek-v4-pro}"
```

The existing reviewer line already starts with `codex-sub`, but its DeepSeek
fallback is not in `providers` — so under the profile `aw` will refuse the run
until the reviewer chain is narrowed for that command:

```sh
LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw loop 0007-c
```

That refusal is the feature: it is what stops a rate-limited Codex from falling
through to DeepSeek inside a worktree holding `core/**`.

## 3. `AGENTS.md` — one note

Under the existing zones section (the `**fence**` bullet):

```markdown
- **`fence_profiles.codex`** — a task may opt in with `Fence-profile: codex`
  (or `aw new --fence-profile codex`) to get `core/**`, `docs/audits/**` and
  `docs/safety-assessment/**` back in its worktree. `ios/**` and `spike/**`
  stay fenced. Only `claude-sub` and `codex-sub` may run against such a task —
  `aw` refuses to create the worktree otherwise, and the pre-commit guard
  accepts commits to exactly those released paths on that branch. Confirm the
  harness supports it before use: `aw doctor` must print a
  `fence profile 'codex'` line, exactly as it must print `fence: N pattern(s)`.
```

## 4. Check it took

```sh
aw doctor | grep "fence profile"
#   OK       fence profile 'codex': releases core/** docs/audits/** docs/safety-assessment/** to providers claude codex
#   WARN     fence profile 'codex': the implementer chain at tier standard has non-released providers: ... — a task on this profile needs LOOM_MODELS_implementer

# the refusal path, before trusting anything:
aw new <some-task> --fence-profile codex        # must die naming the implementer chain
LOOM_MODELS_implementer="codex-sub claude-sub" \
LOOM_MODELS_reviewer="codex-sub claude-sub" \
  aw new <some-task> --fence-profile codex      # must succeed
ls <worktree>/core <worktree>/ios              # core present, ios absent
```
