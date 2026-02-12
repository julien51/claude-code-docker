#!/bin/sh
set -e

# ABOUTME: Docker entrypoint for interactive sessions. Sources shared init,
# ABOUTME: then drops to non-root 'claude' user before launching the CLI.

CLAUDE_HOME=/home/claude

# Run shared init (config copy, safe dirs, skills, gh auth, ownership)
. /common-init.sh

# Run as claude user
exec gosu claude "$@"
