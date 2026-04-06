#!/usr/bin/env bash
#
# run-goals-codex.sh — Auto-run Codex sessions for each goal in codex-goals.md
#
# Usage:
#   ./run-goals-codex.sh                  # Run through goals in auto mode
#   ./run-goals-codex.sh my-goals.md      # Use a different goals file
#   ./run-goals-codex.sh --skip           # Skip current goal, mark done
#
# How it works:
#   Codex runs autonomously on each goal (full auto via --dangerously-bypass-approvals-and-sandbox).
#   Output streams to terminal in real-time.
#   When Codex finishes a goal, it auto-advances to the next.
#
#   Goals that exceed GOAL_TIMEOUT are marked [~] and retried on the next run
#   with context pointing at the previous session log.
#

GOALS_FILE="${1:-codex-goals.md}"
PROGRESS_FILE="codex-goals-progress.md"
SKIP_FLAG=false
COOLDOWN=3
LOG_DIR="/tmp/codex-goal-runner"
MODEL="gpt-5.4"
REASONING="xhigh"
GOAL_TIMEOUT=${GOAL_TIMEOUT:-3000}  # 50 minutes per goal max

for arg in "$@"; do
  case $arg in
    --skip) SKIP_FLAG=true ;;
    --cooldown=*) COOLDOWN="${arg#*=}" ;;
    --model=*) MODEL="${arg#*=}" ;;
    --reasoning=*) REASONING="${arg#*=}" ;;
  esac
done

if [[ "$GOALS_FILE" == --* ]]; then
  GOALS_FILE="codex-goals.md"
fi

if [ ! -f "$GOALS_FILE" ]; then
  echo "Goals file not found: $GOALS_FILE"
  exit 1
fi

# Create progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Codex Goals Progress" > "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
  echo "Append-only log of goal completions from run-goals-codex.sh" >> "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
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
echo "║  CODEX GOAL RUNNER                                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  File:      $GOALS_FILE"
echo "║  Progress:  $PROGRESS_FILE"
echo "║  Model:     $MODEL (reasoning: $REASONING)"
echo "║  Mode:      Full auto (Ctrl+C to interrupt)"
echo "║  Timeout:   ${GOAL_TIMEOUT}s per goal"
echo "║  Goals:     $(count_remaining) remaining"
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
    osascript -e 'display notification "All Codex goals complete!" with title "Codex Goal Runner"' 2>/dev/null || true
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
  if $IS_RETRY; then
    echo "  (retry — previously timed out)"
  fi
  echo "  $(date '+%H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  GOAL_START=$(date +%s)
  ITER_LOG="$LOG_DIR/goal-${GOAL_NUM}.log"
  rm -f "$ITER_LOG"
  touch "$ITER_LOG"

  # ── Build the prompt ─────────────────────────────────────────────────────────
  RETRY_CONTEXT=""
  if $IS_RETRY; then
    PREV_LOG=$(ls -t "$LOG_DIR"/goal-*.log 2>/dev/null | head -1)
    RETRY_CONTEXT="
NOTE: This goal previously timed out. Check the previous session log at $PREV_LOG for what was already done.
Also check git log and git stash list for any committed or stashed work from the previous attempt.
Resume where it left off rather than starting from scratch."
  fi

  GOAL_PROMPT="$GOAL_TEXT
$RETRY_CONTEXT
IMPORTANT — This is goal $GOAL_NUM in an automated goal runner. When you finish:
- Mark line $LINE_NUM in $GOALS_FILE as done: change '- [ ]' to '- [x]'
- Append a summary to $PROGRESS_FILE with this format:
  ### [YYYY-MM-DD HH:MM] — Goal $GOAL_NUM: [Goal Title]
  - What was done: [description]
  - Files created/modified: [list]
  - Tests: [pass/fail status or N/A]
  - Learnings: [patterns discovered, gotchas, things that affect future goals]
  - Blockers: [anything that couldn't be resolved, or none]
- Commit your changes (include $PROGRESS_FILE in the commit)
- Then STOP — do not continue with additional work. The runner will advance to the next goal.

If you cannot achieve this goal after reasonable effort:
- Stash your tracked changes: git stash push -m \"goal-${GOAL_NUM}: ${GOAL_TEXT}\"
- Mark line $LINE_NUM in $GOALS_FILE as incomplete: change '- [ ]' or '- [~]' to '- [~]'
- Do NOT commit — just stash and stop."

  # ── Launch codex in background ──────────────────────────────────────────────
  INTERRUPTED=false
  TIMED_OUT=false

  codex \
    --dangerously-bypass-approvals-and-sandbox \
    -m "$MODEL" \
    -c reasoning_effort="$REASONING" \
    "$GOAL_PROMPT" \
    > "$ITER_LOG" 2>&1 &
  CODEX_PID=$!

  # Watchdog: kill codex if it exceeds the goal timeout
  (
    sleep "$GOAL_TIMEOUT"
    if kill -0 "$CODEX_PID" 2>/dev/null; then
      echo ""
      echo "  ⚠️  Goal timed out after ${GOAL_TIMEOUT}s — killing session"
      kill "$CODEX_PID" 2>/dev/null
    fi
  ) &
  WATCHDOG_PID=$!

  # Stream output live
  trap 'INTERRUPTED=true' INT
  tail -f "$ITER_LOG" --pid="$CODEX_PID" 2>/dev/null &
  TAIL_PID=$!

  wait "$CODEX_PID" 2>/dev/null
  CODEX_EXIT=$?

  kill "$TAIL_PID" 2>/dev/null
  wait "$TAIL_PID" 2>/dev/null || true
  trap - INT

  # Kill watchdog
  kill "$WATCHDOG_PID" 2>/dev/null
  wait "$WATCHDOG_PID" 2>/dev/null || true

  GOAL_DURATION=$(( $(date +%s) - GOAL_START ))

  # Check if goal timed out (duration >= timeout and not interrupted by user)
  if [ "$GOAL_DURATION" -ge "$GOAL_TIMEOUT" ] && ! $INTERRUPTED; then
    TIMED_OUT=true
  fi

  # ── Handle interruption (Ctrl+C) ──────────────────────────────────────────
  if $INTERRUPTED; then
    echo ""
    echo ""
    echo "  Session interrupted after ${GOAL_DURATION}s."
    echo ""
    echo "  What would you like to do?"
    echo "    [s] Skip this goal and move to next"
    echo "    [r] Retry this goal from scratch"
    echo "    [q] Quit"
    echo ""
    read -rp "  Choice [s/r/q]: " CHOICE

    case "${CHOICE:-q}" in
      [sS]*)
        mark_done "$LINE_NUM"
        echo "  Skipped: $GOAL_TEXT"
        ;;
      [rR]*)
        echo "  Retrying..."
        GOAL_NUM=$((GOAL_NUM - 1))
        continue
        ;;
      [qQ]*)
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
      {
        echo ""
        echo "### [$(date '+%Y-%m-%d %H:%M')] — Goal $GOAL_NUM: $GOAL_TEXT (TIMED OUT)"
        echo "- Status: Timed out after ${GOAL_DURATION}s"
        echo "- Will retry on next run"
        echo ""
      } >> "$PROGRESS_FILE"
    else
      # ── Goal completed ─────────────────────────────────────────────────────
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
