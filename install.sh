#!/usr/bin/env bash
# Install the Loom harness into a target repository.
#
#   ./install.sh /path/to/repo [--copy-bin]
#
# Env: LOOM_BIN=<dir>   where the symlinks go   (default ~/.local/bin)
#      LOOM_ENV=<file>  provider key file       (default ~/.config/loom/env)
#
# Copies the contract layer (.agents/) and agent config (.opencode/) into the
# target repo, puts `loom` and `loom-session` on your PATH (symlinked by default,
# so harness updates propagate; --copy-bin to copy instead), and installs the
# hand-zone pre-commit hook. Never clobbers files you may have edited:
# zones.toml, AGENTS.md, opencode.json are skipped if they already exist —
# and an existing pre-commit hook is moved to .git/hooks/pre-commit.pre-loom
# and chained (the guard runs first, then your hook). Re-running is a no-op.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TARGET="${1:?usage: ./install.sh /path/to/repo [--copy-bin]}"
COPY_BIN="${2:-}"
BIN_DIR="${LOOM_BIN:-$HOME/.local/bin}"

[ -d "$TARGET/.git" ] || { echo "install: $TARGET is not a git repository" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd -P)"

put() { # put <src> <dst> <mode: clobber|keep>
  local src="$1" dst="$2" mode="$3"
  if [ -e "$dst" ] && [ "$mode" = keep ]; then
    echo "  keep   ${dst#$TARGET/} (exists, not overwritten)"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  install ${dst#$TARGET/}"
  fi
}

echo "installing contract layer into $TARGET"
for d in plans tasks decisions reviews; do mkdir -p "$TARGET/.agents/$d"; done
put "$HERE/.agents/gate.sh"          "$TARGET/.agents/gate.sh"          keep
chmod +x "$TARGET/.agents/gate.sh"
put "$HERE/.agents/zones.toml"       "$TARGET/.agents/zones.toml"       keep
put "$HERE/.agents/PLAN_TEMPLATE.md" "$TARGET/.agents/PLAN_TEMPLATE.md" clobber
put "$HERE/.agents/TASK_TEMPLATE.md" "$TARGET/.agents/TASK_TEMPLATE.md" clobber
put "$HERE/AGENTS.md"                "$TARGET/AGENTS.md"                keep

echo "installing agent config"
put "$HERE/.opencode/opencode.json"  "$TARGET/.opencode/opencode.json"  keep
for f in "$HERE"/.opencode/prompts/*.md; do
  put "$f" "$TARGET/.opencode/prompts/$(basename "$f")" clobber
done

put "$HERE/vscode/tasks.json"      "$TARGET/.vscode/tasks.json"       keep

echo "installing bin → $BIN_DIR"
mkdir -p "$BIN_DIR"
for b in loom loom-session; do
  if [ "$COPY_BIN" = "--copy-bin" ]; then cp "$HERE/bin/$b" "$BIN_DIR/$b"; chmod +x "$BIN_DIR/$b"
  else ln -sf "$HERE/bin/$b" "$BIN_DIR/$b"; fi
  echo "  $BIN_DIR/$b"
done
# The dispatcher used to be called `aw`. Clean up what a previous install of
# THIS harness left on that name, and nothing else:
#   - a symlink into this checkout (the default install);
#   - a dangling symlink to some checkout's bin/aw (the checkout moved since)
#     — already broken, so removing it destroys nothing;
#   - a --copy-bin copy, recognised by the old dispatcher's own header line.
# Anything else on that name is somebody else's program: reported, kept.
old_aw="$BIN_DIR/aw"; old_target=""
[ -L "$old_aw" ] && old_target="$(readlink "$old_aw")"
if [ -L "$old_aw" ] && [ "$old_target" = "$HERE/bin/aw" ]; then
  rm -f "$old_aw"; echo "  removed stale $old_aw (renamed to loom)"
elif [ -L "$old_aw" ] && [ ! -e "$old_aw" ] && case "$old_target" in */bin/aw) true ;; *) false ;; esac; then
  rm -f "$old_aw"; echo "  removed dangling $old_aw -> $old_target (renamed to loom)"
elif [ -f "$old_aw" ] && grep -qsF '# aw — agent worktree dispatcher (Loom)' "$old_aw"; then
  rm -f "$old_aw"; echo "  removed stale $old_aw (--copy-bin of the pre-rename dispatcher)"
elif [ -e "$old_aw" ] || [ -L "$old_aw" ]; then
  echo "  NOTE: $old_aw exists but is not this harness's — left alone (remove it yourself if it is the old dispatcher)"
fi
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "  NOTE: $BIN_DIR is not on your PATH" ;; esac

LOOM_ENV="${LOOM_ENV:-$HOME/.config/loom/env}"
if [ ! -f "$LOOM_ENV" ]; then
  mkdir -p "$(dirname "$LOOM_ENV")"
  umask 177
  cat > "$LOOM_ENV" << 'ENVEOF'
# Loom provider keys — sourced automatically by `loom`. KEY=value lines.
# Lives outside every repo on purpose. Keep it chmod 600.
ZHIPU_API_KEY=PASTE-YOUR-GLM-CODING-PLAN-KEY-HERE
# DEEPSEEK_API_KEY=
# MOONSHOT_API_KEY=
ENVEOF
  umask 022
  echo "  created $LOOM_ENV (add your keys)"
fi

echo "installing pre-commit hook (chaining any existing one)"
( cd "$TARGET" && "$BIN_DIR/loom" install-hooks )

# Keep-mode files are never overwritten (you may have edited them), so a
# pre-rename copy still says `aw`. Say so rather than leave a VS Code task or
# an AGENTS.md instruction pointing at a command that is gone.
stale=""
for f in .vscode/tasks.json AGENTS.md .opencode/opencode.json .agents/zones.toml; do
  if [ -f "$TARGET/$f" ] && grep -qw aw "$TARGET/$f"; then stale="$stale $f"; fi
done
if [ -n "$stale" ]; then
  echo "  NOTE: kept files still say 'aw' (now 'loom') — edit by hand:$stale"
fi

cat << DONE

Done. Next steps in $TARGET:
  1. \$EDITOR .agents/zones.toml      # five minutes, do it honestly
  2. \$EDITOR AGENTS.md               # fill in the repo facts, keep it <100 lines
  3. \$EDITOR ~/.config/loom/env      # paste ZHIPU_API_KEY (GLM Coding Plan);
                                     # loom sources this file automatically
  4. loom doctor                     # verifies binaries, keys, and model IDs
  5. loom plan "something small"     # one end-to-end feature before trusting it
DONE
