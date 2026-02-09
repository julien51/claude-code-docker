# Claude Agents

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in Docker — both as **interactive sessions** and as **headless autonomous agents** that pick up GitHub Issues, do the work, open PRs, and iterate on CI failures and review feedback until merged.

## What is this?

This is a self-contained toolkit for running Claude Code in isolated Docker containers. It supports two modes:

**Interactive mode** — Start a Claude Code session in a container, attach your terminal, and work as usual. Your workspace is bind-mounted in, so changes persist.

**Headless agent mode** — Point an agent at a GitHub Issue (or give it a prompt), and it will:
1. Clone the repo into its own isolated container
2. Create a branch and do the work
3. Open a Pull Request
4. Monitor CI and review comments every 5 minutes
5. Automatically fix CI failures and address reviewer feedback
6. Exit when the PR is merged, closed, or after a configurable timeout

You can launch agents manually with `claude-task`, or run the `claude-dispatch` daemon to automatically pick up issues labeled `claude` across your repos.

```
┌─────────────────┐
│  GitHub Issues   │
│  label: claude   │
└────────┬────────┘
         │ polls every 5min
┌────────▼────────┐
│  claude-dispatch │
│  (cron/loop)     │
└────────┬────────┘
         │ spawns containers via claude-task
    ┌────┼────┐
    ▼    ▼    ▼
  Agent Agent Agent       (isolated containers, own clone, own branch)
    │    │    │
    ▼    ▼    ▼
  Open PRs, monitor CI + reviews, push fixes
```

Each agent is fully isolated: own container, own repo clone, own branch, own resource limits (CPU + memory).

---

## Prerequisites

- Docker and Docker Compose
- An [Anthropic API key](https://console.anthropic.com/)
- A [GitHub personal access token](https://github.com/settings/tokens) with `repo` scope

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/julien51/claude-agents.git
cd claude-agents
```

### 2. Create your `.env` file

```bash
cp .env.example .env
```

Edit `.env` and add your real keys:

```
ANTHROPIC_API_KEY=sk-ant-api03-...
GITHUB_TOKEN=ghp_...
```

### 3. Set up shared config (optional)

The `claude-config/` directory is mounted read-only into every container. Use it to share Claude settings across sessions:

```bash
mkdir -p claude-config/.claude
```

You can add any of these:

| File | Purpose |
|------|---------|
| `claude-config/.gitconfig` | Git identity (name, email, signing) |
| `claude-config/.claude.json` | Claude account/settings seed |
| `claude-config/.claude/CLAUDE.md` | Global instructions for Claude |
| `claude-config/.claude/settings.json` | Claude Code settings |
| `claude-config/.claude/.credentials.json` | Claude credentials (if using OAuth) |
| `claude-config/.claude/projects/` | Per-project Claude settings |
| `claude-config/.claude/plugins/` | Claude plugins |

None of these are required. The container will work with just the API key from `.env`.

### 4. Configure the dispatcher (for headless agents)

Edit `dispatch.conf` to list your repos:

```bash
# Repos to monitor for claude-labeled issues (space-separated)
REPOS="your-org/your-repo another-org/another-repo"
```

See [dispatch.conf reference](#dispatchconf) for all options.

### 5. Build the Docker image

```bash
docker compose build --no-cache
```

Rebuild with `--no-cache` whenever you want to pick up a new version of Claude Code.

---

## Usage

### Interactive Sessions

Start a session:

```bash
./claude-start my-session
```

This creates a Docker container named `claude-session-my-session`, runs the entrypoint setup, and drops you into the Claude Code CLI. Your `workspace/` directory is bind-mounted at `/workspace`.

Detach with `Ctrl-P Ctrl-Q`. Reattach later:

```bash
./claude-attach
```

If multiple sessions are running, you'll get a menu to pick one.

### Headless Agents — Manual Launch

Launch an agent for a specific GitHub issue:

```bash
./claude-task your-org/your-repo 42
```

Or give it a direct prompt:

```bash
./claude-task your-org/your-repo --prompt "Add input validation to the signup form"
```

Manage running agents:

```bash
./claude-task --status              # Show all running agents + resource usage
./claude-task --logs <agent-name>   # Tail live log output
./claude-task --stop <agent-name>   # Stop an agent
```

### Headless Agents — Automatic Dispatcher

Start the dispatcher to automatically pick up `claude`-labeled issues:

```bash
./claude-dispatch --daemon    # Run in background
./claude-dispatch --status    # Check if running
./claude-dispatch --stop      # Stop it
./claude-dispatch             # Or run in foreground
```

The dispatcher polls each repo in `dispatch.conf` every 5 minutes (configurable). When it finds an issue with the `claude` label, it launches an agent for it.

---

## How Headless Agents Work

When an agent starts (whether via `claude-task` or `claude-dispatch`), it goes through this lifecycle:

### 1. Setup
- Copies shared config from `claude-config/`
- Authenticates `gh` CLI with your GitHub token
- Fetches Claude skills from dotfiles

### 2. Clone & Branch
- Clones the repo into `/work/<repo-name>` inside the container
- Creates a branch: `claude/<issue-number>-<slugified-title>`

### 3. Work
- Fetches the issue body as the task prompt
- Comments on the issue: "Agent started working on this"
- Swaps labels: removes `claude`, adds `claude-in-progress`
- Runs Claude Code with `--dangerously-skip-permissions` in headless mode (`-p`)
- Claude reads the codebase, makes changes, runs tests, commits

### 4. Open PR
- Pushes the branch
- Opens a PR with title from the issue, body referencing `Closes #N`
- Comments on the issue with a link to the PR

### 5. Monitor Loop
Every 5 minutes, the agent checks:

| Check | Action |
|-------|--------|
| **PR merged** | Labels issue `claude-done`, comments, exits |
| **PR closed** | Comments on issue, exits |
| **CI failure** | Feeds failure details to Claude, pushes fixes |
| **Review comments** | Feeds review feedback to Claude, pushes fixes |
| **Timeout** | Exits after N hours of no activity (default: 4h) |

### Label Lifecycle

| Label | Meaning |
|-------|---------|
| `claude` | Issue is ready for agent pickup |
| `claude-in-progress` | An agent is actively working on it |
| `claude-done` | The PR was merged successfully |

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `./claude-start [name]` | Start or resume an interactive Claude session |
| `./claude-attach` | Reconnect to a running interactive session |
| `./claude-task <repo> <issue>` | Launch a headless agent for a GitHub issue |
| `./claude-task <repo> --prompt "..."` | Launch a headless agent with a direct prompt |
| `./claude-task --status` | Show all running agents and resource usage |
| `./claude-task --logs <name>` | Tail live logs for an agent |
| `./claude-task --stop <name>` | Stop a running agent |
| `./claude-dispatch` | Run the issue dispatcher in foreground |
| `./claude-dispatch --daemon` | Run the dispatcher in background |
| `./claude-dispatch --stop` | Stop the background dispatcher |
| `./claude-dispatch --status` | Check if the dispatcher is running |
| `docker compose build --no-cache` | Rebuild image (picks up latest Claude Code) |

---

## Configuration

### `.env`

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Your Anthropic API key |
| `GITHUB_TOKEN` | Yes | GitHub personal access token with `repo` scope |

### `dispatch.conf`

| Setting | Default | Description |
|---------|---------|-------------|
| `REPOS` | *(none)* | Space-separated list of `owner/repo` to monitor |
| `POLL_INTERVAL` | `300` | Seconds between GitHub polls |
| `MAX_AGENTS` | `3` | Maximum concurrent headless agents |
| `AGENT_CPUS` | `1` | CPU limit per agent container |
| `AGENT_MEMORY` | `2g` | Memory limit per agent container |
| `MONITOR_TIMEOUT_HOURS` | `4` | Hours of inactivity before agent stops monitoring a PR |
| `TASK_LABEL` | `claude` | GitHub issue label that triggers agent pickup |
| `BRANCH_PREFIX` | `claude` | Prefix for agent-created branch names |

### `claude-config/`

Shared configuration directory, mounted read-only into all containers. Put your `.gitconfig`, Claude credentials, `CLAUDE.md`, and settings here. See [Setup step 3](#3-set-up-shared-config-optional) for details.

---

## File Structure

```
claude-agents/
├── .env.example          # Template for API keys
├── .gitignore
├── Dockerfile            # Image: node:20-slim + gh CLI + jq + gosu + claude-code
├── README.md             # This file
├── claude-attach         # Reconnect to a running interactive session
├── claude-dispatch       # Dispatcher daemon: polls GitHub, spawns agents
├── claude-start          # Start/resume an interactive Claude session
├── claude-task           # Manual agent launcher + status/logs/stop
├── dispatch.conf         # Dispatcher configuration
├── docker-compose.yml    # Used for building the image
├── entrypoint-task.sh    # Container entrypoint for headless agents
├── entrypoint.sh         # Container entrypoint for interactive sessions
├── claude-config/        # Shared config (git-ignored, you create this)
│   ├── .gitconfig
│   └── .claude/
│       ├── CLAUDE.md
│       ├── settings.json
│       └── .credentials.json
├── logs/                 # Agent log files (git-ignored, created at runtime)
└── workspace/            # Bind-mounted workspace for interactive sessions (git-ignored)
```

---

## Monitoring & Debugging

### Agent logs

Each agent writes to `logs/<agent-name>.log`. The dispatcher writes to `logs/dispatch.log`.

```bash
# Tail a specific agent
./claude-task --logs claude-agent-myorg-myrepo-42-1707500000

# Tail the dispatcher
tail -f logs/dispatch.log

# See all log files
ls -lt logs/
```

### Container resource usage

```bash
./claude-task --status
# or directly:
docker stats --filter "name=claude-agent-"
```

### Troubleshooting

| Problem | Fix |
|---------|-----|
| Agent exits immediately | Check `logs/<agent-name>.log` for errors. Common: missing API keys, repo not found. |
| Dispatcher not picking up issues | Verify the issue has the `claude` label (not `claude-in-progress`). Check `logs/dispatch.log`. |
| Agent can't push to repo | Ensure your `GITHUB_TOKEN` has `repo` scope on the target repo. |
| Image is outdated | Rebuild: `docker compose build --no-cache` |
| Too many agents running | Adjust `MAX_AGENTS` in `dispatch.conf`, or stop agents with `./claude-task --stop <name>`. |

---

## Security Notes

- API keys live in `.env` (git-ignored). Never commit them.
- Credentials in `claude-config/` are git-ignored.
- Agents run with `--dangerously-skip-permissions` — they can execute arbitrary commands inside their container. Each container is isolated, but review what you're asking them to do.
- The `GITHUB_TOKEN` is passed into every container. Use a token scoped to only the repos you want agents to access.
- Resource limits (`--cpus`, `--memory`) prevent any single agent from consuming the host.
