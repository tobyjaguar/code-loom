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

## 1b. `.agents/zones.toml` — five paths (six patterns) that belong in `[hand]`

Check that `[hand].paths` in the consuming repo lists the control plane itself,
and add what is missing:

```toml
  ".agents/gate.sh",
  ".agents/zones.toml",
  ".agents/loom.env",
  ".opencode/**",
  ".gitattributes",
  "**/.gitattributes",
```

An agent may **propose** a change to any of them — that is what the hand
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
* `.opencode/**` is the provider **identity** and every role prompt.
  `provider.<name>.options.baseURL` in `opencode.json` decides which host
  answers as `deepseek` — the fact this profile's `providers` list is built on
  — and the agent definitions there supply each role's system prompt. `loom`
  points every opencode run at the **main checkout's** copy and turns the
  worktree's own project config off, so a rewritten worktree copy is inert
  *while the task runs*; a landed one is the copy every later task uses.

* `.gitattributes` (the repo root's, and every nested one — git reads a
  `.gitattributes` in any directory) is the **file half** of filter- and
  merge-driver execution. The driver itself lives in `.git/config`, which
  `loom` now pins to the task: a change to the repository's git config — all
  three scopes and the include closure — is refused, and `--accept-config` is
  the one escape. (The repository also carries a baseline of its own for the
  roles that have no task, `loom plan` and `loom scout`; `loom pin-config`
  records it.) The *attribute* that selects
  a driver for a path lives in the tree, where an agent writes it — `filter=x`
  on one path, plus a `filter.x.clean` anywhere in the config chain (your
  `~/.gitconfig` included), is a program git runs on checkout, `git add` and
  commit. A landed `.gitattributes` is the copy every later task checks out
  under.

`loom land` checks the branch's commits against `[hand]` regardless of what the
guard did, so this is the entry that actually holds. None of `.agents/gate.sh`,
`.agents/zones.toml` or `.opencode/**` may be put in `[fence]` either — `loom`
refuses a fence pattern covering them, because a worktree (or a harness)
without them disarms the checks that judge the agent.

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
# and the git config is pinned too — plant a key and it must refuse, naming it
# AND the scope it appeared in, before any model, fetch, push or merge:
git config filter.probe.clean /bin/true
loom check <some-task> --fence-profile codex      # must die: "+ filter.probe.clean="
loom check <some-task> --fence-profile codex --accept-config   # must proceed
git config --unset filter.probe.clean
loom check <some-task> --fence-profile codex --accept-config   # re-pin the removal

# ... and the same at WORKTREE scope, which `git config --local --list` does
# not show at all:
git -C <worktree> config --worktree core.hooksPath /tmp/probe
loom check <some-task> --fence-profile codex      # must die: "[worktree-task]"
git -C <worktree> config --worktree --unset core.hooksPath

loom check <other-unprofiled-task> --fence-profile codex
                                                # must die: a profile cannot be
                                                # introduced after `loom new`

# and the record is not a key, in either direction:
rm "${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/"*"/tasks/<some-task>"
loom check <some-task> --fence-profile codex      # must STILL die, telling you to
                                                # loom drop && loom new the task

# --- the two `loom scout` refusals -----------------------------------------
# `loom scout` has no task, so it is judged against the REPOSITORY baseline —
# and its mirror is a working-tree update, which is what runs a planted smudge.
git config filter.probe.smudge /bin/true
loom scout "anything"                             # must die: "+ filter.probe.smudge="
                                                # and name `loom pin-config --accept-config`
git config --unset filter.probe.smudge
loom pin-config --accept-config                   # re-record the removal

# ... and the mirror's OWN worktree scope, which no baseline can cover:
git -C "$(dirname "$PWD")/.loom-worktrees/$(basename "$PWD")/_scout" \
    config --worktree core.hooksPath /tmp/probe   # adjust for your LOOM_WORKTREES
loom scout "anything"                             # must die naming the key AND the
                                                # config.worktree file it lives in
git -C .../_scout config --worktree --unset core.hooksPath

# --- the worktree is proved to be OURS before anything reads it ------------
# `<worktree>/.git` is a one-line FILE the agent owns. Rewrite it and every
# `git -C <worktree> …` afterwards reads a repository of the writer's choosing
# — and a decoy with the same branch name answers the branch question
# correctly, so "is this tree on its branch" is not the check that catches it.
cp <worktree>/.git /tmp/gitfile.bak
echo "gitdir: /tmp/not-this-repo/.git/worktrees/x" > <worktree>/.git
loom check <some-task> --fence-profile codex      # must die: "does not belong to
                                                # this repository", naming the path
loom drop  <some-task>                            # must ALSO die, and must NOT say
                                                # "dropped" over a directory that is
                                                # still there
cp /tmp/gitfile.bak <worktree>/.git               # and now the drop goes through

# --- loom's own writes into the worktree are resolved, not spelled out -----
# `.agents/reviews` is where the review PATCH is written, and the patch carries
# the content of every path in the diff — released paths included.
rm -rf <worktree>/.agents/reviews
ln -s /tmp/elsewhere <worktree>/.agents/reviews
loom check <some-task> --fence-profile codex      # must die naming /tmp/elsewhere
loom land  <some-task> --fence-profile codex      # must die: dirty worktree
rm -f <worktree>/.agents/reviews                  # (the same must hold with
                                                # `.agents` itself symlinked)

# --- ... and one level down, at the FILE ----------------------------------
# `>` follows a symlink at the leaf, and a HARD link is the same redirect with
# nothing to see in `ls -l`. loom writes a fresh temp inside the resolved
# directory and RENAMES it onto the target, so the entry is replaced and the
# far end of the link never sees a byte.
ln -s /tmp/elsewhere/stolen.patch <worktree>/.agents/reviews/<some-task>.patch
loom check <some-task> --fence-profile codex      # goes through
ls /tmp/elsewhere/stolen.patch                    # must NOT exist
ls -l <worktree>/.agents/reviews/<some-task>.patch  # a plain file, 1 link

printf 'mine\n' > /tmp/elsewhere/hard.txt
ln /tmp/elsewhere/hard.txt <worktree>/.agents/reviews/<some-task>.patch
loom check <some-task> --fence-profile codex      # goes through
cat /tmp/elsewhere/hard.txt                       # must still say "mine"

# A link INSIDE the review directory is not loom's scratch either, so the
# dirty-worktree exclusion is dropped and landing refuses.
ln -s /tmp/elsewhere <worktree>/.agents/reviews/note.txt
loom land <some-task> --fence-profile codex       # must die: dirty worktree
rm -f <worktree>/.agents/reviews/note.txt

# And the file loom READS back is refused rather than believed.
ln -s /tmp/elsewhere/blocked.md <worktree>/.agents/reviews/<some-task>-blocked.md
loom run <some-task> --fence-profile codex        # must die naming the symlink,
                                                # never "implementer reported
                                                # blocked"

# A COMMITTED symlink out of the tree is the other class, and it is judged by
# what THIS BRANCH added. A chain counts: each hop can look "inside" on its own.
( cd <worktree> && mkdir -p d1/d2 && ln -s ../.. d1/d2/l1 \
  && ln -s ../d1/d2/l1/../../<your repo dir>/core backend/loot \
  && git add -A && git commit -m "chain" )
loom check <some-task>                            # must die naming backend/loot
                                                # AND where it resolves to
```

**If your trunk already carries one.** `ln -s /etc/hostname backend/hostname`
committed on `main` before any of this is not your branch's doing, and loom will
not refuse your whole repository over it: `loom new` and `loom attach` print one
WARN, `loom doctor` a warn line, and the exact path is excluded from every
worktree loom builds (added to the sparse rules, released by no profile,
verified absent). It is a **residual, not a fix** — the link is still in your
trunk and in every clone of it, and anything that is not loom reads straight
through it. Remove it. To check what you have:

```bash
git ls-files -s | awk '$1 == "120000"'            # every tracked symlink
loom doctor | grep 'trunk symlink'                # the ones that leave the tree
```

**Where the artifacts loom acts on actually live.** The patch, the review and
the gate log are written to the operator's own state directory first —
`${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/<key>/tasks/<task>.artifacts/`,
mode 0700/0600, removed by `loom drop` with the record — and only then *placed*
into `.agents/reviews/` in the worktree, where they are a courtesy for the
agent (0600 there too — `place_file` renames a `mktemp` into place, and that is
mktemp's mode). `loom loop` reads its VERDICT, and the REVISE text it appends to the
task spec, from the operator's copy; `loom land` reads `reviewed` from the
operator's record. Nothing loom decides is read back out of the tree it is
deciding about.

The record is a file you own, not a git object: `loom new` writes it, `loom check`
stamps its `reviewed`, `loom rebase` re-points its `base`, `loom drop` deletes it
(with or without `--keep-branch`), and `loom ls` shows the profile it names. It is
one field per line, each field once, every key from a fixed list and no control
character in any value — `loom` refuses a record of any other shape rather than
reading the first line that matches, because `origin`, `fetch`, `pushurl` and
`config` all come out of `.git/config`, where a value may contain a newline.
A task created by an older `loom` has no record at all, so
`loom check|diff|loop|rebase|land` on it refuses with "no operator record for
task X"; one created by a `loom` from before the config pin has a record with no
`config=` and is refused with "pins no git config". `loom drop X && loom new X`
is the fix for both, and there is no migration to run beyond that.

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
  path, `loom rebase` refuses; `--accept-upstream` is the operator's "I have
  read those and I accept them under the base". Either way the range is printed
  whenever the base moves — the `git log --oneline` and the fenced/hand path
  lists — so the consent is an informed one.
* **The repository's git config is pinned to the task — all of it.**
  `.git/config` is in the shared git directory, so `git -C <worktree> config
  <anything> <anything>` is one command from inside an agent's tree — and the
  keys that matter cannot be listed in advance (`filter.<anything>.clean`,
  `pager.<anything>`, `includeIf.<anything>` put the attack in the key name),
  while `credential.helper` and `core.askPass` are handed your credential as
  well as being run. "All of it" is **three scopes and an include closure**,
  because `git config --local --list` is not what git reads:
  `.git/config` (`local`), `.git/config.worktree` (`worktree-main`, the main
  checkout's own scope — a `core.hooksPath` there runs your hooks during
  `loom land`'s merge), `.git/worktrees/<wt>/config.worktree` (`worktree-task`,
  one `git config --worktree` from inside the agent's tree), and every file an
  `include.path`/`includeIf` in any of them pulls in, digested by its bytes.
  `loom new` records a digest of the lot, plus the list itself beside the record
  as `<task>.gitconfig` (each entry tagged with its scope), and every command
  recomputes it **before its first fence operation** and again before it runs a
  model, fetches, pushes, merges, replays or writes a review patch. A change
  prints a `-`/`+` diff — naming the scope — and refuses.
  **`--accept-config`** is the one escape and re-records the config as the new
  baseline. Practical consequences for a consuming repo:
  - an agent that runs `git config user.name` in its worktree trips it, and so
    does `git config --worktree <anything>`. That is intended — it is the same
    command as `git config credential.helper '!sh -c …'` — and
    `loom <cmd> <task> --accept-config` is the one-word answer once you have
    read the diff;
  - so does your own `git remote add`, `git config pull.rebase true`, or any
    other config edit you make while a task is open — **including an edit to a
    file your `.git/config` includes**, which is the case that surprises people;
  - `loom new` prints `loom: pinned N local + M worktree config entries`, and
    WARNs, naming the targets, if your config pulls other files in. It
    **refuses** `--accept-config`: it is the command that pins;
  - `loom drop` deliberately does not check the pin — it runs no model and
    publishes nothing, and a repo you cannot clean up is worse than one whose
    config moved;
  - a task created by a `loom` from before the pin has no `config=` field and is
    refused with no escape: `loom drop <task> && loom new <task>`;
  - `loom` writes config on your behalf in exactly two places, and both re-pin
    themselves: the first `git sparse-checkout init` in a repository (which adds
    `extensions.worktreeConfig` locally and `core.sparseCheckout` at worktree
    scope), and `loom land --pr`'s `--set-upstream-to`;
  - those two re-pins also re-record the **repository** baseline, and they now
    print the `-`/`+` delta rather than doing it quietly
    (`loom: repository config baseline moved:`). If the delta **adds** a key
    that names a program git runs, `loom new` refuses outright (it takes no
    `--accept-config`) and tells you to run `loom pin-config --accept-config`
    first; `land --pr` refuses the re-pin *after* the push and says so. In a
    consuming repo the common way to meet this is your own `git config` edit
    landing between two loom commands — read the diff, then
    `loom pin-config --accept-config`;
  - the WARN block that names programs also names the keys **inside** a file
    your config includes, tagged `[include:<path>]`, and an included file's
    bytes are pinned up to 64 KiB (past that: digest and size only).
* **The remote is pinned to the task: the URL *and* `remote.origin.fetch`.**
  Both are recorded at `loom new` and refused when changed. The refspec matters
  because it decides which local ref a fetch updates at all — pointed at
  `refs/remotes/decoy/*` it leaves a forged `refs/remotes/origin/main` standing
  through a fetch that looks like it worked. `loom rebase` also names the
  refspec itself (`+refs/heads/<b>:refs/remotes/origin/<b>`) rather than
  trusting the config.
* **`loom check` stamps the tip it reviewed, and `loom land` refuses any other.**
  A commit added after the reviewer read the patch does not ride the review
  into the merge — re-run `loom check`. Landing also refuses a worktree with
  uncommitted changes (`.agents/reviews/` excepted, which is where `loom` writes
  the patch itself — gitignore that directory). That exception holds only while
  that directory is loom's own scratch: neither it nor `.agents` a symlink, the
  directory physically inside the worktree, and every entry in it a plain file
  with one name. And because you gitignored it, the check is two steps:
  `git status --porcelain --untracked-files=normal -- .` with the
  `:(exclude).agents/reviews` pathspec — dropped the moment that condition fails
  — and then, only when it was dropped, `git status --porcelain
  --untracked-files=normal --ignored=matching -- .agents/reviews`, whose `!!`
  lines are appended. A link planted inside an ignored directory is an ignored
  path that step one cannot see; step two is what makes landing refuse it. Both
  are a tripwire — `place_file` (write) and `probe_agent_file` (read) close the
  paths themselves, whatever your `.gitignore` says.
  * git names the offending ENTRY only when a tracked file inside that directory
    makes it descend. In exactly the shape this page asks you for — the
    directory gitignored, nothing tracked inside — `--ignored=matching`
    collapses to the single line `!! .agents/reviews/` (measured, git 2.34.1).
    Landing still refuses; `loom` appends the entry it refused on itself, as
    `!! .agents/reviews/<name>  (not loom's plain scratch: <why>)`.
  * An `.agents` or `.agents/reviews` `loom` cannot read and search is a
    **refusal**, not a clean tree: at mode `0300` a shell glob over it matches
    nothing and `git status` only warns on stderr and exits 0. `loom` refuses on
    the mode, and refuses on any `git status` stderr at all — so an unreadable
    directory anywhere in your worktree stops a landing rather than hiding
    inside one. `status.showUntrackedFiles=normal` and `core.untrackedCache=false`
    are pinned in `GIT_CONFIG_PARAMETERS` for the same reason: a
    `status.showUntrackedFiles=no` (in `--global`, which the config pin does not
    read) blinded step one and made step two exit 128.

```sh
# the record for a task, if you ever want to read one:
cat "${XDG_CONFIG_HOME:-$HOME/.config}/loom/repos/"*"/tasks/<some-task>"
#   base=<commit>  profile=<name>  branch=agent/<task>  created=<iso>
#   reviewed=<tip loom check last reviewed>
#   origin=<remote.origin.url at loom new>
#   fetch=<remote.origin.fetch at loom new, each value length-prefixed:
#          "<len>:<refspec>", space-joined, because a plain space join of a
#          multi-valued setting is not reversible>
#   pushurl=<`git remote get-url --push origin` at loom new — where a push
#            actually goes, which remote.origin.pushurl and a
#            url.<x>.pushInsteadOf rewrite both move without touching `origin`>
#   config=<sha256, sorted, of the whole git config: the `local` scope, the
#           `worktree-main` scope (.git/config.worktree), the `worktree-task`
#           scope (.git/worktrees/<wt>/config.worktree), and one
#           include:<path>:<sha256> record per file the include directives in
#           any of them pull in. The list itself is in the file beside this
#           one, <task>.gitconfig, with each entry tagged by scope>
```

Then read [`docs/KNOWN-GAPS.md`](KNOWN-GAPS.md) in the harness repo, in full:
it is the list of what a profile does **not** close, and it is kept current
there rather than summarised here. None of it is fixed by this snippet.
