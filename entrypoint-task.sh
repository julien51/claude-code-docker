#!/bin/sh
set -e

# ABOUTME: Headless task entrypoint for autonomous Claude agents.
# ABOUTME: Clones a repo, runs a task, opens a PR, and monitors CI/reviews.

CLAUDE_HOME=/home/claude
WORK_DIR=/work
LOG_FILE="/logs/${AGENT_NAME:-agent}.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

# Ensure log directory exists
mkdir -p /logs

log "=== Claude Agent Starting ==="
log "TASK_REPO=$TASK_REPO"
log "TASK_ISSUE=$TASK_ISSUE"
log "TASK_PROMPT=$TASK_PROMPT"

# ── Validate inputs ──────────────────────────────────────────────
[ -z "$TASK_REPO" ] && die "TASK_REPO is required"
[ -z "$TASK_ISSUE" ] && [ -z "$TASK_PROMPT" ] && die "TASK_ISSUE or TASK_PROMPT is required"
[ -z "$ANTHROPIC_API_KEY" ] && die "ANTHROPIC_API_KEY is required"
[ -z "$GITHUB_TOKEN" ] && die "GITHUB_TOKEN is required"

# ── Setup (mirrors entrypoint.sh init) ───────────────────────────
if [ ! -f "$CLAUDE_HOME/.initialized" ]; then
  log "Setting up home directory..."

  if [ -d /shared-config ]; then
    [ -f /shared-config/.gitconfig ] && cp /shared-config/.gitconfig "$CLAUDE_HOME/.gitconfig"
    [ -f /shared-config/.claude.json ] && cp /shared-config/.claude.json "$CLAUDE_HOME/.claude.json"

    if [ -d /shared-config/.claude ]; then
      mkdir -p "$CLAUDE_HOME/.claude"
      cp /shared-config/.claude/.credentials.json "$CLAUDE_HOME/.claude/.credentials.json" 2>/dev/null || true
      cp /shared-config/.claude/CLAUDE.md "$CLAUDE_HOME/.claude/CLAUDE.md" 2>/dev/null || true
      cp /shared-config/.claude/settings.json "$CLAUDE_HOME/.claude/settings.json" 2>/dev/null || true
    fi

    if [ -d /shared-config/.claude/projects ]; then
      mkdir -p "$CLAUDE_HOME/.claude/projects"
      cp -r /shared-config/.claude/projects/. "$CLAUDE_HOME/.claude/projects/"
    fi
  fi

  if [ ! -f "$CLAUDE_HOME/.gitconfig" ] && [ -f /root-template/.gitconfig ]; then
    cp /root-template/.gitconfig "$CLAUDE_HOME/.gitconfig"
  fi

  touch "$CLAUDE_HOME/.initialized"
  log "Home directory initialized."
fi

# Authenticate gh
echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true

# Fetch skills from dotfiles
log "Fetching skills from dotfiles..."
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
  log "Skills installed."
fi

# ── Clone repo ───────────────────────────────────────────────────
REPO_NAME=$(echo "$TASK_REPO" | cut -d'/' -f2)
REPO_DIR="$WORK_DIR/$REPO_NAME"
mkdir -p "$WORK_DIR"

log "Cloning $TASK_REPO..."
git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${TASK_REPO}.git" "$REPO_DIR" 2>&1 | tee -a "$LOG_FILE"
cd "$REPO_DIR"

# Mark as safe directory
git config --global --add safe.directory "$REPO_DIR"

# ── Determine branch name and prompt ─────────────────────────────
BRANCH_PREFIX="${BRANCH_PREFIX:-claude}"

if [ -n "$TASK_ISSUE" ]; then
  log "Fetching issue #$TASK_ISSUE..."
  ISSUE_JSON=$(gh issue view "$TASK_ISSUE" -R "$TASK_REPO" --json title,body,labels)
  ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
  ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body')

  # Slugify title for branch name
  SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
  TASK_BRANCH="${BRANCH_PREFIX}/${TASK_ISSUE}-${SLUG}"

  # Build prompt from issue
  PROMPT="GitHub Issue #${TASK_ISSUE}: ${ISSUE_TITLE}

${ISSUE_BODY}

Instructions:
- Implement the changes described in this issue.
- Write tests for any new functionality.
- Make focused, minimal changes.
- Commit your work with clear commit messages."
else
  # Direct prompt mode
  TASK_BRANCH="${BRANCH_PREFIX}/task-$(date +%Y%m%d-%H%M%S)"
  PROMPT="$TASK_PROMPT"
fi

# Override branch if explicitly set
[ -n "$TASK_BRANCH_OVERRIDE" ] && TASK_BRANCH="$TASK_BRANCH_OVERRIDE"

log "Creating branch: $TASK_BRANCH"
git checkout -b "$TASK_BRANCH"

# ── Signal start on GitHub issue ─────────────────────────────────
if [ -n "$TASK_ISSUE" ]; then
  gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
    --body "🤖 Claude agent started working on this." 2>/dev/null || true

  # Swap labels: remove trigger label, add in-progress
  gh issue edit "$TASK_ISSUE" -R "$TASK_REPO" \
    --remove-label "${TASK_LABEL:-claude}" \
    --add-label "claude-in-progress" 2>/dev/null || true
fi

# ── Fix ownership and run Claude as non-root ─────────────────────
chown -R claude:claude "$CLAUDE_HOME"
chown -R claude:claude "$WORK_DIR"

log "Running Claude on task..."
CLAUDE_CMD="node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"

gosu claude $CLAUDE_CMD -p "$PROMPT" --dangerously-skip-permissions 2>&1 | tee -a "$LOG_FILE"
CLAUDE_EXIT=$?
log "Claude exited with code $CLAUDE_EXIT"

# ── Check for changes and open PR ────────────────────────────────
if git diff --quiet HEAD && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  log "No changes produced. Exiting."
  if [ -n "$TASK_ISSUE" ]; then
    gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
      --body "🤖 Agent finished but produced no changes." 2>/dev/null || true
    gh issue edit "$TASK_ISSUE" -R "$TASK_REPO" \
      --remove-label "claude-in-progress" \
      --add-label "${TASK_LABEL:-claude}" 2>/dev/null || true
  fi
  exit 0
fi

# Stage and commit any uncommitted changes
if ! git diff --quiet HEAD || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  git add -A
  git commit -m "wip: uncommitted agent changes" 2>/dev/null || true
fi

log "Pushing branch $TASK_BRANCH..."
git push -u origin "$TASK_BRANCH" 2>&1 | tee -a "$LOG_FILE"

# Build PR title and body
if [ -n "$TASK_ISSUE" ]; then
  PR_TITLE="$ISSUE_TITLE"
  PR_BODY="Closes #${TASK_ISSUE}

🤖 This PR was generated by a Claude agent.

## Issue
#${TASK_ISSUE}: ${ISSUE_TITLE}"
else
  PR_TITLE="Claude agent: $(echo "$TASK_PROMPT" | head -c 60)"
  PR_BODY="🤖 This PR was generated by a Claude agent.

## Task
${TASK_PROMPT}"
fi

log "Opening pull request..."
PR_URL=$(gh pr create \
  -R "$TASK_REPO" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --head "$TASK_BRANCH" 2>&1 | tee -a "$LOG_FILE" | tail -1)
log "PR opened: $PR_URL"

PR_NUMBER=$(echo "$PR_URL" | grep -o '[0-9]*$')

if [ -n "$TASK_ISSUE" ]; then
  gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
    --body "🤖 PR opened: ${PR_URL}" 2>/dev/null || true
fi

# ── Monitor loop ─────────────────────────────────────────────────
log "Entering monitor loop for PR #$PR_NUMBER..."
MONITOR_START=$(date +%s)
MONITOR_TIMEOUT_HOURS="${MONITOR_TIMEOUT_HOURS:-4}"
MONITOR_TIMEOUT_SECS=$((MONITOR_TIMEOUT_HOURS * 3600))
LAST_ACTIVITY=$(date +%s)

while true; do
  sleep 300

  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_ACTIVITY))
  if [ "$ELAPSED" -gt "$MONITOR_TIMEOUT_SECS" ]; then
    log "Monitor timeout ($MONITOR_TIMEOUT_HOURS hours with no activity). Exiting."
    if [ -n "$TASK_ISSUE" ]; then
      gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
        --body "🤖 Agent timed out after $MONITOR_TIMEOUT_HOURS hours of inactivity." 2>/dev/null || true
    fi
    exit 0
  fi

  # Check PR state
  PR_STATE=$(gh pr view "$PR_NUMBER" -R "$TASK_REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")

  if [ "$PR_STATE" = "MERGED" ]; then
    log "PR #$PR_NUMBER has been merged!"
    if [ -n "$TASK_ISSUE" ]; then
      gh issue edit "$TASK_ISSUE" -R "$TASK_REPO" \
        --remove-label "claude-in-progress" \
        --add-label "claude-done" 2>/dev/null || true
      gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
        --body "🤖 PR merged. Task complete!" 2>/dev/null || true
    fi
    exit 0
  fi

  if [ "$PR_STATE" = "CLOSED" ]; then
    log "PR #$PR_NUMBER was closed without merging."
    if [ -n "$TASK_ISSUE" ]; then
      gh issue comment "$TASK_ISSUE" -R "$TASK_REPO" \
        --body "🤖 PR was closed. Stopping agent." 2>/dev/null || true
      gh issue edit "$TASK_ISSUE" -R "$TASK_REPO" \
        --remove-label "claude-in-progress" 2>/dev/null || true
    fi
    exit 0
  fi

  # Check CI status
  CI_OUTPUT=$(gh pr checks "$PR_NUMBER" -R "$TASK_REPO" 2>/dev/null || true)
  if echo "$CI_OUTPUT" | grep -qiE "fail|error"; then
    log "CI failure detected. Asking Claude to fix..."
    LAST_ACTIVITY=$(date +%s)

    CI_PROMPT="The CI checks on this PR have failed. Here are the CI results:

${CI_OUTPUT}

Please examine the failures, fix the issues, and commit the fixes."

    cd "$REPO_DIR"
    gosu claude $CLAUDE_CMD -p "$CI_PROMPT" --dangerously-skip-permissions 2>&1 | tee -a "$LOG_FILE"

    if ! git diff --quiet HEAD || [ -n "$(git ls-files --others --exclude-standard)" ]; then
      git add -A
      git commit -m "fix: address CI failures" 2>/dev/null || true
      git push 2>&1 | tee -a "$LOG_FILE"
      log "Pushed CI fix."
    fi
  fi

  # Check for new review comments
  REVIEWS=$(gh api "repos/${TASK_REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null || echo "[]")
  REVIEW_COMMENTS=$(gh api "repos/${TASK_REPO}/pulls/${PR_NUMBER}/comments" 2>/dev/null || echo "[]")

  # Count comments — if any exist, ask Claude to address them
  REVIEW_COUNT=$(echo "$REVIEWS" | jq '[.[] | select(.state != "APPROVED")] | length' 2>/dev/null || echo 0)
  COMMENT_COUNT=$(echo "$REVIEW_COMMENTS" | jq 'length' 2>/dev/null || echo 0)

  if [ "$REVIEW_COUNT" -gt 0 ] || [ "$COMMENT_COUNT" -gt 0 ]; then
    # Build a summary of review feedback
    REVIEW_SUMMARY=$(echo "$REVIEWS" | jq -r '.[] | select(.state != "APPROVED") | "[\(.state)] \(.user.login): \(.body)"' 2>/dev/null || true)
    COMMENT_SUMMARY=$(echo "$REVIEW_COMMENTS" | jq -r '.[] | "\(.user.login) on \(.path):\(.line): \(.body)"' 2>/dev/null || true)

    if [ -n "$REVIEW_SUMMARY" ] || [ -n "$COMMENT_SUMMARY" ]; then
      log "Review comments found. Asking Claude to address..."
      LAST_ACTIVITY=$(date +%s)

      REVIEW_PROMPT="There are review comments on this PR that need to be addressed:

Reviews:
${REVIEW_SUMMARY}

Inline comments:
${COMMENT_SUMMARY}

Please address the feedback, make the necessary changes, and commit."

      cd "$REPO_DIR"
      gosu claude $CLAUDE_CMD -p "$REVIEW_PROMPT" --dangerously-skip-permissions 2>&1 | tee -a "$LOG_FILE"

      if ! git diff --quiet HEAD || [ -n "$(git ls-files --others --exclude-standard)" ]; then
        git add -A
        git commit -m "fix: address review feedback" 2>/dev/null || true
        git push 2>&1 | tee -a "$LOG_FILE"
        log "Pushed review fixes."
      fi
    fi
  fi

  log "Monitor loop: PR #$PR_NUMBER state=$PR_STATE, still watching..."
done
