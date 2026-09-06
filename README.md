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
  zones.toml               hand / assist / auto, plus optional [fence]
                           and [fence_profiles] (per-provider relaxations).
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
git clone git@github.com:tobyjaguar/coding-harness.git
cd coding-harness && ./install.sh /path/to/your/repo # creates ~/.config/loom/env
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
loom pin-config                    # record this repository's git config as the
                                   # baseline `loom plan` and `loom scout` are
                                   # judged against (`loom new` writes it too,
                                   # so this is for a repo with no tasks yet)
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
in the review file — the run transcript is kept just long enough to spot a rate
limit, which falls through to the next model in the chain like any other
provider. `LOOM_SKIP="codex"` takes it out.

The review is written to the **operator's** copy first,
`${XDG_CONFIG_HOME:-~/.config}/loom/repos/<key>/tasks/<task>.artifacts/<task>-review.md`,
and then placed in `.agents/reviews/<task>-review.md` in the worktree for the
implementer to read. The patch and the gate log go the same way. The copy in
the worktree is a courtesy: `loom loop` reads its verdict, and the REVISE text
it pastes into the task spec, from the operator's copy — see "The copies loom
acts on" below.

Codex can also be the *implementer*: a writable sandbox, granted per role, not
per model, on any run — see "Codex (or Claude) as an implementer" below. It is
not in a default chain, so it takes an explicit `LOOM_MODELS_implementer`.

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
that match no tracked file. Both are repo-wide, not task-scoped: they always
report the whole `[fence]`, never one task's relaxation of it.

#### Fence profiles

The fence is provider-agnostic: it hides a path from *every* agent. That is one
decision too coarse when the reason for fencing is "not this provider" rather
than "not any model" — a custody core you are happy to hand to the two
subscription CLIs you already trust with the rest of the repo, and unwilling to
send to a third-party API. A **fence profile** is a named, per-provider
relaxation of the fence:

```toml
[fence]
paths = ["core/**", "ios/**", "spike/**", "docs/audits/**"]

[fence_profiles.codex]
reason    = "Anthropic + OpenAI may read and edit the custody core."
release   = ["core/**", "docs/audits/**"]   # must be [fence].paths, verbatim
providers = ["claude", "codex"]             # provider_of(), not model IDs
```

A task that opts into `codex` gets a worktree fenced by `[fence]` **minus**
`release` — `core/**` and `docs/audits/**` are there, `ios/**` and `spike/**`
are still gone. A task with no profile is fenced by the whole `[fence]`, as
before.

**Unprofiled runs did get stricter, though**, and none of it is about profiles
— the fence-profile work was where the adversarial reviews happened, so the
fixes landed here. If you never write a `[fence_profiles]` table, this is the
part of the branch that still changes your runs:

- **The base is an operator record, outside every repo.** Every check of what a
  branch's *commits* touch is measured from the commit your checkout was on
  when `loom new` created the task, stored in
  `${XDG_CONFIG_HOME:-~/.config}/loom/repos/<sha256 of the repo path>/tasks/<task>`
  (mode 0700/0600, with a `repo` file beside it naming the checkout). Nothing
  inside the repository takes part: a linked worktree shares `.git` with your
  checkout, so `branch.<br>.loombase` (one `git config`) and the refs
  themselves (`refs/remotes/origin/main`, `refs/heads/main` — one
  `git update-ref`) are all writable from inside an agent's tree, and each of
  them could collapse the range a fence check looked at to nothing. That also
  fixes a false refusal in the other direction: your own unpushed commits on
  `main` used to count as the branch's.
  The record is outside the repository; the OBJECTS it names are not, and that
  is a separate lever — `refs/replace/<oid>` redirects the object an OID names
  for every git command, and those refs live in the shared `.git` too. So
  `loom` turns replacement off for every git it runs
  (`core.useReplaceRefs=false` and `GIT_NO_REPLACE_OBJECTS=1`) **and** refuses
  outright, naming each ref, if the repository has any: a replacement planted
  while agents were running emptied all three checks at once, and it is not a
  thing to run beside.
  `loom new` writes the record, `loom rebase` re-points it (the one command that
  moves a base, and it is yours), `loom drop` deletes it, and every check reads
  it. A missing record, a base that does not resolve, a base that is not an
  ancestor of the branch, and a branch with nothing past its branch point are
  each a refusal with their own message — never an empty answer.
  `$LOOM_BASE_REF` is gone with the merge-base it named.
- **The history endpoint is the branch ref**, `refs/heads/agent/<task>` read in
  your checkout, and never the worktree's `HEAD`: `git checkout --detach
  HEAD~1` after a fenced commit left the tree looking clean while the branch
  still carried the commit into the merge. A worktree whose `HEAD` is not its
  own branch is refused outright — it is not a state `loom` produces.
- **The worktree roots are verified.** Both are normalised (a trailing `/` or
  `/.` in `$LOOM_WORKTREES` is stripped before `-profiled` is appended),
  resolved through the parent chain (python3 `realpath`, in `resolve_root`, so a
  root that does not exist yet resolves without being created) and refused if
  the resolved path is not where the name says — a symlink at
  `$WT_ROOT-profiled` would otherwise put released content inside the directory
  unprofiled runs are pointed at. `WT_ROOT_PROFILED` is
  derived, never taken from the environment or `loom.env`. Every `git worktree
  add` re-resolves its parent immediately before, and the created worktree
  immediately after.
- **"Which fenced paths are present" is asked of the disk**, not just of `git
  ls-files`, so an untracked `core/copy.rs` — `git show HEAD:core/lib.rs >
  core/copy.rs` never touches the index — is a dead stop instead of an
  invisible one. (Content copied to a path the fence does *not* name is still
  the exfiltration class; see "What a profile is not".)
- **An existing branch is refused**, never walked over: `loom new` used to arm
  its cleanup trap before `git worktree add -b`, so an add that failed because
  `agent/<task>` already existed deleted that branch and its commits. A branch
  the failing `loom new` *itself* created **is** removed, and it says so — `git
  worktree add -b` creates the branch and can then fail on the path, and an
  orphan there made the task id unusable forever.
- **A worktree holding fenced paths is refused**, not quietly re-applied — the
  worktree's own diff carries the content regardless. There is no "the record
  says this would have been fine" arm any more, and there will not be one: a
  record is agent-reachable state and can only ever refuse.
  The **one** exception is not about the tree at all. If you widen `[fence]`
  while a task's worktree exists, the paths it is now holding are there because
  `loom new` was right to check them out, and refusing stranded the task (the
  only recovery on offer was `loom drop`, after which `loom new` refuses —
  "branch already exists"). So `loom` compares your `[fence]` **now** against
  `git show <the task's recorded base>:.agents/zones.toml` — your own file at a
  commit in your own trunk. A present path that only a pattern **added since
  the base** matches is your change: `loom` re-fences the worktree, prints one
  note naming the patterns, and carries on. A present path that a pattern which
  **already existed** matches is the agent's doing and still refuses. No base,
  no `zones.toml` at the base, or anything unreadable: every pattern counts as
  pre-existing and the refusal stands.
- **The history is refused in `check`, `diff`, `loop`, `rebase` and `land`**
  when the branch's commits touch a fenced path, and `land` refuses a `[hand]`
  path in those commits too. `--force` skips the gate, not this.
- **opencode's grant narrowed** from the whole worktree root to the role's own
  worktree, and opencode now reads *your* `.opencode/opencode.json`
  (`OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR`) with
  `OPENCODE_DISABLE_PROJECT_CONFIG=1` — the worktree copy is a file the agent
  can rewrite, and it carries provider endpoints and role prompts. **The
  disable is unconditional**, including in a repo that has no
  `.opencode/opencode.json` of its own — which is exactly the repo where the
  worktree's copy would otherwise be the only config there is. **The cost,
  plainly:** opencode no longer reads the worktree's `AGENTS.md`/`CLAUDE.md`,
  its `.opencode/` directory, or any project-local plugin. Role prompts come
  from `$ROOT/.opencode/prompts/` via `{file:./prompts/…}` in your config —
  the same copy the `claude` and `codex` legs already used — so if a repo's
  opencode roles depended on `AGENTS.md` reaching the model, that content has
  to move into the role prompt.
- **Policy comes from the MAIN checkout, whichever tree you typed the command
  in.** `$ROOT` used to be `git rev-parse --show-toplevel`, so `cd
  <a worktree> && loom new t5` read *that worktree's* `.agents/zones.toml` (the
  fence it was about to apply — an agent that emptied it got an unfenced task)
  and sourced *that worktree's* `.agents/loom.env` as shell in your
  environment. It is now the parent of `git rev-parse --git-common-dir`. One
  thing still comes from the invoking tree, and only one: `loom guard`'s subject —
  the staged files and the tree it is judging are the ones the commit is
  happening in, while the zones it judges them by are the main checkout's.
  (That also closes `docs/KNOWN-GAPS.md` gap 1.)
- **The branch tip is resolved once per command, into a sha.** Every command
  used to re-resolve `refs/heads/agent/<task>` per use — the history check, the
  review patch, the merge, the push — and the ref lives in the shared `.git`,
  one `git update-ref` from something else. The checks, the patch, `git merge
  --no-ff <sha>` and `git push origin <sha>:refs/heads/agent/<task>` are now all
  the same sha.
- **`loom check` records the tip it reviewed; `loom land` refuses any other**,
  naming both shas and asking for a fresh `loom check`. A commit added after the
  reviewer read the patch does not ride the review into the merge. `--force`
  skips the gate, not this. `loom rebase` clears the stamp, because the sha a
  reviewer read no longer exists on a rebased branch.
- **`loom run` and `loom land` run the OPERATOR's `.agents/gate.sh`** (with the
  worktree as its cwd), never `<worktree>/.agents/gate.sh`. The worktree's copy
  is a file the implementer edits — the `claude` leg even allowlists running it
  — and it was deciding "green, commit it" and "green, land it". The
  implementer still runs the worktree's copy for its own iteration; the verdict
  `loom` acts on is yours.
- **Landing refuses a dirty worktree.** Uncommitted work is not the branch's
  work: what the reviewer read and what the merge would carry have come apart.
  `.agents/reviews/` is excluded, because that is where `loom check` and `loom diff`
  write the review patch themselves — **gitignore that directory** in a
  consuming repo. The exclusion applies only while `.agents/reviews` really is
  loom's own scratch (see the next bullet): neither it nor `.agents` a symlink,
  the directory physically inside the worktree, and **every entry in it a plain
  file with one name**. Anything else counts as dirty, and landing refuses.

  That check is two steps, and the second one exists **because** you gitignored
  the directory. Step one is `git status --porcelain --untracked-files=normal
  -- .`, with the `:(exclude).agents/reviews` pathspec dropped the moment the
  directory stops being loom's own plain scratch. In a repo that ignores
  `.agents/reviews/`, dropping the pathspec changes nothing — a link planted
  inside an ignored directory is an ignored path, and `git status` will not
  mention it either way. So whenever the exclusion is dropped, `loom` asks the
  same directory a second time with `git status --porcelain
  --untracked-files=normal --ignored=matching -- .agents/reviews` and appends
  those `!!` lines to the dirty output. The plant surfaces as an `!!` line and
  landing refuses.

  **git names the entry only when something makes it descend.** In the shape
  this README asks you for — `.agents/reviews/` gitignored and *nothing tracked
  inside it* — `--ignored=matching` collapses to the single line
  `!! .agents/reviews/` (measured, git 2.34.1, with and without `-uall`): the
  refusal fires, but it names a directory where you need a file. git prints
  `!! .agents/reviews/<name>` only when a tracked file in there forces it to walk
  in. So `loom` appends the entry it refused on itself, either way, with the same
  prefix:

  ```
  !! .agents/reviews/<name>  (not loom's plain scratch: symlink)
  ```

  (or `not a regular file`, or `link count N`).

  **An unreadable directory is a refusal, not a clean tree.** `.agents` or
  `.agents/reviews` at mode `0300` still answers `cd` and `pwd -P`, but a shell
  glob over it matches *nothing* — so the entry walk saw an empty directory,
  called it plain, and left the exclusion on over everything planted inside. And
  dropping the exclusion would not have saved it: `git status` reports an
  unreadable directory as a **warning on stderr with exit 0**, listing nothing
  from inside it. `loom` refuses on the mode of either directory, and — the
  general form, for an unreadable directory anywhere in the tree — refuses
  whenever either `git status` writes anything at all to stderr. Two config keys
  are pinned for the same reason: `status.showUntrackedFiles=normal` (a `no` in
  any scope empties step one and makes step two exit 128) and
  `core.untrackedCache=false`.

  It is a **tripwire**, not the lock. What actually closes the write path is
  `place_file` (resolve the directory, hold it as the working directory, rename
  a fresh file onto the target, assert what is left is one plain file) and the
  read path `probe_agent_file` — both regardless of what any repo ignores.
- **The review directory is RESOLVED before loom writes into it, and the write
  REPLACES the file rather than following it.**
  `.agents/reviews` is the one place loom writes on the agent's side of the
  fence — the review **patch** (which carries the content of every path in the
  diff, released paths included), the gate log, and the review text — and it is
  a directory the agent can replace with a symlink. `mkdir -p` on a path that
  already resolves to a directory succeeds silently, so a swap redirected all
  three, and the obvious target is another task's worktree: an *unprofiled*
  tree, under the other root, that a provider this profile does not allow is
  about to run in. `loom` now resolves it physically before every write and
  refuses anything outside the worktree, at **two** levels — `.agents` (checked
  *before* the `mkdir`, which would otherwise create the directory at the far
  end of the link) and `.agents/reviews` (the stealth variant, with `.agents`
  left intact) — and writes to what it resolved to rather than re-deriving the
  path. The same rule applies to the `--add-dir` sandbox root an implementer is
  granted.

  One level down, the FILE was the same hole: `>` follows a symlink at
  `.agents/reviews/<task>.patch`, and a **hard link** there is the same
  redirect with nothing to see in `ls -l`. So every loom write into a worktree
  — the patch, the review, the gate log, and `loom loop`'s append to
  `.agents/tasks/<task>.md` — re-resolves the directory, writes to a fresh temp
  **inside** it and **renames** that onto the target: rename replaces the
  directory entry instead of following it, and the result is checked to be a
  plain one-link file or the command dies. `<task>-blocked.md`, the one file
  loom reads back out of the tree, is refused outright if it is a link rather
  than read as "the implementer is blocked".
- **The copies loom acts on live beside the operator record, not in the
  worktree.** `loom check` writes the patch and the review — and `loom run` the
  gate log — to
  `${XDG_CONFIG_HOME:-~/.config}/loom/repos/<key>/tasks/<task>.artifacts/`
  first (0700/0600, removed by `loom drop` with the rest of the task's state),
  and only then places a copy in `.agents/reviews/` for the agent to read. The
  worktree copy is **0600** as well — it is a `mktemp` renamed into place, and
  that is mktemp's mode, not the umask's.
  `loom loop` takes its VERDICT — and the REVISE text it pastes into the task
  spec — from the operator's copy, and `loom land` takes `reviewed` from the
  record. The tree being judged does not get to write what judges it.
- **`loom rebase` will not bury ANY upstream commits under your base without
  your word.** A rebase is the one command that moves a recorded base, and
  everything between the old base and the new one stops being the branch's work
  — it slides *under* the base, where no fence check, no hand check and no
  review patch looks again. `refs/remotes/origin/main` is one `git update-ref`
  from any commit, and unlike your own `main` (the branch you are standing on,
  which moves in front of you) a moved `origin/main` is visible nowhere. So a
  non-empty `old_base..new_base` needs `--accept-upstream` — **whatever it
  contains.** The gate used to be "the range touches a fenced or a hand-zone
  path", which let a range of merge commits, or one touching only the assist
  zone, move the base in silence; burial is a *review* question, not a fence
  one, and "it touches nothing I check" is not the same statement as "it is
  nothing". The whole range is printed whenever the base moves, on the refusal
  and under the flag alike: the fenced and hand-zone lists first (mapped through
  the **full** `[fence]` and `[hand]` — a profile releases paths for the *task's*
  commits, and nobody released anything for what arrives from upstream), then
  `git log --oneline old_base..new_base`, then **every path those commits
  touch**. In an active repo this fires on your own commits merged upstream
  while the task ran — that is the intended shape, not a bug: the flag is a
  one-word confirmation, not an override.
- **A rebase replays onto `origin/<branch>` or onto a local branch, and nothing
  else.** loom moves the recorded base, so it has to be able to *refresh* what
  it replays onto first. `origin/<b>` is fetched here with an explicit refspec
  naming both ends, and requires an `origin` remote — without one,
  `refs/remotes/origin/<b>` is a purely local ref that nothing refreshes and one
  `git update-ref` from anything. A local branch is allowed and loom says out
  loud that nothing was fetched (a fetch updates `refs/remotes/*`, never
  `refs/heads/*`). Any other remote-tracking ref is refused: `loom rebase T
  upstream/main` used to skip the fetch entirely — only `origin/*` ever got a
  refspec — and replay the base onto whatever `refs/remotes/upstream/main` said.
  A failed `git fetch` is a refusal for the same reason: replaying onto a stale
  upstream succeeds quietly.
- **The remote is pinned to the task — the URL, the refspec *and* the push
  destination.** All three are recorded at `loom new`; `loom rebase` (before it
  fetches) and `loom land --pr` (before it pushes) refuse when any of them
  differs. Remote config is in the shared `.git/config`, and the two beyond the
  URL are the quiet ones:
  - the **refspec** pointed at `refs/remotes/decoy/*` makes `git fetch origin`
    succeed while updating nothing under `refs/remotes/origin/`, so a forged
    `origin/main` survives the fetch and the rebase replays onto it.
    `loom rebase` therefore writes the refspec out itself —
    `git fetch origin +refs/heads/<b>:refs/remotes/origin/<b>` — instead of
    trusting the config to say what a fetch is for;
  - the **push URL** is not `remote.origin.url` at all. A
    `remote.origin.pushurl`, or a `url.<decoy>.pushInsteadOf = <the real
    origin>` rewrite, sends the push somewhere else while `git remote get-url
    origin` goes on answering exactly what the record pinned — and
    `loom land --pr` is the one command here that publishes an agent's commits
    to a host. It is recorded as `git remote get-url --push origin`, which is
    the effective answer after both. `protocol.ext.allow=never` is set for every
    git subprocess loom spawns as well, so an `ext::<program>` URL is dead
    twice over.
- **The operator record is one field per line, and `loom` wrote every one of
  them.** `origin` and `fetch` arrive from `.git/config`, where a value may
  contain a newline — so a URL of `https://…` + newline + `reviewed=<sha>` used
  to append a second field to the record. `state_put` refuses a control
  character in any value and a key outside the fixed list
  (`base profile branch created origin fetch pushurl reviewed`); `state_read` refuses a
  file with a duplicated field, an unknown key or a line that is not
  `<key>=<value>`, instead of taking the first match and carrying on.
- **`loom run` with no operator record refuses before the model runs.** It used to
  run one and commit, with the refusal arriving at `loom check` and the content
  already on the branch.
- **Repo-local git config is not a code channel.** `.git/config` is in the
  shared git directory, so `git -C <worktree> config core.pager /tmp/x` is one
  command from inside an agent's tree — and `core.pager`, `pager.<cmd>`,
  `core.fsmonitor`, `core.sshCommand`, `diff.external`,
  `remote.<n>.uploadpack`/`receivepack`, `core.editor` and `sequence.editor`
  each name a **program git runs**, in your session, the next time you type a
  `loom` command. `loom` now exports its own `GIT_CONFIG_PARAMETERS` (the
  variable `git -c` uses, which outranks every config *file*) for every git
  subprocess it spawns, clears git's own `GIT_*` environment first — the config
  half of it too: `GIT_CONFIG_*`, `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`,
  `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `GIT_EDITOR`, `GIT_ASKPASS`, … — and spells
  out `--no-ext-diff`, `--upload-pack=` and `--receive-pack=` at the diff, fetch
  and push call sites, because those keys do not obey the variable (measured;
  see `ARCHITECTURE.md` § 5). **`pager.<cmd>` is the fourth:** measured in a
  pty, a `pager.log=<script>` ran straight through `core.pager=cat`, because
  git consults `pager.<cmd>` first — and a string-valued `pager.<cmd>` turns
  paging *on* for subcommands that never page, `update-ref` and `merge-base`
  included. `GIT_PAGER=cat` plus one `pager.<cmd>=cat` per subcommand loom runs
  is the lock. **Two costs:** `loom diff` no longer pages by default (`export
  LOOM_DIFF_CMD="less -R"` if you want one), and a repo-local `core.sshCommand`
  is ignored — your global one is not. Two more keys are pinned there that name
  no program at all — `core.untrackedCache=false` and
  `status.showUntrackedFiles=normal` — because they change what `git status`
  *reports*, which is the whole of the dirty-tree tripwire above.
- **...and the whole git config is PINNED to the task**, because the keys that
  matter cannot be enumerated: `filter.<anything>.clean`,
  `merge.<anything>.driver`, `pager.<anything>` and `includeIf.<anything>` put
  the attack in the **key name**, so there is no list for
  `GIT_CONFIG_PARAMETERS` to override — and `credential.helper` /
  `core.askPass` are handed your credential as well as being run. "The whole
  git config" is **three scopes and an include closure**, because
  `git config --local --list` is not what git reads:
  - `local` — `.git/config`, shared by every worktree;
  - `worktree-main` — `$GIT_COMMON_DIR/config.worktree`, the **main checkout's**
    own scope. A `core.hooksPath` there runs *your* hooks, in *your* checkout,
    during `loom land`'s merge;
  - `worktree-task` — `$GIT_COMMON_DIR/worktrees/<wt>/config.worktree`, the task
    worktree's own scope, one `git config --worktree <k> <v>` away from inside
    the agent's tree;
  - `include` — every file an `include.path` / `includeIf.<cond>.path` in any of
    those pulls in, recursively, digested by its raw bytes. `--list` prints
    those directives as **pointers** and never the keys they bring, so pinning
    the listing alone pins the pointer and nothing behind it.

  Both worktree scopes are live whenever `extensions.worktreeConfig` is on —
  which loom's own `git sparse-checkout init` turns on — and **neither shows up
  in `git config --local --list`**. Whether it is on is asked of git
  (`git config --local --type=bool --get`), not string-matched: git reads that
  key with `git_config_bool`, which is case-insensitive and treats a *valueless*
  key as true, so `True`, `ON` and a bare `worktreeConfig` line each read as
  "off" to a `true|yes|on|1` list while git went on reading both scopes. `loom new` records `config=<sha256 of all of
  that, sorted>` in the operator record, with the full list beside it as
  `<task>.gitconfig` (each entry tagged with its scope, plus one
  `include:<path>:<sha256>` record per included file — carrying the target's
  own **bytes**, capped at 64 KiB, so an edit to it is a `-`/`+` content diff
  and not a pair of digests; past the cap the value half reads
  `(<N> bytes, sha256 <hex>)` and the digest still does the change check) so a
  mismatch is shown as a diff that names the scope. Every
  `includeIf.<cond>.path` target is pinned **whatever the condition says**:
  `loom` does not evaluate `gitdir:` / `onbranch:` / `hasconfig:`, which
  over-refuses on purpose. It is recomputed and compared **before the first
  fence operation of every command**, **before every model launch** (per
  *attempt*, not per command), before `land`'s merge and its push, before
  `rebase`'s fetch and again before its replay, and before `check` and `diff`
  write the review patch. A change is a refusal; **`--accept-config`** is the one
  escape — it prints what changed and re-records it as the baseline, and
  **`loom new` refuses it**, because `new` is the command that pins and so has
  nothing to accept. `loom new` also prints one line saying what it pinned
  (`loom: pinned N local + M worktree config entries`), WARNs naming the
  targets when the config pulls other files in, and WARNs again naming every
  pinned key that names a **program git runs** — `core.hooksPath`,
  `credential.*`, `core.askPass`, `filter.*`, `merge.*.driver`,
  `diff.*.textconv`/`.command`, `gpg.program`, `pager.*`, `core.attributesFile`,
  `core.sshCommand`, `include.*`/`includeIf.*` — values escaped, tagged with the
  scope each came from, and **including the keys inside an included file**,
  tagged `[include:<path>]` (`--list` shows an include as a pointer and never
  the keys it brings, so a `core.hooksPath` one `include.path` away from
  `.git/config` was pinned in full and named nowhere). Those keys are what the
  pin ADOPTS as the baseline, and this is the one moment an operator is shown
  them. `loom` writes config on your
  behalf in exactly two places and both re-pin themselves (`loom new`'s first
  `sparse-checkout init`, which adds `extensions.worktreeConfig` locally and
  `core.sparseCheckout` at worktree scope; and `land --pr`'s
  `--set-upstream-to`). Everything else that changes it is you or an
  agent, so **an agent's `git config user.name` in its worktree will trip
  this** — deliberately: it is the same command as `git config
  credential.helper '!sh -c …'`. A record with no `config=` (one an older
  `loom` wrote) is refused outright, and `--accept-config` is not an escape from
  that: `loom drop <task> && loom new <task>`. **`loom drop` deliberately does
  not check the pin**: dropping runs no model, publishes nothing and removes the
  worktree, the branch and the record, so refusing to clean up because the
  config moved would strand the released paths on disk — the opposite of what
  the check is for. What the pin leaves trusted — the config as it stood at
  `loom new` or as `--accept-config` re-recorded it, your `~/.gitconfig` and the
  system config — is enumerated in `docs/KNOWN-GAPS.md` gap 6.
- **...and the REPOSITORY has a baseline too, for the roles with no task.**
  `loom plan`'s architect runs in your own checkout and `loom scout` runs in the
  shared `_scout` mirror; neither has a task record, so neither read a pin — and
  the scout's run is a *working-tree update*, which is exactly what runs a
  planted `filter.<d>.smudge`. `loom` records `$STATE_DIR/config` (+
  `config.gitconfig` beside it) over the `local` and `worktree-main` scopes and
  their include closure, wherever a task is pinned and whenever you run
  **`loom pin-config`**:

  ```sh
  loom pin-config                  # record one; or say it is current; or print
                                   # the diff and REFUSE
  loom pin-config --accept-config  # print the diff and re-record it
  ```

  `loom scout` reads it before it touches the mirror, `loom plan` before the
  architect runs, and `run_role` before every task-less launch. `loom drop` does
  not remove it — it is the repository's fact, not a task's.
- **...and that baseline never moves silently.** It is re-recorded as a *side
  effect* of pinning a task — at `loom new`, and at `land --pr` after its own
  `--set-upstream-to` — i.e. in places where loom expects to be adopting its
  **own** writes. "Expects" is not "checked", so every such re-record prints the
  `-`/`+` delta first (`loom: repository config baseline moved:`), and where the
  delta **adds** a key that names a program git runs it is refused instead:
  `loom new` cannot weigh it (it takes no `--accept-config`, being the command
  that pins), so it names the key, points at `loom pin-config --accept-config`
  and unwinds the half-built task; `land --pr` refuses the re-pin *after* the
  push and says so — the branch is on origin, the baseline is not moved, and
  the next task-less role keeps refusing until you have read the lines. A
  program key *going away* is not refused: that would make "put it back" a
  refusal of its own.
- **The scout mirror is disposable.** It is shared by every task and every
  provider, so `loom scout` `git clean -xdff`s it before every reset (a
  `reset --hard` never removes an untracked file, so one run's scratch was the
  next provider's reading), and it **refuses** a mirror whose own
  worktree-scope config — `$GIT_COMMON_DIR/worktrees/_scout/config.worktree`,
  the one scope no baseline can cover — holds anything but the sparse keys git
  writes there.
- **A worktree is judged only once it is proved to be ours.** `$wt/.git` in a
  linked worktree is a one-line FILE in a directory the agent owns; rewrite it
  and every `git -C "$wt" …` afterwards reads a repository of the writer's
  choosing — its filters, its `core.hooksPath`, its refs — while a decoy built
  with the same branch name goes on answering `symbolic-ref HEAD` correctly, so
  the "is this tree on its branch" check passed it. `require_wt_is_ours` compares
  `--git-common-dir`, `--show-toplevel` and `--git-dir` against this repository
  (realpath'd on both sides) before `run`, `check`, `diff`, `land`, `rebase`,
  `loop` and `drop` touch a worktree, and before the scout mirror is used. And
  `loom drop` no longer prints `dropped` on faith: git refuses to remove a
  worktree it does not own, so the directory is asserted **gone** before the
  record and the branch are — and if anything remains, loom says what and
  exits 1.
- **`loom rebase` resolves its refs instead of looking them up.** `origin/main`
  and `main` are not ref names, they are things git *resolves*, and the order is
  `refs/<n>` > `refs/tags/<n>` > `refs/heads/<n>` > `refs/remotes/<n>`. So a
  local branch literally named `origin/main`, a `refs/origin/main`, or a **tag**
  named `main` each answer before the ref the rebase just fetched and means —
  each of them one `git update-ref` from inside a worktree, and git only prints
  `warning: refname … is ambiguous` and carries on. The upstream is now resolved
  once, to `refs/remotes/origin/<b>` or `refs/heads/<name>`, and the branch is
  read as `refs/heads/agent/<task>`.
- **The pre-commit guard reads the index git hands it.** git runs a hook with a
  **temporary** index for `git commit -a`, `git commit -- <path>`, `--only` and
  `--include`, and names it in `$GIT_INDEX_FILE`. Clearing git's environment
  (the bullet above) took that away, so `loom guard`'s `git diff --cached` read
  the standard index, found nothing staged, and exited 0 without printing
  anything — a `git commit -a` on a hand-zone path went straight through.
  `$GIT_INDEX_FILE` (with `GIT_DIR`, `GIT_WORK_TREE`, `GIT_PREFIX` and the
  author/committer identity) is snapshotted **before** either env file is
  sourced and restored **after** the unset, so git's own values survive and a
  landed `loom.env` still cannot inject them.
- **`loom ls` says when a record is unreadable.** It used to read the profile
  field with `2>/dev/null || true`, so a record loom refuses to believe — a
  duplicated field, an unknown key, a line that is not `<key>=<value>` — listed
  as an ordinary task with a blank profile column.
- **opencode's config variables never come out of the tree.** `OPENCODE_CONFIG`,
  `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_PERMISSION` and
  `OPENCODE_DISABLE_PROJECT_CONFIG` are snapshotted before `.agents/loom.env` is
  sourced and restored after, with a WARN naming any the file tried to set —
  they decide which config opencode loads, and that config carries
  `provider.<name>.options.baseURL`, which is the provider *identity* the whole
  `providers` rule rests on. A caller that exports them still wins; the file
  does not. `OPENCODE_CONFIG_CONTENT` (a whole config inline in a variable) is
  stripped from every launch outright, caller included.
- **`TMPDIR` is pinned the same way, and for the same reason.** It is the
  parent of every temp `loom` makes, and those temps are the *authoritative*
  copies on their way to the operator's state directory: the gate log fed back
  into the next attempt's prompt, the patch a reviewer is handed. One
  `TMPDIR=` line in a landed `.agents/loom.env` would move all of them into a
  directory the agent owns. So it is snapshotted **before either env file is
  sourced** — the global `~/.config/loom/env` as well as the project's
  `loom.env` — and restored after both, with a WARN if a file tried to set it.
  A caller who exports `TMPDIR` still wins, untouched.
- Independent of all of it: implementer-class roles on `claude-sub` and
  `codex-sub` get a write-capable sandbox (see "Codex as an implementer"
  below), and `loom doctor` prints the parse error when `zones.toml` is
  unreadable instead of a generic line.

**The rule is fail-closed.** Before the worktree is created, `loom` checks every
model in every chain that will run against it — implementer, reviewer, and the
auto-fix rounds of `loom loop`, fallbacks included, because a fallback fires on a
rate limit without asking anyone. One model outside `providers` and it dies,
naming the role and the override that fixes it:

```
$ loom new 0007-c --fence-profile codex
loom: fence profile 'codex' releases fenced paths into this worktree,
but the implementer chain would run 'zai-coding-plan/glm-5.3' (provider 'zai-coding-plan').
The profile allows only: claude codex
Restrict the chain for this task, e.g.:
  LOOM_MODELS_implementer="claude-sub codex-sub" loom ...
```

An unknown profile name, a `release` pattern that is not in `[fence].paths`, a
`release` that another still-fenced pattern covers, a `providers` entry with a
space or a glob character in it, a missing `providers` list — all of them die,
in every command, the way a malformed `zones.toml` already does. The scout is
never covered by a profile: its mirror is shared by every task, so it always
runs at the full fence.

**You pass the flag every time.** `--fence-profile <name>` is required by
`loom new`, `run`, `check`, `loop`, `diff`, `rebase` and `land` for a task under
a profile:

```sh
loom new    0007-c --fence-profile codex
loom run    0007-c --fence-profile codex
loom check  0007-c --fence-profile codex
loom diff   0007-c --fence-profile codex
loom rebase 0007-c --fence-profile codex
loom land   0007-c --fence-profile codex

# and, separately, when the repository's git config has changed since
# `loom new` — `--accept-config` prints the diff and re-records it:
loom run    0007-c --fence-profile codex --accept-config
```

**A profiled task's worktree lives under its own root.** `$LOOM_WORKTREES` with
`-profiled` appended — a *sibling* of the ordinary root, never a child of it.
Nothing that runs unprofiled is ever pointed at a directory that contains
released paths, and that includes the shared `_scout` mirror (which stays under
the ordinary root and always carries the full fence) and opencode's
`external_directory` grant, which is now the role's own worktree rather than
the whole root. `loom ls` and `loom drop` know both roots. A task that already
exists under one root cannot be re-created under the other: a profile is not
something you add to, or remove from, a task that exists.

`loom new` also records it — in the operator record, the same file that holds the
task's base — and `loom ls` shows it. That record is a **consistency check, not
an authorisation**. `loom new` is the only thing that ever writes it. It can
refuse a command in three ways, it grants nothing, and these three rules are
the whole of it — there is no fourth case and no exception:

| the flag you passed | the record | result |
|---|---|---|
| absent | absent | ordinary unprofiled task; nothing to check |
| absent | `codex` | **dies**: this task was created under `codex`, so pass `--fence-profile codex` |
| `audit` | `codex` | **dies**: the flag contradicts the record |
| `codex` | `codex` | the profile is active for this command |
| `codex` | absent | **dies**: a profile cannot be introduced after `loom new` — `loom drop <task> && loom new <task> --fence-profile codex` |

That last row used to have an escape: if the worktree already held exactly what
the profile releases, `loom` called that corroboration, restored the record and
ran. It is gone. A worktree is a directory the agent can write — `git
sparse-checkout disable` materialises the released paths in one command — so a
tree that "looks like" a profile is not evidence that anyone asked for it.
Re-creating the task is now an operator act, with the same weight as the flag.

`branch.agent/<task>.fenceprofile` is neither read nor written any more, and
the reason is worth stating plainly: **branch config is agent-writable state.**
It lives in the shared `.git/config`, so anything running in the worktree could
`git config branch.agent/<task>.fenceprofile codex` and, under a design that
read the profile back from there, widen its own fence for the next `loom run`.
The record moved to a file outside every repository. That is
**operator integrity, not tamper-proofing** — an unsandboxed agent can write
`$HOME`, which `docs/KNOWN-GAPS.md` § 3 already concedes — but it does remove
the class of "one git command inside the worktree rewrites the input to its own
security check". Your flag is the consent; the record only checks it.

A `Fence-profile: <name>` line in the task file is a third form, and the
weakest — it *documents* the intent of a task (an architect agent may have
written it), so `loom new` honours it only when you also pass the same name:

```markdown
Zone: assist
Fence-profile: codex        # loom new 0007-c --fence-profile codex, or it dies
```

Only the task file's header block is read, so a `Fence-profile:` line inside a
code block — the shape `loom loop` appends when it pastes a reviewer's text back
into the task file — is not a declaration.

**Enforcement comes off the disk and out of the commits, not off the record.**
Before any role runs — and before *every* fallback attempt, because attempt 1
can widen the tree and then hit a rate limit — `loom` asks the worktree which
fenced paths are actually in it (against the whole `[fence]`, never the
released subset) and refuses anything that does not line up: released paths
present that your flag does not account for, or a flag whose released paths are
nowhere on disk — a tree that was never built under that profile. It refuses
rather than quietly re-fencing, because by then the tree's own diff and
`.agents/reviews/<task>.patch` carry the content anyway.

The tree is only half the question, because a tree can be re-fenced after the
fact: materialise `core/**`, commit it, put the sparse rules back, and the
worktree looks clean while the *history* still carries it into every diff,
patch file and merge. So the branch's commits are judged too — every path in
`git diff <security base> refs/heads/agent/<task>`, mapped through the full
`[fence]` — wherever history is handed onward: `loom check` (before the patch is
written), each round of `loom loop`, `loom diff`, `loom rebase`, and `loom land` before
it merges or pushes. `loom land` additionally refuses any `[hand]` path in those
commits that the profile does not release; `--force` skips the gate, not this.

Two honest limits of a diff between two endpoints. It answers "what do these
commits, taken together, touch" — so a fenced path **added and then deleted
again on the same branch** is not in it, even though both commits are in the
history and `git log -p` shows the content. (The reconciler catches it while it
is on disk, and the *first* command to run after the add sees it in the range;
what is not covered is a branch that adds and removes it between two `loom`
commands.) And it says nothing about what the model read: content copied to a
path the fence does not name is the exfiltration class, below.

The *base* is the operator record described above, and the *endpoint* is
`refs/heads/agent/<task>` read in your checkout — resolved to a SHA **once per
command**, and used as that sha for the history check, the review patch, the
merge and the push. Neither comes from the
worktree, and neither comes from anything in `.git` — that is the same sentence
as three paragraphs up, with the one caveat the sentence cannot carry on its
own: an OID is a *name for an object*, and `refs/replace/*` in the shared
`.git` renames objects. Replacement is therefore off for every git `loom` runs,
and a replacement ref that exists at all is a refusal (above). It cost a whole
class of bypass (a `loombase`
pointed at the branch's own tip, or an `origin/main` moved there with `git
update-ref`, makes every one of those diffs empty; a detached worktree hides
the last commit from every check measured off `HEAD`). There is no second,
"nicer to read" base any more: the review patch is cut from the same range the
history check just cleared, `base..refs/heads/agent/<task>`. `loom rebase` is the
only command that moves a recorded base, and it is one of yours.

**The commit guard follows the profile — as a seatbelt.** Fenced paths are
conventionally listed under `[hand]` too (that is what blocks a *commit* to
them); under a profile the guard accepts commits to exactly the released
patterns and still blocks everything else in `[hand]` — `.agents/zones.toml`,
`.agents/gate.sh`, `.agents/loom.env`, migrations, whatever your repo lists.
The zones it applies are the **main checkout's**, even though it is running
inside the agent's worktree; only the staged files and the tree it inspects are
the worktree's. It reads the operator record for the released set
(the hook runs as you, so it can), and corroborates it against the tree first
(a record whose released paths are not in the worktree refuses the commit). It
is a pre-commit hook running in the agent's own context, where `--no-verify`
exists: a seatbelt, not a lock. Be plain about the corroboration, too — it is a
**consistency check an agent that is trying can satisfy**: making the tree
agree costs one `git sparse-checkout disable`, and an unsandboxed agent can
write `$HOME`. It catches a stale worktree and an honest mistake, and that is
all it claims. The
thing that actually decides whether released content reaches a provider is your
`--fence-profile` flag, re-checked on every command, plus `loom land`'s
inspection of the commits. The reviewer is told the same thing, so a released
path does not come back as an "unauthorized hand/fence change" REVISE.

**If Codex refuses the task, run the same profile on Anthropic.** Codex has
declined security-remediation prompts; the profile allows both providers
precisely so that is a one-line retry, not a dead end:

```sh
LOOM_MODELS_implementer=claude-sub loom run 0007-c --fence-profile codex
```

**What a profile is not.** It scopes *exposure*, it does not prevent
exfiltration: the git object store is shared with every worktree, so a
determined agent can still reach a fenced blob through git plumbing
(`ARCHITECTURE.md` § 5, caveat 1). A profile only changes which files an agent
finds in front of it, and which providers are allowed to be that agent. If your
threat model includes a model actively working around the rule, you need a
separate repository, not a profile. The gaps in the surrounding machinery that
a profile does **not** close are written down in
[`docs/KNOWN-GAPS.md`](docs/KNOWN-GAPS.md) — read it before you rely on this.
One of them (opencode's directory grant) is *widened* by profiles, and is the
reason a profiled worktree gets its own root.

`loom doctor` lists every profile, what it releases, to whom, and warns when a
role's default chain reaches a provider the profile does not allow.

#### Codex (or Claude) as an implementer

Independent of fence profiles: this applies to **every** run, with or without
one. It is described here because a profiled task is the first place
`codex-sub` is an obvious implementer rather than a reviewer.

The edit permission is granted per ROLE, never per model:

| role | codex-sub | claude-sub | opencode providers |
|---|---|---|---|
| implementer | `codex exec --sandbox workspace-write --add-dir <wt>/.agents` | `claude -p --permission-mode acceptEdits --allowedTools 'Bash(./.agents/gate.sh…)'` | no OS sandbox |
| reviewer / scout | `codex exec --sandbox read-only` | `claude -p` (no mode flag: every prompt is denied) | no OS sandbox |

Note the third column: the opencode leg has **no OS sandbox in either row** — an
opencode reviewer is held by its role prompt, the fence, and the profile's
provider rule, not by the process. Those last two now come from *your*
`.opencode/opencode.json` (`OPENCODE_CONFIG` plus
`OPENCODE_DISABLE_PROJECT_CONFIG=1`), not from the worktree's copy, which the
agent can rewrite — provider endpoints and role prompts both live in that file. Note also that neither `codex-sub` nor
`claude-sub` appears in a default implementer chain (those are GLM, DeepSeek and
Kimi), so reaching this path at all takes an explicit `LOOM_MODELS_implementer`.

Two measured details behind the table. codex's `workspace-write` keeps the
workspace's dot-directories read-only, so without `--add-dir` the implementer
cannot write its `.agents/reviews/<task>-done.md` (or a `-blocked.md`) —
`--add-dir` re-opens exactly that directory, resolved with `pwd -P` and refused
if it does not stay inside the worktree. And `claude -p` has nobody to answer a
permission prompt, so `acceptEdits` pre-approves the file edits but a Bash call
is still denied: the gate is allowlisted by name. That allowlist is a
convenience boundary, not a sandbox — `.agents/gate.sh` is a file the
implementer can edit — so widen it without ceremony when a repo needs it:

```sh
export LOOM_CLAUDE_ALLOWED_TOOLS='Bash(./.agents/gate.sh:*),Bash(cargo test:*)'
```

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

`loom diff` streams the patch **unpaged** by default: `core.pager` names a
program git runs and it lives in the shared `.git/config`, so `loom` pins it to
`cat` for every git subprocess it spawns (see `docs/KNOWN-GAPS.md` gap 6). A
pager is operator-side — point `LOOM_DIFF_CMD` at whatever you prefer, and the
patch path is appended as the last argument:

```sh
export LOOM_DIFF_CMD="less -R"        # or: delta, bat, code --wait, $EDITOR
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
cd /path/to/coding-harness && git pull
./install.sh /path/to/your/repo
cd /path/to/your/repo && loom doctor
```

Do not skip the hook rewrite. The old hook calls `aw`, and its "not on PATH"
branch exits 0 — so an un-migrated hook does not fail loudly, it silently stops
guarding hand zones. `loom doctor` reports that as a FAIL.

Two behaviour changes ride along with the rename:

- `loom diff` streams the patch to stdout instead of opening `$EDITOR -R`, and
  it does not page it (`core.pager` is pinned to `cat` — gap 6). To get a pager
  or the old behaviour: `export LOOM_DIFF_CMD="less -R"` /
  `export LOOM_DIFF_CMD="$EDITOR -R"`.
- The Neovim layer is gone. If you copied `nvim/loom.lua` or
  `nvim/codecompanion.lua` into your editor config, remove them — they call
  `aw`.
