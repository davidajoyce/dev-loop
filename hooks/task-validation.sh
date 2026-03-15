#!/bin/bash
# TaskCompleted hook — validates work before allowing a task to be marked done
#
# Exit 0 = task can complete
# Exit 2 = task stays in progress (teammate gets the stderr message as feedback)

INPUT=$(cat)
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // "unknown"')

echo "Validating task: $TASK_SUBJECT" >&2

# Check if there are uncommitted changes (teammate should commit their work)
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  # No changes — either already committed or nothing was done
  true
else
  echo "You have uncommitted changes. Commit your work before marking the task complete." >&2
  exit 2
fi

# If npm test exists, run it
if [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  if ! npm test --silent 2>&1; then
    echo "Tests are failing. Fix tests before marking task '$TASK_SUBJECT' complete." >&2
    exit 2
  fi
fi

exit 0
