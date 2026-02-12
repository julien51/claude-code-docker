#!/bin/sh
# ABOUTME: Shared init logic sourced by both entrypoint.sh and entrypoint-task.sh.
# ABOUTME: Handles config copy, git safe dirs, gh auth, skills install, and ownership.

# Expects CLAUDE_HOME to be set by the caller.

# ── First-boot setup ────────────────────────────────────────────
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

# ── Every-boot setup ────────────────────────────────────────────

# Sync CLAUDE.md, settings.json, and credentials from shared-config.
# Credentials are synced every boot because claude-start always pushes the
# freshest host credentials into shared-config before starting the container.
if [ -d /shared-config/.claude ]; then
  mkdir -p "$CLAUDE_HOME/.claude"
  cp /shared-config/.claude/CLAUDE.md "$CLAUDE_HOME/.claude/CLAUDE.md" 2>/dev/null || true
  cp /shared-config/.claude/settings.json "$CLAUDE_HOME/.claude/settings.json" 2>/dev/null || true
  cp /shared-config/.claude/.credentials.json "$CLAUDE_HOME/.claude/.credentials.json" 2>/dev/null || true
  echo "[INIT] Synced CLAUDE.md, settings.json, and credentials from shared config." >&2
fi

# Add all /workspace subdirectories as git safe directories
for dir in /workspace/*/; do
  if [ -d "$dir" ]; then
    dir="${dir%/}"
    git config --file "$CLAUDE_HOME/.gitconfig" --add safe.directory "$dir"
  fi
done
git config --file "$CLAUDE_HOME/.gitconfig" --add safe.directory /workspace

# Install skills from baked-in template
if [ -d /skills-template ]; then
  mkdir -p "$CLAUDE_HOME/.claude"
  rm -rf "$CLAUDE_HOME/.claude/skills"
  cp -r /skills-template "$CLAUDE_HOME/.claude/skills"
  echo "[INIT] Skills installed from image." >&2
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
