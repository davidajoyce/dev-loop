#!/usr/bin/env bash
#
# orchestrate.sh — Ralph-style loop for the /orchestrate skill
#
# Usage:
#   ./orchestrate.sh                    # Run with default prd.md
#   ./orchestrate.sh my-prd.md          # Run with a specific PRD file
#   ./orchestrate.sh --monitor          # Run with tmux monitoring panes
#   ./orchestrate.sh my-prd.md --monitor  # Both
#   ./orchestrate.sh --goal="add Stripe checkout to conversion flow"  # Goal-driven mode
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
PRD_FILE="${1:-prd.md}"
MONITOR_MODE=false
MAX_ITERATIONS=50
COOLDOWN_SECONDS=5
LOG_DIR="/tmp/orchestrate-logs"
STATE_FILE="orchestrate/state.md"
STEER_FILE="/tmp/orchestrate-steer"
MODEL="claude-opus-4-6"
GOAL=""

# Parse flags
for arg in "$@"; do
  case $arg in
    --monitor) MONITOR_MODE=true ;;
    --max=*) MAX_ITERATIONS="${arg#*=}" ;;
    --model=*) MODEL="${arg#*=}" ;;
    --goal=*) GOAL="${arg#*=}" ;;
  esac
done

# Skip PRD_FILE if first arg is a flag
if [[ "$PRD_FILE" == --* ]]; then
  PRD_FILE="prd.md"
fi

# If --goal is set, use a goal-specific PRD file
if [ -n "$GOAL" ]; then
  # Generate a safe filename from the goal
  GOAL_SLUG=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 50)
  PRD_FILE="prd-${GOAL_SLUG}.md"
fi

# ─── Setup ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" orchestrate
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SESSION_LOG="$LOG_DIR/session-$TIMESTAMP.jsonl"
STOP_FILE="/tmp/orchestrate-stop"
ITERATION=0
START_TIME=$(date +%s)

# Clean up any stale signals from previous sessions
rm -f "$STOP_FILE" "$STEER_FILE"

# Trap Ctrl+C for graceful shutdown — writes progress before exiting
graceful_shutdown() {
  echo ""
  echo "  ⚠  Graceful shutdown requested..."
  echo "  Writing shutdown state to orchestrate/state.md..."

  cat > orchestrate/state.md << SHUTDOWN
VERDICT: HALT
CYCLE: $ITERATION
REASON: Graceful shutdown requested by user (Ctrl+C or stop signal).
TASK: $(grep -m1 '### ' "$PRD_FILE" | head -1 || echo "unknown")
NOTE: Loop was interrupted. Progress up to this point has been committed. Resume with ./orchestrate.sh $PRD_FILE
SHUTDOWN

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  GRACEFULLY STOPPED                                     ║"
  echo "║  Iterations completed: $ITERATION"
  echo "║  State saved to: orchestrate/state.md"
  echo "║  Resume: ./orchestrate.sh $PRD_FILE"
  echo "╚══════════════════════════════════════════════════════════╝"

  rm -f "$STOP_FILE" "$STEER_FILE"
  osascript -e 'display notification "Orchestrate loop stopped gracefully" with title "Orchestrate"' 2>/dev/null || true
  exit 0
}
trap graceful_shutdown SIGINT SIGTERM

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           ORCHESTRATE LOOP                              ║"
echo "╠══════════════════════════════════════════════════════════╣"
if [ -n "$GOAL" ]; then
echo "║  MODE:       Goal-driven"
echo "║  GOAL:       $GOAL"
fi
echo "║  PRD:        $PRD_FILE"
echo "║  Model:      $MODEL"
echo "║  Max Iters:  $MAX_ITERATIONS"
echo "║  Log:        $SESSION_LOG"
echo "║  Started:    $(date)"
echo "║                                                          ║"
echo "║  CONTROLS:                                               ║"
echo "║  Ctrl+C      = graceful stop (saves state)              ║"
echo "║  touch /tmp/orchestrate-stop = stop after current iter  ║"
echo "║  echo 'msg' > /tmp/orchestrate-steer = redirect next   ║"
echo "║                                                          ║"
echo "║  FILES YOU CAN EDIT BETWEEN ITERATIONS:                  ║"
echo "║  $PRD_FILE  = add/change/reorder tasks"
echo "║  orchestrate/state.md     = current verdict + context    ║"
echo "║  progress.md              = session log (append-only)    ║"
echo "║                                                          ║"
echo "║  COPY TEXT (tmux):                                       ║"
echo "║  Mouse drag   = auto-copies selection to clipboard       ║"
echo "║  Ctrl+b [     = enter scroll/copy mode                   ║"
echo "║    arrow keys  = navigate                                ║"
echo "║    Space       = start selection                          ║"
echo "║    Enter / y   = copy to clipboard                       ║"
echo "║    q           = exit copy mode                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Monitor Mode (tmux) ────────────────────────────────────────────────────
if $MONITOR_MODE; then
  # Check if we're already inside tmux
  if [ -z "${TMUX:-}" ]; then
    echo "Launching tmux monitor session..."

    # Kill any existing orchestrate session
    tmux kill-session -t orchestrate 2>/dev/null || true

    # Create a shared log path that both the loop and monitors can find
    SHARED_LOG="$LOG_DIR/session-latest.jsonl"
    rm -f "$SHARED_LOG"
    touch "$SHARED_LOG"

    # Create tmux session
    tmux new-session -d -s orchestrate -x 220 -y 55

    # ─── Copy/paste support ──────────────────────────────────────────────
    # Enable mouse (scroll, click panes, resize)
    tmux set-option -t orchestrate -g mouse on
    # Large scrollback
    tmux set-option -t orchestrate history-limit 50000
    # Use vi mode for copy (Ctrl+b [ to enter, Space to start selection, Enter to copy)
    tmux set-option -t orchestrate mode-keys vi
    # macOS: copy to system clipboard on selection
    tmux set-option -t orchestrate set-clipboard on
    # Bind y in copy mode to also pipe to pbcopy (macOS) or xclip (Linux)
    tmux bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "pbcopy 2>/dev/null || xclip -selection clipboard 2>/dev/null" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "pbcopy 2>/dev/null || xclip -selection clipboard 2>/dev/null" 2>/dev/null || true
    # Mouse drag copies to clipboard too
    tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy 2>/dev/null || xclip -selection clipboard 2>/dev/null" 2>/dev/null || true

    # ─── Layout: 3 panes ─────────────────────────────────────────────────
    #
    #  ┌─────────────────────┬────────────────────────┐
    #  │                     │  STATE + PROGRESS      │
    #  │  MAIN LOOP          │  Verdict, tasks file,  │
    #  │  (orchestrate.sh)   │  recent progress       │
    #  │                     ├────────────────────────┤
    #  │                     │  ACTIVITY STREAM       │
    #  │                     │  Tool calls + text     │
    #  └─────────────────────┴────────────────────────┘

    # Main pane (0): run the loop
    ARGS="$PRD_FILE"
    [[ "$MAX_ITERATIONS" != "50" ]] && ARGS="$ARGS --max=$MAX_ITERATIONS"
    [[ "$MODEL" != "claude-opus-4-6" ]] && ARGS="$ARGS --model=$MODEL"
    [[ -n "$GOAL" ]] && ARGS="$ARGS --goal='$GOAL'"
    tmux send-keys -t orchestrate:0.0 "cd $(pwd) && ./orchestrate.sh $ARGS" Enter

    # Pane 1 (top-right): State + progress + tasks file hint
    tmux split-window -h -t orchestrate:0.0
    tmux send-keys -t orchestrate:0.1 "cd $(pwd) && while true; do echo ''; echo \"━━━ \$(date '+%H:%M:%S') ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"; echo '=== VERDICT ==='; cat orchestrate/state.md 2>/dev/null || echo 'No state yet'; echo ''; echo '=== TASKS ==='; echo 'File: $PRD_FILE (edit between iterations to add/change tasks)'; if [ -f '$PRD_FILE' ]; then grep -E '^\#\#\#|^\- \[' '$PRD_FILE' 2>/dev/null || echo 'No tasks yet'; else echo 'No PRD file yet — waiting for Phase 0...'; fi; echo ''; echo '=== RECENT PROGRESS ==='; tail -20 progress.md 2>/dev/null || echo 'No progress yet'; sleep 5; done" Enter

    # Pane 2 (bottom-right): Activity stream
    tmux split-window -v -t orchestrate:0.1
    tmux send-keys -t orchestrate:0.2 "cd $(pwd) && echo 'Waiting for log data...'; tail -f $SHARED_LOG | jq -r '
      (select(.type == \"assistant\") | .message.content[]? |
        if .type == \"tool_use\" then
          if .name == \"Read\" then \"📖 Read: \" + (.input.file_path // \"?\" | split(\"/\") | last)
          elif .name == \"Write\" then \"✏️  Write: \" + (.input.file_path // \"?\" | split(\"/\") | last)
          elif .name == \"Edit\" then \"🔧 Edit: \" + (.input.file_path // \"?\" | split(\"/\") | last)
          elif .name == \"Bash\" then \"💻 Bash: \" + (.input.command // \"?\" | .[0:80])
          elif .name == \"Grep\" then \"🔍 Grep: \" + (.input.pattern // \"?\") + \" in \" + (.input.path // \".\" | split(\"/\") | last)
          elif .name == \"Glob\" then \"📁 Glob: \" + (.input.pattern // \"?\")
          elif .name == \"Agent\" then \"🤖 Agent: \" + (.input.description // \"?\")
          elif .name == \"Skill\" then \"⚡ Skill: \" + (.input.skill // \"?\")
          else \"🔧 \" + .name
          end
        elif .type == \"text\" and (.text | length) > 0 then
          \"💬 \" + (.text | .[0:120] | gsub(\"\\n\"; \" \"))
        else empty
        end
      )
    ' 2>/dev/null" Enter

    # Focus main pane
    tmux select-pane -t orchestrate:0.0

    # Attach
    tmux attach -t orchestrate
    exit 0
  fi
  # If already in tmux, just continue running normally
fi

# ─── The Loop ────────────────────────────────────────────────────────────────
while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  ITERATION=$((ITERATION + 1))
  ITER_START=$(date +%s)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Iteration $ITERATION / $MAX_ITERATIONS"
  echo "  Time elapsed: $(( (ITER_START - START_TIME) / 60 )) minutes"
  echo "  $(date)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Run one orchestration cycle
  # The skill prompt tells Claude to use the PRD file we specify
  ITER_LOG="$LOG_DIR/iter-$ITERATION-$(date +%H%M%S).jsonl"
  SHARED_LOG="$LOG_DIR/session-latest.jsonl"

  # ─── Check for steering input from user ──────────────────────────────────
  STEER_MSG=""
  if [ -f "$STEER_FILE" ]; then
    STEER_MSG=$(cat "$STEER_FILE")
    rm -f "$STEER_FILE"
    echo ""
    echo "  🔀 Steering input received: $STEER_MSG"
    echo ""
  fi

  # Build the prompt — goal-driven mode on first iteration if no PRD exists yet
  # IMPORTANT: Always include fallback instructions to read SKILL.md directly,
  # because claude -p doesn't always load custom skills reliably.
  SKILL_FALLBACK="If the /orchestrate skill is not available, read .claude/skills/orchestrate/SKILL.md and follow its instructions exactly as your protocol."

  CURRENT_DATETIME="$(date '+%Y-%m-%d %H:%M')"
  DATETIME_CONTEXT="Current date/time: $CURRENT_DATETIME."

  if [ -n "$GOAL" ] && [ ! -f "$PRD_FILE" ]; then
    PROMPT="$DATETIME_CONTEXT Run /orchestrate in goal-driven mode. GOAL: '$GOAL'. PRD file: '$PRD_FILE'. The PRD file does not exist yet — you must run Phase 0 (DECOMPOSE) to create it from the goal. $SKILL_FALLBACK"
  elif [ -n "$GOAL" ]; then
    PROMPT="$DATETIME_CONTEXT Run /orchestrate using '$PRD_FILE' as the PRD file. This is a goal-driven session. GOAL: '$GOAL'. The PRD was auto-generated — if you encounter VERDICT: REPLAN, regenerate the PRD. $SKILL_FALLBACK"
  else
    PROMPT="$DATETIME_CONTEXT Run /orchestrate using '$PRD_FILE' as the PRD file (instead of the default prd.md). Read that file for the task list. $SKILL_FALLBACK"
  fi

  # Prepend steering message if present
  if [ -n "$STEER_MSG" ]; then
    PROMPT="HUMAN STEERING (priority instruction from the user — follow this guidance for this iteration): $STEER_MSG

$PROMPT"
  fi

  # Run claude and tee to logs. Capture exit code separately to avoid pipe hangs.
  claude -p "$PROMPT" \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --output-format stream-json \
    --verbose 2>&1 \
    | tee -a "$SESSION_LOG" "$ITER_LOG" "$SHARED_LOG" \
    | jq -rj 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null \
    || true

  RESULT="done"

  ITER_END=$(date +%s)
  ITER_DURATION=$(( ITER_END - ITER_START ))

  echo ""
  echo "  ⏱  Iteration $ITERATION took ${ITER_DURATION}s"

  # ─── Check for manual stop signal ────────────────────────────────────────
  if [ -f "$STOP_FILE" ]; then
    rm -f "$STOP_FILE"
    echo ""
    echo "  ⚠  Stop signal detected (/tmp/orchestrate-stop)"
    graceful_shutdown
  fi

  # ─── Check for HALT verdict ──────────────────────────────────────────────
  if [ -f "$STATE_FILE" ] && grep -q "VERDICT: HALT" "$STATE_FILE" 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  HALTED                                                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    grep "REASON:" "$STATE_FILE" | head -1 | sed 's/^/║  /'
    echo ""
    echo "║  Total iterations: $ITERATION"
    echo "║  Total time: $(( (ITER_END - START_TIME) / 60 )) minutes"
    echo "║  Log: $SESSION_LOG"
    echo "╚══════════════════════════════════════════════════════════╝"

    # ─── Archive completed runs to history/ ───────────────────────────────
    # If HALT reason is "all tasks complete", move PRD + state files to history/
    # so the next run with the same goal starts fresh (Phase 0 creates a new PRD)
    if grep -qi "all.*tasks\?\s*complete\|no remaining work" "$STATE_FILE" 2>/dev/null; then
      ARCHIVE_DIR="history"
      ARCHIVE_TS=$(date +%Y%m%d-%H%M%S)
      mkdir -p "$ARCHIVE_DIR"

      echo ""
      echo "  📦 Archiving completed run to $ARCHIVE_DIR/..."

      # Move PRD file
      if [ -f "$PRD_FILE" ]; then
        mv "$PRD_FILE" "$ARCHIVE_DIR/$(basename "$PRD_FILE" | sed "s/\.\([^.]*\)$/-${ARCHIVE_TS}.\1/")"
        echo "     ✓ $PRD_FILE"
      fi

      # Move orchestrate state and plan
      if [ -f "orchestrate/state.md" ]; then
        mv "orchestrate/state.md" "$ARCHIVE_DIR/orchestrate-state-${ARCHIVE_TS}.md"
        echo "     ✓ orchestrate/state.md"
      fi
      if [ -f "orchestrate/plan.md" ]; then
        mv "orchestrate/plan.md" "$ARCHIVE_DIR/orchestrate-plan-${ARCHIVE_TS}.md"
        echo "     ✓ orchestrate/plan.md"
      fi

      echo "  📦 Archive complete. Next run with same goal will start fresh."
    fi

    # macOS notification
    rm -f "$STOP_FILE" "$STEER_FILE"
    osascript -e 'display notification "Orchestrate loop halted after '"$ITERATION"' iterations" with title "Orchestrate"' 2>/dev/null || true

    exit 0
  fi

  # ─── Check for REPLAN verdict (goal-driven mode only) ───────────────────
  if [ -n "$GOAL" ] && [ -f "$STATE_FILE" ] && grep -q "VERDICT: REPLAN" "$STATE_FILE" 2>/dev/null; then
    REPLAN_COUNT=$((${REPLAN_COUNT:-0} + 1))
    if [ "$REPLAN_COUNT" -ge 3 ]; then
      echo ""
      echo "  ✗  Max replans ($REPLAN_COUNT) reached. Halting."
      exit 1
    fi
    echo ""
    echo "  ↻  REPLAN requested (attempt $REPLAN_COUNT/3). Regenerating PRD on next iteration..."
    # Delete the PRD so Phase 0 runs again on next iteration
    rm -f "$PRD_FILE"
    sleep $COOLDOWN_SECONDS
    continue
  fi

  # ─── Check for errors (scan iteration log for failures) ─────────────────
  if grep -qi "error.*failed\|ECONNREFUSED\|SIGTERM\|panic" "$ITER_LOG" 2>/dev/null && \
     ! [ -f "$STATE_FILE" ]; then
    echo ""
    echo "  ✗  Possible error in iteration $ITERATION. Retrying after cooldown..."
    sleep $((COOLDOWN_SECONDS * 3))
    continue
  fi

  # ─── Brief pause before next iteration ──────────────────────────────────
  echo "  ✓  Cycle complete. Next iteration in ${COOLDOWN_SECONDS}s..."
  sleep $COOLDOWN_SECONDS
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  MAX ITERATIONS REACHED ($MAX_ITERATIONS)              ║"
echo "║  Total time: $(( ($(date +%s) - START_TIME) / 60 )) minutes"
echo "║  Log: $SESSION_LOG"
echo "╚══════════════════════════════════════════════════════════╝"

rm -f "$STOP_FILE" "$STEER_FILE"
osascript -e 'display notification "Orchestrate loop finished after '"$MAX_ITERATIONS"' iterations" with title "Orchestrate"' 2>/dev/null || true
