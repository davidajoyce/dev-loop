---
name: browser-debug
description: Test and debug your web app in a real browser using agent-browser. Use when asked to "test the app", "check how it looks", "verify the UI", "browser test", "debug the frontend", "see if it works", "visual test", "check the flow", or any task requiring browser-based verification. Customize the interaction map below for your product.
allowed-tools: Bash(npx agent-browser:*), Bash(agent-browser:*), Bash(mkdir:*), Bash(cat:*)
---

# Browser Debug Skill (Template)

Test and debug your web app in a real browser using [agent-browser](https://github.com/vercel-labs/agent-browser). This skill provides a framework for pre-mapping your app's pages, interactive elements, and core flows so testing is fast and deterministic.

**To use this skill:** Copy it into your project at `.claude/skills/browser-debug/SKILL.md` and customize the interaction maps below for your product.

## Setup

```bash
npm install agent-browser
npx agent-browser install  # Downloads Chrome for Testing
```

## Quick Start

```bash
# Start a named session (reusable across commands)
npx agent-browser --session myapp open http://localhost:3000
npx agent-browser --session myapp wait --load networkidle
npx agent-browser --session myapp snapshot -i
```

Always use `--session myapp` for consistency. Always `snapshot -i` before interacting.

## Core Workflow

Every browser test follows this pattern:

1. **Navigate**: `npx agent-browser --session myapp open <url>`
2. **Snapshot**: `npx agent-browser --session myapp snapshot -i` (get element refs like `@e1`, `@e2`)
3. **Interact**: Use refs to click, fill, select
4. **Re-snapshot**: After navigation or DOM changes, get fresh refs
5. **Verify**: Check for expected elements, take screenshots, check console errors

## Page Interaction Map (CUSTOMIZE THIS)

Map out your app's pages, their URLs, and interactive elements. This eliminates trial and error — the agent knows exactly what to expect on each page.

### Example: Landing Page (`/`)

```
Interactive elements:
- link "Sign in" -> navigates to /login
- link "Get Started" -> navigates to /signup
- heading "Your App Tagline"
```

```bash
npx agent-browser --session myapp open http://localhost:3000
npx agent-browser --session myapp snapshot -i
# Typical refs:
#   @e1 = "Sign in" link
#   @e2 = "Get Started" CTA
```

### Example: Login Page (`/login`)

```
Interactive elements:
- textbox "Email" [required]
- textbox "Password" [required]
- button "Sign in" [disabled until fields filled]
```

```bash
npx agent-browser --session myapp fill @e1 "test@example.com"
npx agent-browser --session myapp fill @e2 "password123"
npx agent-browser --session myapp click @e3
npx agent-browser --session myapp wait --url "**/dashboard"
```

## Test Data IDs (Reliable Selectors)

Use `data-testid` attributes for reliable element targeting. Map them here:

| testid | Page | Element |
|--------|------|---------|
| `login-form` | /login | Login form container |
| `submit-btn` | /login | Submit button |
| `nav-menu` | all | Navigation menu |

## Test Flows (CUSTOMIZE THESE)

### Flow 1: Full User Journey

```bash
mkdir -p ./test-results

# 1. Landing page
npx agent-browser --session myapp open http://localhost:3000
npx agent-browser --session myapp wait --load networkidle
npx agent-browser --session myapp snapshot -i
npx agent-browser --session myapp screenshot ./test-results/01-landing.png

# 2. Login
npx agent-browser --session myapp click @e1  # Navigate to login
npx agent-browser --session myapp wait --load networkidle
npx agent-browser --session myapp snapshot -i
npx agent-browser --session myapp fill @e2 "test@example.com"
npx agent-browser --session myapp click @e3  # Submit
npx agent-browser --session myapp wait --url "**/dashboard"
npx agent-browser --session myapp screenshot ./test-results/02-dashboard.png
```

### Flow 2: Visual Regression

```bash
# Take baseline
npx agent-browser --session myapp screenshot ./test-results/baseline.png

# ... make code changes ...

# Compare
npx agent-browser --session myapp open http://localhost:3000
npx agent-browser --session myapp wait --load networkidle
npx agent-browser --session myapp diff screenshot --baseline ./test-results/baseline.png
```

### Flow 3: Mobile Responsive

```bash
npx agent-browser --session myapp set viewport 375 812
npx agent-browser --session myapp open http://localhost:3000
npx agent-browser --session myapp wait --load networkidle
npx agent-browser --session myapp screenshot ./test-results/mobile.png

# Reset
npx agent-browser --session myapp set viewport 1280 720
```

## Debugging

```bash
# Check for JS errors
npx agent-browser --session myapp errors

# Check console output
npx agent-browser --session myapp console

# Get current URL
npx agent-browser --session myapp get url

# Annotated screenshot (shows element numbers)
npx agent-browser --session myapp screenshot --annotate ./test-results/annotated.png

# Wait for specific text
npx agent-browser --session myapp wait --text "Welcome"
```

## Authentication

```bash
# Option 1: Grab auth from your running Chrome
npx agent-browser --auto-connect state save ./auth.json
npx agent-browser --state ./auth.json open http://localhost:3000/dashboard

# Option 2: Persistent session (auto-saves cookies)
npx agent-browser --session-name myapp open http://localhost:3000/login
# ... login flow ...
npx agent-browser close
# Next time: state auto-restored
npx agent-browser --session-name myapp open http://localhost:3000/dashboard
```

## Cleanup

Always close the session when done:

```bash
npx agent-browser --session myapp close
```

## How to Customize This Skill

1. Replace `myapp` session name with your project name
2. Map out every page in your app under "Page Interaction Map"
3. Add your `data-testid` attributes to the selectors table
4. Write test flows for your core user journeys
5. Add any API endpoints that are useful for verifying behavior
