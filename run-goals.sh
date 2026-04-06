#!/usr/bin/env bash
#
# run-goals.sh — Auto-run Claude sessions for each goal in goals.md
#
# Usage:
#   ./run-goals.sh                  # Run through goals in auto mode
#   ./run-goals.sh my-goals.md      # Use a different goals file
#   ./run-goals.sh --skip           # Skip current goal, mark done
#
# How it works:
#   Claude runs autonomously on each goal (auto mode via -p).
#   You see all output streaming in real-time — text, tool calls, results.
#   When Claude finishes a goal, it auto-advances to the next.
#
#   If you want to jump in and interact:
#     1. Ctrl+C to pause the stream (Claude keeps running in background)
#     2. Choose [i] to attach interactively via --resume
#     3. Chat with Claude, give it direction, etc.
#     4. /exit when done — the runner marks the goal complete and moves on
#

GOALS_FILE="${1:-goals.md}"
SKIP_FLAG=false
COOLDOWN=3
LOG_DIR="/tmp/goal-runner"
GOAL_TIMEOUT=${GOAL_TIMEOUT:-3000}  # 50 minutes per goal max

for arg in "$@"; do
  case $arg in
    --skip) SKIP_FLAG=true ;;
    --cooldown=*) COOLDOWN="${arg#*=}" ;;
  esac
done

if [[ "$GOALS_FILE" == --* ]]; then
  GOALS_FILE="goals.md"
fi

if [ ! -f "$GOALS_FILE" ]; then
  echo "Goals file not found: $GOALS_FILE"
  exit 1
fi

mkdir -p "$LOG_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────────────
get_next_goal() {
  # Pick up timed-out [~] goals first, then unchecked [ ] goals
  local result
  result=$(grep -n '^\- \[~\]' "$GOALS_FILE" | head -1)
  if [ -z "$result" ]; then
    result=$(grep -n '^\- \[ \]' "$GOALS_FILE" | head -1)
  fi
  echo "$result"
}

count_remaining() {
  local unchecked timed_out
  unchecked=$(grep -c '^\- \[ \]' "$GOALS_FILE" 2>/dev/null) || true
  timed_out=$(grep -c '^\- \[~\]' "$GOALS_FILE" 2>/dev/null) || true
  echo $(( ${unchecked:-0} + ${timed_out:-0} ))
}

mark_done() {
  local line_num="$1"
  sed -i '' "${line_num}s/- \[ \]/- [x]/" "$GOALS_FILE"
  sed -i '' "${line_num}s/- \[~\]/- [x]/" "$GOALS_FILE"
}

mark_timed_out() {
  local line_num="$1"
  sed -i '' "${line_num}s/- \[ \]/- [~]/" "$GOALS_FILE"
}

# ─── JQ filter for rich output ────────────────────────────────────────────────
# Shows: text output, tool calls (name + key input), tool results (truncated)
JQ_FILTER='
  if .type == "assistant" then
    .message.content[]? |
    if .type == "text" then
      .text // empty
    elif .type == "tool_use" then
      "\n\u001b[36m⏺ " + .name +
      (if .name == "Bash" then "(" + (.input.command // "?" | .[0:80]) + ")"
       elif .name == "Read" then "(" + (.input.file_path // "?" | split("/") | last) + ")"
       elif .name == "Write" then "(" + (.input.file_path // "?" | split("/") | last) + ")"
       elif .name == "Edit" then "(" + (.input.file_path // "?" | split("/") | last) + ")"
       elif .name == "Grep" then "(" + (.input.pattern // "?") + ")"
       elif .name == "Glob" then "(" + (.input.pattern // "?") + ")"
       elif .name == "Skill" then "(" + (.input.skill // "?") + ")"
       elif .name == "Agent" then "(" + (.input.description // "?") + ")"
       elif (.name | startswith("mcp__playwright")) then "(" + (.name | split("__") | last) + ")"
       else ""
       end) + "\u001b[0m\n"
    else empty
    end
  elif .type == "user" then
    .tool_use_result // null |
    if . != null then
      if .isImage then
        "\u001b[33m  ⎿  [screenshot taken]\u001b[0m\n"
      elif (.stdout // "" | length) > 0 then
        "\u001b[33m  ⎿  " + (.stdout | .[0:200] | gsub("\n"; " ")) + "\u001b[0m\n"
      else
        ""
      end
    else empty
    end
  else empty
  end
'

# Stream a jsonl log file with rich output until a PID exits or INTERRUPTED.
# Usage: stream_output <logfile> <pid>
stream_output() {
  local logfile="$1"
  local watch_pid="$2"
  local lines_read=0

  while true; do
    # If interrupted, stop streaming (but don't kill claude)
    if $INTERRUPTED; then
      break
    fi

    # Check if claude is still running
    if ! kill -0 "$watch_pid" 2>/dev/null; then
      # Claude exited — read any remaining lines then stop
      local total
      total=$(wc -l < "$logfile" 2>/dev/null || echo 0)
      if [ "$total" -gt "$lines_read" ]; then
        tail -n +"$((lines_read + 1))" "$logfile" \
          | jq --unbuffered -rj "$JQ_FILTER" 2>/dev/null || true
      fi
      break
    fi

    # Read new lines
    local total
    total=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    if [ "$total" -gt "$lines_read" ]; then
      tail -n +"$((lines_read + 1))" "$logfile" | head -n "$((total - lines_read))" \
        | jq --unbuffered -rj "$JQ_FILTER" 2>/dev/null || true
      lines_read=$total
    fi

    sleep 0.3
  done
}

# ─── Skip mode ────────────────────────────────────────────────────────────────
if $SKIP_FLAG; then
  MATCH=$(get_next_goal)
  if [ -z "$MATCH" ]; then
    echo "No incomplete goals to skip."
    exit 0
  fi
  LINE_NUM=$(echo "$MATCH" | cut -d: -f1)
  GOAL_TEXT=$(echo "$MATCH" | cut -d: -f2- | sed 's/^- \[.\] //')
  mark_done "$LINE_NUM"
  echo "Skipped: $GOAL_TEXT"
  exit 0
fi

# ─── Main loop ────────────────────────────────────────────────────────────────
GOAL_NUM=0
START_TIME=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  GOAL RUNNER                                            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  File:    $GOALS_FILE"
echo "║  Mode:    Auto (Ctrl+C to jump in interactively)"
echo "║  Goals:   $(count_remaining) remaining"
echo "║                                                          ║"
echo "║  Ctrl+C  = pause stream & choose action                 ║"
echo "║           (Claude keeps working in background)           ║"
echo "╚══════════════════════════════════════════════════════════╝"

while true; do
  MATCH=$(get_next_goal)

  if [ -z "$MATCH" ]; then
    ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ALL GOALS COMPLETE                                     ║"
    echo "║  Finished $GOAL_NUM goals in ${ELAPSED} minutes         "
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    osascript -e 'display notification "All goals complete!" with title "Goal Runner"' 2>/dev/null || true
    break
  fi

  LINE_NUM=$(echo "$MATCH" | cut -d: -f1)
  GOAL_TEXT=$(echo "$MATCH" | cut -d: -f2- | sed 's/^- \[.\] //')
  IS_RETRY=false
  echo "$MATCH" | grep -q '^\- \[~\]' && IS_RETRY=true
  GOAL_NUM=$((GOAL_NUM + 1))
  REMAINING=$(count_remaining)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Goal $GOAL_NUM ($REMAINING remaining): $GOAL_TEXT"
  echo "  $(date '+%H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  GOAL_START=$(date +%s)
  ITER_LOG="$LOG_DIR/goal-${GOAL_NUM}.jsonl"
  rm -f "$ITER_LOG"
  touch "$ITER_LOG"

  # ── Launch claude in background ─────────────────────────────────────────────
  INTERRUPTED=false

  RETRY_CONTEXT=""
  if $IS_RETRY; then
    # Find the most recent log for this goal
    PREV_LOG=$(ls -t "$LOG_DIR"/goal-*.jsonl 2>/dev/null | head -1)
    RETRY_CONTEXT="
NOTE: This goal previously timed out. Check the previous session log at $PREV_LOG for what was already done.
You can extract text and tool calls from it with: jq -r 'select(.type==\"assistant\") | .message.content[]? | if .type==\"text\" then .text elif .type==\"tool_use\" then \"TOOL: \" + .name + \" \" + (.input | tostring | .[0:200]) else empty end' $PREV_LOG | tail -50
Also check git log and git stash list for any committed or stashed work from the previous attempt.
Resume where it left off rather than starting from scratch."
  fi

  GOAL_PROMPT="$GOAL_TEXT
$RETRY_CONTEXT
IMPORTANT — This is goal $GOAL_NUM in an automated goal runner. When you finish:
- Mark line $LINE_NUM in $GOALS_FILE as done: change '- [ ]' to '- [x]'
- Append a summary to goals-progress.md with this format:
  ### [YYYY-MM-DD HH:MM] — Goal $GOAL_NUM: [Goal Title]
  - What was done: [description]
  - Files created/modified: [list]
  - Tests: [pass/fail status or N/A]
  - Learnings: [patterns discovered, gotchas, things that affect future goals]
  - Blockers: [anything that couldn't be resolved, or none]
- Commit your changes (include goals-progress.md in the commit)
- Then STOP — do not continue with additional work. The runner will advance to the next goal.

If you cannot achieve this goal after reasonable effort:
- Stash your tracked changes: git stash push -m \"goal-${GOAL_NUM}: ${GOAL_TEXT}\"
- Mark line $LINE_NUM in $GOALS_FILE as incomplete: change '- [ ]' or '- [~]' to '- [~]'
- Do NOT commit — just stash and stop."

  claude -p "$GOAL_PROMPT" \
    --dangerously-skip-permissions \
    --verbose \
    --effort max \
    --output-format stream-json \
    --append-system-prompt "ABSOLUTE RULE — NO BACKGROUND TASKS:
You MUST NOT set run_in_background=true on ANY tool call. This includes:
- Bash: NEVER use run_in_background. Use timeout command if a process might hang (e.g. timeout 30 npx convex logs).
- Agent: NEVER use run_in_background. Always run agents in the foreground.
- Any other tool: NEVER use run_in_background parameter.
Background tasks cause the session to hang indefinitely waiting for completion notifications that never arrive.
If you need to run a potentially long command, use a shell timeout: timeout <seconds> <command>
If you need Convex logs, use: timeout 15 npx convex logs --prod --history
VIOLATION OF THIS RULE WILL CAUSE THE ENTIRE GOAL RUNNER TO HANG." \
    > "$ITER_LOG" 2>/dev/null &
  CLAUDE_PID=$!
  TIMED_OUT=false

  # Watchdog: kill claude if it exceeds the goal timeout, mark as [~]
  (
    sleep "$GOAL_TIMEOUT"
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
      echo ""
      echo "  ⚠️  Goal timed out after ${GOAL_TIMEOUT}s — killing session"
      kill "$CLAUDE_PID" 2>/dev/null
    fi
  ) &
  WATCHDOG_PID=$!

  # Ctrl+C: DON'T kill claude — just stop the stream display
  trap 'INTERRUPTED=true' INT

  # Stream rich output in foreground until claude exits or Ctrl+C
  stream_output "$ITER_LOG" "$CLAUDE_PID"

  trap - INT

  # Kill the watchdog timer
  kill "$WATCHDOG_PID" 2>/dev/null
  wait "$WATCHDOG_PID" 2>/dev/null || true

  GOAL_DURATION=$(( $(date +%s) - GOAL_START ))

  # Check if goal timed out (duration >= timeout and not interrupted by user)
  if [ "$GOAL_DURATION" -ge "$GOAL_TIMEOUT" ] && ! $INTERRUPTED; then
    TIMED_OUT=true
  fi

  # Extract session ID from the log for resume
  SESSION_ID=$(jq -r 'select(.type == "system") | .session_id // empty' "$ITER_LOG" 2>/dev/null | head -1)

  # ── Handle interruption (Ctrl+C) ──────────────────────────────────────────
  if $INTERRUPTED; then
    # Check if claude is still running
    CLAUDE_RUNNING=false
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
      CLAUDE_RUNNING=true
    fi

    echo ""
    echo ""
    if $CLAUDE_RUNNING; then
      echo "  Stream paused (Claude still working in background)."
    else
      echo "  Session paused after ${GOAL_DURATION}s."
    fi
    if [ -n "$SESSION_ID" ]; then
      echo "  Session: $SESSION_ID"
    fi
    echo ""
    echo "  What would you like to do?"
    echo "    [i] Jump into interactive session (resume with full context)"
    echo "    [w] Wait — re-attach to the stream (if still running)"
    echo "    [s] Skip this goal and move to next"
    echo "    [r] Retry this goal from scratch"
    echo "    [q] Quit"
    echo ""
    read -rp "  Choice [i/w/s/r/q]: " CHOICE

    case "${CHOICE:-i}" in
      [iI]*)
        # Kill the background claude so we can resume interactively
        if $CLAUDE_RUNNING; then
          kill "$CLAUDE_PID" 2>/dev/null
          wait "$CLAUDE_PID" 2>/dev/null || true
        fi
        echo ""
        echo "  Opening interactive session... (/exit when done)"
        echo ""
        if [ -n "$SESSION_ID" ]; then
          claude --resume "$SESSION_ID" --dangerously-skip-permissions || true
        else
          claude --continue --dangerously-skip-permissions || true
        fi
        mark_done "$LINE_NUM"
        echo ""
        echo "  Marked done: $GOAL_TEXT"
        ;;
      [wW]*)
        if $CLAUDE_RUNNING; then
          echo "  Re-attaching to stream..."
          echo ""
          INTERRUPTED=false
          trap 'INTERRUPTED=true' INT
          stream_output "$ITER_LOG" "$CLAUDE_PID"
          trap - INT
          wait "$CLAUDE_PID" 2>/dev/null || true
          GOAL_DURATION=$(( $(date +%s) - GOAL_START ))

          if $INTERRUPTED; then
            # Interrupted again — loop back to menu
            GOAL_NUM=$((GOAL_NUM - 1))
            continue
          fi

          mark_done "$LINE_NUM"
          echo ""
          echo "  Completed: $GOAL_TEXT (${GOAL_DURATION}s)"
        else
          echo "  Claude already finished. Marking done."
          mark_done "$LINE_NUM"
        fi
        ;;
      [sS]*)
        if $CLAUDE_RUNNING; then
          kill "$CLAUDE_PID" 2>/dev/null
          wait "$CLAUDE_PID" 2>/dev/null || true
        fi
        mark_done "$LINE_NUM"
        echo "  Skipped: $GOAL_TEXT"
        ;;
      [rR]*)
        if $CLAUDE_RUNNING; then
          kill "$CLAUDE_PID" 2>/dev/null
          wait "$CLAUDE_PID" 2>/dev/null || true
        fi
        echo "  Retrying..."
        GOAL_NUM=$((GOAL_NUM - 1))
        continue
        ;;
      [qQ]*)
        if $CLAUDE_RUNNING; then
          kill "$CLAUDE_PID" 2>/dev/null
          wait "$CLAUDE_PID" 2>/dev/null || true
        fi
        echo "  Stopped. $(count_remaining) goals remaining in $GOALS_FILE."
        exit 0
        ;;
    esac
  else
    if $TIMED_OUT; then
      # ── Goal timed out — mark as [~] for retry next run ──────────────────
      mark_timed_out "$LINE_NUM"
      echo ""
      echo ""
      echo "  ⚠️  Timed out: $GOAL_TEXT (${GOAL_DURATION}s) — marked [~] for retry"
      # Log partial progress
      {
        echo ""
        echo "### [$(date '+%Y-%m-%d %H:%M')] — Goal $GOAL_NUM: $GOAL_TEXT (TIMED OUT)"
        echo "- Status: Timed out after ${GOAL_DURATION}s"
        echo "- Will retry on next run"
        echo ""
      } >> goals-progress.md
    else
      # ── Goal completed successfully ────────────────────────────────────────
      mark_done "$LINE_NUM"
      echo ""
      echo ""
      echo "  Completed: $GOAL_TEXT (${GOAL_DURATION}s)"
    fi

    # Brief pause between goals
    REMAINING_NOW=$(count_remaining)
    if [ "$REMAINING_NOW" -gt 0 ]; then
      echo "  Next goal in ${COOLDOWN}s... (Ctrl+C to stop)"
      sleep "$COOLDOWN" 2>/dev/null || {
        echo ""
        read -rp "  Stop the runner? [Y/n] " ANSWER
        case "${ANSWER:-y}" in
          [nN]*) continue ;;
          *) echo "  Stopped. $REMAINING_NOW goals remaining."; exit 0 ;;
        esac
      }
    fi
  fi
done
