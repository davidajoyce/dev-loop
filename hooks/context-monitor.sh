#!/bin/bash
# PostToolUse hook — monitors context window usage and warns Claude to wrap up
#
# Exit 0 = continue normally
# Stderr message = feedback shown to Claude

INPUT=$(cat)

# Extract context usage percentage if available
CONTEXT_USED=$(echo "$INPUT" | jq -r '.context_window.used_percent // empty' 2>/dev/null)
TOOL_COUNT=$(echo "$INPUT" | jq -r '.tool_use_count // empty' 2>/dev/null)

# Fallback: count tool uses as a proxy for context consumption
if [ -z "$CONTEXT_USED" ] && [ -n "$TOOL_COUNT" ]; then
  if [ "$TOOL_COUNT" -gt 200 ]; then
    echo "CONTEXT WARNING: $TOOL_COUNT tool calls. STOP NOW — commit work, write verdict, end cycle." >&2
    exit 0
  elif [ "$TOOL_COUNT" -gt 150 ]; then
    echo "CONTEXT CAUTION: $TOOL_COUNT tool calls. Start wrapping up — move to JUDGE phase soon." >&2
    exit 0
  fi
fi

# If we have actual context percentage — use Anthropic's recommended thresholds
# Context degrades at ~60% fill, well before hitting limits
if [ -n "$CONTEXT_USED" ]; then
  PCT=$(echo "$CONTEXT_USED" | awk '{printf "%d", $1}')

  if [ "$PCT" -ge 75 ]; then
    echo "CRITICAL: Context at ${PCT}%. STOP — commit work, write verdict, end cycle NOW." >&2
    exit 0
  elif [ "$PCT" -ge 60 ]; then
    echo "WARNING: Context at ${PCT}%. Wrap up — delegate remaining work to subagents or move to JUDGE phase." >&2
    exit 0
  fi
fi

exit 0
