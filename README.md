# dev-loop

Autonomous plan→work→judge skills for AI coding agents. Ship faster with browser-verified orchestration loops.

## What is this?

dev-loop is a set of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills and hooks that turn your AI coding agent into an autonomous development loop. Give it a goal, and it will:

1. **Plan** — decompose the goal into ordered tasks with acceptance criteria
2. **Work** — dispatch parallel worker agents to implement each task
3. **Judge** — verify the work with tests, browser checks, and diff review
4. **Decide** — continue to next task, retry on failure, or halt for human input

It runs unattended via a bash loop (`orchestrate.sh`), with optional tmux monitoring so you can watch it work.

## Quick Start

### 1. Install the skills into your project

```bash
# Copy skills into your project's .claude directory
mkdir -p .claude/skills
cp -r skills/orchestrate .claude/skills/
cp -r skills/browser-debug .claude/skills/  # optional

# Copy hooks
mkdir -p .claude/hooks
cp hooks/context-monitor.sh .claude/hooks/
cp hooks/task-validation.sh .claude/hooks/
chmod +x .claude/hooks/*.sh

# Add hooks config (or merge into existing .claude/settings.json)
cp hooks/settings.example.json .claude/settings.json

# Copy the loop runner
cp orchestrate.sh ./orchestrate.sh
chmod +x orchestrate.sh
```

### 2. Run it

**Interactive (single cycle):**
```bash
# Inside Claude Code
/orchestrate
```

**Goal-driven (fully autonomous):**
```bash
./orchestrate.sh --goal="add Stripe checkout to the conversion flow"
```

**With tmux monitoring:**
```bash
./orchestrate.sh --goal="refactor auth to use JWT" --monitor
```

**With an existing PRD:**
```bash
./orchestrate.sh my-tasks.json
```

## What's Included

### Skills

| Skill | Description |
|-------|-------------|
| **orchestrate** | The core plan→work→judge loop. Reads a PRD (JSON task list), dispatches worker agents, verifies results, and decides next steps. |
| **browser-debug** | Template for browser-based UI testing using [agent-browser](https://github.com/vercel-labs/agent-browser). Pre-map your app's pages and flows for fast, deterministic testing. |

### Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| **context-monitor.sh** | PostToolUse | Warns the agent when context window is filling up, preventing mid-task context exhaustion |
| **task-validation.sh** | TaskCompleted | Ensures work is committed and tests pass before a task can be marked done |

### orchestrate.sh

The bash loop runner. Features:
- Goal-driven mode (auto-generates PRD from a goal description)
- Graceful shutdown (Ctrl+C saves state)
- Stop signal (`touch /tmp/orchestrate-stop`)
- Steering (`echo "focus on tests" > /tmp/orchestrate-steer`)
- tmux monitor mode with live state, progress, and activity panes
- Auto-archives completed runs to `history/`
- Configurable max iterations, model, cooldown

## How It Works

### The Orchestrator

The orchestrator (Opus) never touches code. It reads state files, dispatches agents, and judges results. This separation keeps its context window lean so it can run many cycles.

```
YOU (Orchestrator — plans and judges)
  ├── Phase 0: DECOMPOSE — research codebase, create PRD from goal
  ├── Phase 1: ORIENT — read state files (PRD, progress, verdict)
  ├── Phase 2: PLAN — break task into goal-oriented subtasks
  ├── Phase 3: WORK — dispatch parallel worker agents
  ├── Phase 4: JUDGE — verify with tests, browser, diff review
  └── Phase 5: DECIDE — continue, retry, or halt
```

### Workers

Workers are autonomous. They get a goal, a starting point in the codebase, and acceptance criteria. They explore, implement, and commit. No hand-holding.

### PRD Format

Tasks are defined in JSON:

```json
{
  "goal": "add dark mode support",
  "tasks": [
    {
      "id": 1,
      "name": "Add theme toggle component",
      "description": "Create a toggle that switches between light and dark mode",
      "status": "todo",
      "acceptance_criteria": [
        "E2E: clicking toggle switches the theme visually",
        "Functional: preference persists across page reloads",
        "Browser: use /browser-debug to verify the toggle works"
      ],
      "depends_on": [],
      "files_likely_involved": ["src/components/ThemeToggle.tsx"]
    }
  ]
}
```

No `verification_commands` — acceptance criteria is the contract. Workers and judges figure out how to verify.

### Key Rules

1. **Orchestrator never reads source code** — dispatches research agents instead
2. **Workers are autonomous** — give them goals, not instructions
3. **Do whatever it takes** — if the goal requires a big refactor, do it. Don't stop at recommendations
4. **Code is not done until verified** — acceptance criteria are about outcomes, not outputs
5. **Three retries max** — if something fails 3 times, halt for human help

## Browser Testing

The browser-debug skill uses [agent-browser](https://github.com/vercel-labs/agent-browser) (Rust-native, 82% fewer tokens than Playwright MCP) for UI verification.

To set it up for your project:

1. Install agent-browser: `npm install agent-browser && npx agent-browser install`
2. Copy `skills/browser-debug/SKILL.md` to `.claude/skills/browser-debug/`
3. Customize the interaction maps for your app's pages and flows
4. Add `data-testid` attributes to key UI elements

The orchestrate skill automatically dispatches browser verification agents for UI-facing tasks.

## Configuration

### orchestrate.sh options

```bash
./orchestrate.sh [prd-file] [options]

Options:
  --goal="..."     Goal-driven mode (auto-creates PRD)
  --monitor        tmux monitoring panes
  --max=N          Max iterations (default: 50)
  --model=MODEL    Claude model (default: claude-opus-4-6)
```

### Runtime controls

```bash
# Graceful stop (saves state, resume later)
Ctrl+C

# Stop after current iteration
touch /tmp/orchestrate-stop

# Steer the next iteration
echo "skip tests, focus on the API" > /tmp/orchestrate-steer
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- [agent-browser](https://github.com/vercel-labs/agent-browser) (optional, for browser-debug skill)
- `jq` (for hooks and monitoring)
- `tmux` (optional, for `--monitor` mode)

## License

MIT
