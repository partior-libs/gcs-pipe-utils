#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "=============================================="
echo " Back-Merge PR Detection"
echo "=============================================="

# --- 1. Check if triggered by a pull_request event ---
echo ""
echo "--- Step 1: Checking trigger event ---"
echo "GITHUB_EVENT_NAME: '${GITHUB_EVENT_NAME}'"

echo "trigger-event=${GITHUB_EVENT_NAME}" >> "$GITHUB_OUTPUT"

if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "pull_request_target" ]]; then
  echo "Workflow was NOT triggered by a pull_request event (event: '${GITHUB_EVENT_NAME}')."
  echo "Setting is-back-merge-pr=false"
  echo "is-back-merge-pr=false" >> "$GITHUB_OUTPUT"
  echo "pr-target-branch=" >> "$GITHUB_OUTPUT"
  echo "pr-title=" >> "$GITHUB_OUTPUT"
  echo ""
  echo "Action finished. Not a PR-triggered run."
  exit 0
fi

echo "✓ Workflow was triggered by a pull_request event."

# --- 2. Extract PR details from the event payload ---
echo ""
echo "--- Step 2: Extracting PR details from event payload ---"
echo "GITHUB_EVENT_PATH: '${GITHUB_EVENT_PATH}'"

if [[ ! -f "$GITHUB_EVENT_PATH" ]]; then
  echo "::error::GITHUB_EVENT_PATH file not found at '${GITHUB_EVENT_PATH}'."
  echo "is-back-merge-pr=false" >> "$GITHUB_OUTPUT"
  echo "pr-target-branch=" >> "$GITHUB_OUTPUT"
  echo "pr-title=" >> "$GITHUB_OUTPUT"
  exit 1
fi

PR_TARGET_BRANCH=$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH")
PR_TITLE=$(jq -r '.pull_request.title // empty' "$GITHUB_EVENT_PATH")
PR_NUMBER=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
PR_SOURCE_BRANCH=$(jq -r '.pull_request.head.ref // empty' "$GITHUB_EVENT_PATH")

echo "PR Number: #${PR_NUMBER}"
echo "PR Title: '${PR_TITLE}'"
echo "PR Source Branch (head): '${PR_SOURCE_BRANCH}'"
echo "PR Target Branch (base): '${PR_TARGET_BRANCH}'"

echo "pr-target-branch=${PR_TARGET_BRANCH}" >> "$GITHUB_OUTPUT"
echo "pr-title=${PR_TITLE}" >> "$GITHUB_OUTPUT"

if [[ -z "$PR_TARGET_BRANCH" || -z "$PR_TITLE" ]]; then
  echo "::error::Could not extract PR target branch or title from event payload."
  echo "is-back-merge-pr=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

# --- 3. Determine the repository's default branch ---
echo ""
echo "--- Step 3: Determining repository default branch ---"

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')

if [[ -z "$DEFAULT_BRANCH" ]]; then
  echo "::error::Could not determine the default branch for the repository."
  echo "is-back-merge-pr=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

echo "Repository default branch: '${DEFAULT_BRANCH}'"

# --- 4. Check if PR targets the default branch ---
echo ""
echo "--- Step 4: Checking if PR targets the default branch ---"
echo "Comparing PR target branch '${PR_TARGET_BRANCH}' with default branch '${DEFAULT_BRANCH}'..."

if [[ "$PR_TARGET_BRANCH" != "$DEFAULT_BRANCH" ]]; then
  echo "PR does NOT target the default branch."
  echo "  PR target: '${PR_TARGET_BRANCH}'"
  echo "  Default:   '${DEFAULT_BRANCH}'"
  echo "Setting is-back-merge-pr=false"
  echo "is-back-merge-pr=false" >> "$GITHUB_OUTPUT"
  echo ""
  echo "Action finished. PR does not target default branch."
  exit 0
fi

echo "✓ PR targets the default branch '${DEFAULT_BRANCH}'."

# --- 5. Check if PR title contains [Back-merge] ---
echo ""
echo "--- Step 5: Checking PR title for '[Back-merge]' pattern ---"
echo "PR Title: '${PR_TITLE}'"

IS_BACK_MERGE="false"
if echo "$PR_TITLE" | grep -iq "\[back-merge\]"; then
  IS_BACK_MERGE="true"
  echo "✓ PR title contains '[Back-merge]' (case insensitive match)."
else
  echo "✗ PR title does NOT contain '[Back-merge]'."
fi

# --- 6. Set final output ---
echo ""
echo "--- Result ---"
echo "is-back-merge-pr=${IS_BACK_MERGE}"
echo "is-back-merge-pr=${IS_BACK_MERGE}" >> "$GITHUB_OUTPUT"

echo ""
echo "=============================================="
echo " Summary"
echo "=============================================="
echo "  Trigger Event:    ${GITHUB_EVENT_NAME}"
echo "  PR Number:        #${PR_NUMBER}"
echo "  PR Title:         ${PR_TITLE}"
echo "  PR Source Branch: ${PR_SOURCE_BRANCH}"
echo "  PR Target Branch: ${PR_TARGET_BRANCH}"
echo "  Default Branch:   ${DEFAULT_BRANCH}"
echo "  Is Back-Merge PR: ${IS_BACK_MERGE}"
echo "=============================================="
echo ""
echo "Action finished successfully."
