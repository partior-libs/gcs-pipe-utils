#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Determine Target Branch ---
TARGET_BRANCH=$INPUT_TARGET_BRANCH
if [[ -z "$TARGET_BRANCH" ]]; then
  echo "Target branch not provided. Querying for the repository's default branch..."
  TARGET_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
  if [[ -z "$TARGET_BRANCH" ]]; then
    echo "::error::Could not determine default branch for the repository."
    exit 1
  fi
  echo "Default branch is '$TARGET_BRANCH'."
else
  echo "Using provided target branch: '$TARGET_BRANCH'."
fi

# --- 2. Determine Source Branch ---
SOURCE_BRANCH=$INPUT_SOURCE_BRANCH
if [[ -z "$SOURCE_BRANCH" ]]; then
  echo "Source branch input not provided. Determining from environment variables..."
  if [[ -n "$GITHUB_HEAD_REF" ]]; then
    # This variable is set for pull_request events and contains the source branch name.
    echo "Using source branch from GITHUB_HEAD_REF (pull request event)."
    SOURCE_BRANCH=$GITHUB_HEAD_REF
  else
    # This is the fallback for push events.
    echo "Using source branch from GITHUB_REF_NAME (push event)."
    SOURCE_BRANCH=$GITHUB_REF_NAME
  fi

  if [[ -z "$SOURCE_BRANCH" ]]; then
    echo "::error::Could not determine the source branch name from environment variables (GITHUB_HEAD_REF or GITHUB_REF_NAME)."
    exit 1
  fi
  echo "Determined source branch is '$SOURCE_BRANCH'."
else
  echo "Using provided source branch: '$SOURCE_BRANCH'."
fi

# --- 3. Check for Existing Open PR ---
echo "Checking for existing open PR from '$SOURCE_BRANCH' to '$TARGET_BRANCH'..."
# Use --limit to fetch up to 1000 PRs to handle pagination.
# It's highly unlikely to have more than one open PR for the same head/base,
# but this makes the check more robust.
EXISTING_PR_URL=$(gh pr list \
  --state open \
  --head "$SOURCE_BRANCH" \
  --base "$TARGET_BRANCH" \
  --json url \
  --limit 1000 \
  --jq '.[0].url' \
  || echo "")

# --- 4. Create PR or Use Existing ---
PR_URL=""
PR_CREATED="false"

if [[ -n "$EXISTING_PR_URL" ]]; then
  echo "Found existing PR: $EXISTING_PR_URL"
  PR_URL=$EXISTING_PR_URL
  PR_CREATED="false"
else
  echo "No existing PR found. Attempting to create a new one..."
  
  PR_SUBJECT=$INPUT_PR_SUBJECT
  if [[ -z "$PR_SUBJECT" ]]; then
    PR_SUBJECT="[Back-merge] ${SOURCE_BRANCH} ⮕ ${TARGET_BRANCH}"
  fi
  echo "Using PR subject: '$PR_SUBJECT'"

  # Construct the PR body with a link to the GitHub Actions run and R&R
  WORKFLOW_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  PR_BODY="### Back-Merge Pull Request

This PR was automatically created to back-merge changes from the \`$SOURCE_BRANCH\` branch into the \`$TARGET_BRANCH\` branch.

**What is a back-merge?**
A back-merge ensures that critical changes (like hotfixes) made on a separate maintenance branch are integrated back into the main development line. This prevents the changes from being lost in future releases.

**Roles & Responsibilities (R&R):**
> **Developer Leads / Component Owners** are responsible for reviewing, approving, and merging this pull request at the appropriate time to ensure codebase synchronization.

---
*This PR was automatically created from the GitHub Actions job run: [$WORKFLOW_URL]($WORKFLOW_URL)*"

  # Temporarily disable exit on error to gracefully handle the "no commits" case
  set +e
  PR_CREATE_OUTPUT=$(gh pr create \
    --base "$TARGET_BRANCH" \
    --head "$SOURCE_BRANCH" \
    --title "$PR_SUBJECT" \
    --body "$PR_BODY" 2>&1)
  # Capture the exit code of the gh command
  GH_EXIT_CODE=$?
  # Re-enable exit on error
  set -e

  # Check the result of the command
  if [ $GH_EXIT_CODE -eq 0 ]; then
    # Success: The command output is the URL
    PR_URL=$PR_CREATE_OUTPUT
    PR_CREATED="true"
    echo "Successfully created new PR: $PR_URL"
  else
    # Failure: Check if it's the specific "no commits" error
    if [[ "$PR_CREATE_OUTPUT" == *"No commits between"* ]]; then
      echo "No new commits found between '$SOURCE_BRANCH' and '$TARGET_BRANCH'. No PR will be created."
      PR_URL=""
      PR_CREATED="false"
    else
      # It's a different, real error
      echo "::error::Failed to create pull request: $PR_CREATE_OUTPUT"
      exit 1
    fi
  fi
fi

# --- 5. Set Outputs ---
echo "Setting outputs..."
echo "pr-url=$PR_URL" >> $GITHUB_OUTPUT
echo "pr-created=$PR_CREATED" >> $GITHUB_OUTPUT

echo "Action finished successfully."