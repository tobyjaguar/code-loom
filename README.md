# Loom — a multi-provider agent harness

> Personal coding harness, shared as-is under MIT. It works on the machines
> it was built for; `loom doctor` will tell you what yours is missing. Model
> IDs in configs go stale fast — verify before trusting, as the docs say.
> No support implied; issues and forks welcome.

Read `ARCHITECTURE.md` for the design and reasoning. This is the manifest and
quickstart.

## Billing policy (the point of all this)

Flat subscriptions do the work; pay-per-token APIs are only a relief valve:

| Surface | Billing | Used for |
|---|---|---|
| Claude subscription (`claude` CLI) | flat | architect (+ reviewer at `deep` tier) |
| ChatGPT subscription (`codex` CLI) | flat | reviewer — first in the `standard` and `deep` chains |
| GLM Coding Plan (Z.ai, `ZHIPU_API_KEY`) | flat | scout, implementer — the ~85% token share |
| DeepSeek / Moonshot API keys | per-token, cheap | fallback when a sub window is exhausted; decorrelated review |

There is **no `ANTHROPIC_API_KEY` anywhere in this system**, by design. When
the Claude sub is rate-limited, the architect degrades to GLM instead of
falling through to an expensive API bill. `loom` detects rate-limit failures and
walks each role's fallback chain automatically; `LOOM_SKIP="claude"` or
`eval "$(loom tier lean)"` forces the degradation manually.

## Files

```
ARCHITECTURE.md            the design and the reasoning behind it
AGENTS.md                  repo-facts template every agent reads (edit per repo)
install.sh                 copies all of this into a target repo

bin/loom                   the dispatcher — worktrees, model routing, gate, doctor
bin/loom-session           optional tmux layout: editor + shell + gate panes

.agents/
  gate.sh                  fmt / clippy / test. The deterministic reviewer.
                           A `gate:` target in your Makefile wins over auto-detection.
  zones.toml               hand / assist / auto, plus optional [fence].
                           Enforced by pre-commit hook (hand) and sparse
                           checkout (fence).
  PLAN_TEMPLATE.md  TASK_TEMPLATE.md
  loom.env                 optional. Per-project model chains and keys,
                           sourced after the global key file.
  plans/  tasks/  decisions/  reviews/

.opencode/
  opencode.json            per-role model assignment (built-in providers only)
  prompts/                 architect / scout / implementer / reviewer / build

vscode/tasks.json          optional VS Code tasks (gate as the default build task)
```

## Requirements

`git`, `bash`, `python3` ≥ 3.11 (for `tomllib`) — or any python3 with the
`tomli` backport installed (`pip install tomli`) — plus `jq`, `curl`, and
[`opencode`](https://opencode.ai) and the `claude` CLI (logged in to your
subscription). `tmux` optional (for `loom-session`). Everything is
GNU/BSD-portable — the same scripts run on macOS and Linux; `loom doctor`
verifies a new machine in one shot. `codex` optional (a second subscription
reviewer — see below); without it the reviewer chain just starts one entry
later.

## New machine bootstrap (Linux or macOS)

From zero to verified, in order:

```sh
# 1. base tools — Debian/Ubuntu shown; use dnf/pacman/brew equivalents
sudo apt install -y git jq curl python3 tmux         # python3 >= 3.11, or
                                                     # pip install tomli

# 2. the two agent CLIs
curl -fsSL https://opencode.ai/install | bash        # or: npm i -g opencode-ai
curl -fsSL https://claude.ai/install.sh | bash       # or: npm i -g @anthropic-ai/claude-code
claude                                               # first run: log in to your
                                                     # Claude subscription (browser)

# 3. this repo + your target project
git clone git@github.com:tobyjaguar/code-loom.git
cd code-loom && ./install.sh /path/to/your/repo # creates ~/.config/loom/env
$EDITOR ~/.config/loom/env                           # paste ZHIPU_API_KEY etc.

# 4. verify everything — binaries, keys, hooks, live model IDs
cd /path/to/your/repo && loom doctor
```

`loom doctor` is the machine's acceptance test: if it reports 0 failures, the
whole system works here. `~/.local/bin` must be on PATH (most distros do this
when the directory exists; log out/in if not).

## Install

```sh
./install.sh /path/to/audat        # copies harness, links bin, installs hook
                                   # (an existing pre-commit hook is moved to
                                   # pre-commit.pre-loom and still runs, after
                                   # the guard; re-running install is a no-op)

cd /path/to/audat
$EDITOR .agents/zones.toml         # do this honestly, it is the point
$EDITOR AGENTS.md                  # repo facts, keep under 100 lines

$EDITOR ~/.config/loom/env         # paste keys here: ZHIPU_API_KEY=... etc.
                                   # chmod 600; loom sources it automatically,
                                   # so keys never live in a repo or profile

loom doctor                        # verify binaries, keys, and MODEL IDS
```

`claude` must be logged in to your Anthropic subscription (it already is if
you use Claude Code). Nothing else touches Anthropic.

### Verifying model IDs

Model catalogs move weekly; never trust a config's IDs. Three checks, free to
authoritative:

1. `loom doctor` — checks every model in the routing chains and `opencode.json`
   against the public models.dev catalog, and (for providers whose key is set)
   against the provider's **live `/models` endpoint** — the ground truth of
   what your account can call.
2. `opencode models` — what your installed opencode accepts.
3. GLM Coding Plan note: it is a distinct opencode provider,
   `zai-coding-plan/...` (endpoint `api.z.ai/api/coding/paas/v4`), not `zai/...`
   (pay-per-token). Same `ZHIPU_API_KEY` env var.

## The loop

```sh
loom plan "streaming resampler"  # Claude sub, interactive; writes .agents/plans/0007-*.md
                                 # you review the plan, edit it, commit it
loom run 0007-c                  # GLM sub, isolated worktree, gate-enforced
loom check 0007-c                # different provider reviews the diff
loom diff 0007-c                 # you read it
loom land 0007-c                 # gate again, merge, clean up, tick the checkbox
```

Tasks marked `HAND` in the plan you write yourself. That is deliberate —
`loom plan` produces tutor-mode specs (contract + failing test + `todo!()`) for
those, and the pre-commit hook enforces the boundary.

When you hit a rate limit anywhere: `eval "$(loom tier lean)"` and keep going.

### Codex as a reviewer (codex-sub)

`codex-sub` is the OpenAI Codex CLI run headless on your ChatGPT subscription: a
second flat-rate reviewer, from a different lab than the model that wrote the
code, at no per-token cost. It sits first in the `standard` and `deep` reviewer
chains and is skipped silently where the CLI or the login is missing, so a
machine without it behaves exactly as before.

```sh
npm i -g @openai/codex          # or: brew install codex
codex login                     # browser; writes ~/.codex/auth.json
loom doctor                     # checks the binary and that auth file
```

`loom` invokes it as `codex exec --sandbox read-only`: a reviewer reads a diff and
answers, it never writes to the worktree. Only the model's final message lands
in `.agents/reviews/<task>-review.md` — the run transcript is kept just long
enough to spot a rate limit, which falls through to the next model in the chain
like any other provider. `LOOM_SKIP="codex"` takes it out.

Any role's chain can be replaced from the environment, without editing `loom`:

```sh
export LOOM_MODELS_reviewer="codex-sub deepseek/deepseek-v4-pro"
```

Per project, put those same lines in `.agents/loom.env` — sourced after the
global key file, so the project wins. Commit it or ignore it, as the project
prefers.

Note on precedence: `loom` sources the project `.agents/loom.env` after
reading the environment, so a plain `VAR=value` assignment there would
clobber a per-command override like `LOOM_MODELS_reviewer=... loom check`.
Write project pins with default-if-unset expansion —
`LOOM_MODELS_reviewer="${LOOM_MODELS_reviewer:-codex-sub deepseek/deepseek-v4-pro}"`
— so the command line always wins.

### Bounded review loop

```sh
loom loop 0007-c                       # run, review, feed a REVISE back, review again
LOOM_LOOP_ROUNDS=3 loom loop 0007-c    # default is 2
```

`loom run`, then `loom check`, up to `LOOM_LOOP_ROUNDS` rounds. `VERDICT: APPROVE`
ends it and hands you `loom diff` / `loom land`. `VERDICT: REVISE` appends the
review to the task file *inside the worktree* — never your tree — and re-runs
the implementer against it. A REVISE on the last round stops and escalates to
you: disagreement that survives the rounds is a spec problem, not a model
problem. A review with no verdict line at all is treated as truncated, not as a
rejection, and stops the loop without another implementer pass.

### PR-mode landing

In a repo with review gates, merging straight into your current branch is the
wrong last step. `--pr` (or `LOOM_LAND=pr` in the environment; the flag wins)
swaps the tail of the loop:

```sh
loom land 0007-c --pr           # gate in the worktree, then: git push -u origin agent/0007-c
                                # prints a ready `gh pr create ...` line — it never runs it
                                # nothing is merged, the branch stays, the checkbox stays unticked
loom drop 0007-c --keep-branch  # later: reclaim the worktree, keep the pushed branch
```

Tick the plan checkbox by hand when the PR merges. `loom land 0007-c` (or
`--merge`) is unchanged: gate, merge here, clean up, tick.

### Read fences

`[fence]` in `zones.toml` is stronger than `hand`. Where `hand` says "agents may
read but not edit", `fence` says *not even read*: those paths are removed from
every agent worktree by a sparse checkout, so the third-party models that do the
implementer and scout work never see them.

```toml
[fence]
reason = "Client work under NDA — no third-party model sees this tree."
paths = ["crates/audat-nda/**", "docs/audits/**"]
```

Read the honest limits in `ARCHITECTURE.md` § 5 before relying on it — in
particular, a fenced path the build needs will break the build in the worktree.
`loom zone <path>` reports fencing, and `loom doctor` warns about fence patterns
that match no tracked file.

## Editors

The harness has no editor integration and does not want one. Every durable
artifact is a file in the repo and every action is a CLI command, so whatever
you already use works: open `.agents/plans/0007-*.md` in it, read
`loom diff 0007-c`, run `loom land`. Nothing changes between machines or
editors.

Two optional conveniences ship with it, and deleting either breaks nothing:

- `.vscode/tasks.json` (installed by `install.sh`) puts the gate on the default
  build task, wired into the Problems panel, plus prompts for
  `loom scout` / `loom run` / `loom check` / `loom doctor`.
- `loom-session` opens a tmux window with `$EDITOR`, a shell for `loom`
  commands, and a gate/watch pane. Set `LOOM_SESSION_EDITOR` to override the
  left pane (a shell, if your editor lives outside the terminal).

Gate output stays in native tool format, so any editor's error parser can read
`.agents/reviews/<task>-gate.log` directly.

`loom diff` shows a patch through git's own pager by default. Point
`LOOM_DIFF_CMD` at whatever you prefer — the patch path is appended as the last
argument:

```sh
export LOOM_DIFF_CMD="delta"          # or: bat, less -R, code --wait, $EDITOR
```

## Migrating from `aw`

The dispatcher was called `aw` before this rename. Re-running `./install.sh` on
each repo does the upgrade: it links `loom`, removes the old `aw` it installed
(symlink, dangling symlink, or `--copy-bin` copy — never anything else), and
rewrites the pre-commit hook to call `loom guard`. One thing it will not do:
`.vscode/tasks.json`, `AGENTS.md`, `.opencode/opencode.json` and
`.agents/zones.toml` are never overwritten because you may have edited them, so
a pre-rename copy still says `aw`. The installer and `loom doctor` both point
those out; fix them by hand (the VS Code tasks and the `AGENTS.md` scout line
are the two that actually invoke the command).

```sh
cd /path/to/code-loom && git pull
./install.sh /path/to/your/repo
cd /path/to/your/repo && loom doctor
```

Do not skip the hook rewrite. The old hook calls `aw`, and its "not on PATH"
branch exits 0 — so an un-migrated hook does not fail loudly, it silently stops
guarding hand zones. `loom doctor` reports that as a FAIL.

Two behaviour changes ride along with the rename:

- `loom diff` streams through git's pager instead of opening `$EDITOR -R`. To
  keep the old behaviour: `export LOOM_DIFF_CMD="$EDITOR -R"`.
- The Neovim layer is gone. If you copied `nvim/loom.lua` or
  `nvim/codecompanion.lua` into your editor config, remove them — they call
  `aw`.
