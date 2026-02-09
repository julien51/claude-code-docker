#!/bin/sh
set -e

# ABOUTME: Docker entrypoint that sets up session config, then drops
# ABOUTME: to non-root 'claude' user before launching the CLI.

CLAUDE_HOME=/home/claude

# Initialize home dir on first boot of this session volume.
# /shared-config/ is a read-only bind mount with shared config files.
# /root-template/ has defaults baked into the image.

if [ ! -f "$CLAUDE_HOME/.initialized" ]; then
  echo "[INIT] Setting up session home directory..." >&2

  # 1. Copy shared config if the bind mount exists
  if [ -d /shared-config ]; then
    # .gitconfig
    if [ -f /shared-config/.gitconfig ]; then
      cp /shared-config/.gitconfig "$CLAUDE_HOME/.gitconfig"
    fi

    # .claude.json (account/settings seed)
    if [ -f /shared-config/.claude.json ]; then
      cp /shared-config/.claude.json "$CLAUDE_HOME/.claude.json"
    fi

    # .claude credentials
    if [ -f /shared-config/.claude/.credentials.json ]; then
      mkdir -p "$CLAUDE_HOME/.claude"
      cp /shared-config/.claude/.credentials.json "$CLAUDE_HOME/.claude/.credentials.json"
    fi

    # .claude CLAUDE.md
    if [ -f /shared-config/.claude/CLAUDE.md ]; then
      mkdir -p "$CLAUDE_HOME/.claude"
      cp /shared-config/.claude/CLAUDE.md "$CLAUDE_HOME/.claude/CLAUDE.md"
    fi

    # .claude settings.json
    if [ -f /shared-config/.claude/settings.json ]; then
      mkdir -p "$CLAUDE_HOME/.claude"
      cp /shared-config/.claude/settings.json "$CLAUDE_HOME/.claude/settings.json"
    fi

    # .claude projects (settings, not session data)
    if [ -d /shared-config/.claude/projects ]; then
      mkdir -p "$CLAUDE_HOME/.claude/projects"
      cp -r /shared-config/.claude/projects/. "$CLAUDE_HOME/.claude/projects/"
    fi

    # .claude plugins
    if [ -d /shared-config/.claude/plugins ]; then
      mkdir -p "$CLAUDE_HOME/.claude/plugins"
      cp -r /shared-config/.claude/plugins/. "$CLAUDE_HOME/.claude/plugins/"
    fi

    echo "[INIT] Copied shared config into session." >&2
  fi

  # 2. Fall back to /root-template/ for anything still missing
  if [ ! -f "$CLAUDE_HOME/.gitconfig" ]; then
    cp /root-template/.gitconfig "$CLAUDE_HOME/.gitconfig"
    echo "[INIT] Used template for .gitconfig." >&2
  fi

  # 3. Mark session as initialized
  touch "$CLAUDE_HOME/.initialized"
  echo "[INIT] Session initialized." >&2
fi

# Add all /workspace subdirectories as git safe directories
# (write to the claude user's gitconfig)
for dir in /workspace/*/; do
  if [ -d "$dir" ]; then
    dir="${dir%/}"
    git config --file "$CLAUDE_HOME/.gitconfig" --add safe.directory "$dir"
  fi
done
git config --file "$CLAUDE_HOME/.gitconfig" --add safe.directory /workspace

# Sync shared config files on every boot (credentials, CLAUDE.md, settings)
if [ -d /shared-config/.claude ]; then
  mkdir -p "$CLAUDE_HOME/.claude"
  cp /shared-config/.claude/.credentials.json "$CLAUDE_HOME/.claude/.credentials.json" 2>/dev/null || true
  cp /shared-config/.claude/CLAUDE.md "$CLAUDE_HOME/.claude/CLAUDE.md" 2>/dev/null || true
  cp /shared-config/.claude/settings.json "$CLAUDE_HOME/.claude/settings.json" 2>/dev/null || true
  echo "[INIT] Synced credentials, CLAUDE.md and settings.json from shared config." >&2
fi

# Fetch skills from dotfiles repo (always get latest)
echo "[INIT] Fetching skills from dotfiles..." >&2
DOTFILES_DIR="/tmp/dotfiles"
if [ -d "$DOTFILES_DIR" ]; then
  git -C "$DOTFILES_DIR" pull --ff-only 2>/dev/null || true
else
  git clone --depth 1 https://github.com/julien51/dotfiles.git "$DOTFILES_DIR" 2>/dev/null || true
fi
if [ -d "$DOTFILES_DIR/.claude/skills" ]; then
  mkdir -p "$CLAUDE_HOME/.claude"
  rm -rf "$CLAUDE_HOME/.claude/skills"
  cp -r "$DOTFILES_DIR/.claude/skills" "$CLAUDE_HOME/.claude/skills"
  echo "[INIT] Skills installed from dotfiles." >&2
fi

# Authenticate gh with token if provided
if [ -n "$GITHUB_TOKEN" ]; then
  echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
fi

# Fix ownership of the home directory for the claude user
chown -R claude:claude "$CLAUDE_HOME"
# Fix workspace git config and top-level ownership (avoid deep recursive chown)
chown claude:claude /workspace 2>/dev/null || true
for dir in /workspace/*/; do
  if [ -d "$dir/.git" ]; then
    chown -R claude:claude "$dir/.git/config" 2>/dev/null || true
  fi
done

# Drop privileges and exec as the claude user
exec gosu claude "$@"
