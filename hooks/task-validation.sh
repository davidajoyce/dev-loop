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

# Auto-detect and run the project's test suite
TEST_RAN=false

if [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
  if ! make test 2>&1; then
    echo "Tests are failing (make test). Fix tests before marking task '$TASK_SUBJECT' complete." >&2
    exit 2
  fi
  TEST_RAN=true
elif [ -f "Cargo.toml" ]; then
  if ! cargo test 2>&1; then
    echo "Tests are failing (cargo test). Fix tests before marking task '$TASK_SUBJECT' complete." >&2
    exit 2
  fi
  TEST_RAN=true
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "pytest.ini" ]; then
  if command -v pytest &>/dev/null; then
    if ! pytest 2>&1; then
      echo "Tests are failing (pytest). Fix tests before marking task '$TASK_SUBJECT' complete." >&2
      exit 2
    fi
    TEST_RAN=true
  fi
elif [ -f "go.mod" ]; then
  if ! go test ./... 2>&1; then
    echo "Tests are failing (go test). Fix tests before marking task '$TASK_SUBJECT' complete." >&2
    exit 2
  fi
  TEST_RAN=true
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  if ! npm test --silent 2>&1; then
    echo "Tests are failing (npm test). Fix tests before marking task '$TASK_SUBJECT' complete." >&2
    exit 2
  fi
  TEST_RAN=true
fi

exit 0
