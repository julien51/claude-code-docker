# Claude Docker — User Manual

## Quick Start

### Prerequisites

1. **`.env` file** with your API keys:
   ```
   ANTHROPIC_API_KEY=sk-ant-...
   GITHUB_TOKEN=ghp_...
   ```

2. **`dispatch.conf`** — edit to list your repos (already has sensible defaults).

3. **Build the image:**
   ```bash
   docker compose build --no-cache
   ```

### Interactive Mode (unchanged)

```bash
claude-start [session-name]   # Start or resume a session
claude-attach                 # Reconnect to a running session
```

### Headless Agent — Manual

```bash
# Launch agent for a GitHub issue
claude-task ouvre-boite-industries/domains 42

# Launch agent with a direct prompt
claude-task ouvre-boite-industries/domains --prompt "Fix the broken CSS on the landing page"
```

### Headless Agent — Automatic (Dispatcher)

```bash
claude-dispatch --daemon      # Start polling in background
```

Then create a GitHub issue in any monitored repo and add the `claude` label. The dispatcher picks it up within 5 minutes.

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `claude-start [name]` | Start interactive Claude session |
| `claude-attach` | Reconnect to interactive session |
| `claude-task <repo> <issue>` | Launch headless agent for a GitHub issue |
| `claude-task <repo> --prompt "..."` | Launch headless agent with direct prompt |
| `claude-task --status` | Show all running agents |
| `claude-task --logs <name>` | Tail agent logs |
| `claude-task --stop <name>` | Stop an agent |
| `claude-dispatch` | Start dispatcher in foreground |
| `claude-dispatch --daemon` | Start dispatcher in background |
| `claude-dispatch --stop` | Stop background dispatcher |
| `claude-dispatch --status` | Check if dispatcher is running |

---

## Creating Tasks via GitHub Issues

1. File a GitHub issue in any repo listed in `dispatch.conf` `REPOS`.
2. Add the `claude` label to the issue.
3. The issue body is the task prompt — be specific about what you want done.

### What the agent does:

1. Clones the repo into an isolated container
2. Creates a branch: `claude/<issue-number>-<slugified-title>`
3. Runs Claude with the issue body as the prompt
4. If changes are produced: pushes branch and opens a PR referencing the issue
5. Enters a **monitor loop** — every 5 minutes it checks:
   - **PR merged?** → labels issue `claude-done`, exits
   - **PR closed?** → exits
   - **CI failures?** → asks Claude to fix, pushes
   - **Review comments?** → asks Claude to address, pushes
6. Times out after 4 hours of inactivity (configurable)

### Label lifecycle:

| Label | Meaning |
|-------|---------|
| `claude` | Issue ready for pickup |
| `claude-in-progress` | Agent is working on it |
| `claude-done` | PR was merged |

---

## Monitoring Agents

```bash
# Overview of all running agents
claude-task --status

# Live log output
claude-task --logs claude-agent-myorg-myrepo-42-1707500000

# Stop an agent
claude-task --stop claude-agent-myorg-myrepo-42-1707500000
```

Logs persist in `~/claude-docker/logs/`.

Dispatcher logs: `~/claude-docker/logs/dispatch.log`.

---

## Configuration

### `dispatch.conf`

| Setting | Default | Description |
|---------|---------|-------------|
| `REPOS` | (none) | Space-separated list of `owner/repo` to monitor |
| `POLL_INTERVAL` | `300` | Seconds between GitHub polls |
| `MAX_AGENTS` | `3` | Max concurrent headless agents |
| `AGENT_CPUS` | `1` | CPU limit per agent container |
| `AGENT_MEMORY` | `2g` | Memory limit per agent container |
| `MONITOR_TIMEOUT_HOURS` | `4` | Hours of inactivity before agent stops monitoring |
| `TASK_LABEL` | `claude` | GitHub issue label that triggers pickup |
| `BRANCH_PREFIX` | `claude` | Prefix for agent-created branches |

### `.env`

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude |
| `GITHUB_TOKEN` | GitHub token with repo access |

### `claude-config/`

Shared Claude settings, credentials, and CLAUDE.md. Mounted read-only into all containers.

---

## Architecture

Each headless agent runs in its own Docker container with:
- Its own repo clone (not shared with interactive sessions)
- Its own branch
- Resource limits (CPU + memory)
- Isolated `/home/claude` volume

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
  Agent Agent Agent
  (isolated containers)
    │    │    │
    ▼    ▼    ▼
  Open PRs, monitor CI/reviews
```
