#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Determine Target Branch ---
TARGET_BRANCH=$INPUT_TARGET_BRANCH
if [[ -z "$TARGET_BRANCH" ]]; then
  echo "Target branch not provided. Querying for the repository's default branch..."
  # Use the GitHub CLI to get repository info and extract the default branch
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
  echo "Source branch not provided. Using the current branch from GITHUB_REF_NAME..."
  # GITHUB_REF_NAME contains the short name of the branch or tag
  SOURCE_BRANCH=$GITHUB_REF_NAME
  if [[ -z "$SOURCE_BRANCH" ]]; then
    echo "::error::Could not determine the current branch name from GITHUB_REF_NAME."
    exit 1
  fi
  echo "Current branch is '$SOURCE_BRANCH'."
else
  echo "Using provided source branch: '$SOURCE_BRANCH'."
fi

# --- 3. Check for Existing Open PR ---
echo "Checking for existing open PR from '$SOURCE_BRANCH' to '$TARGET_BRANCH'..."
EXISTING_PR_URL=$(gh pr list \
  --state open \
  --head "$SOURCE_BRANCH" \
  --base "$TARGET_BRANCH" \
  --json url \
  --jq '.[0].url' \
  || echo "") # Use '|| echo ""' to prevent script exit if no PR is found

# --- 4. Create PR or Use Existing ---
PR_URL=""
PR_CREATED="false"

if [[ -n "$EXISTING_PR_URL" ]]; then
  # An existing PR was found
  echo "Found existing PR: $EXISTING_PR_URL"
  PR_URL=$EXISTING_PR_URL
  PR_CREATED="false"
else
  # No existing PR found, create a new one
  echo "No existing PR found. Creating a new one..."
  
  # Determine the PR subject
  PR_SUBJECT=$INPUT_PR_SUBJECT
  if [[ -z "$PR_SUBJECT" ]]; then
    PR_SUBJECT="[ATTENTION] Rebaselining needed from [${SOURCE_BRANCH}] to [${TARGET_BRANCH}]"
  fi
  echo "Using PR subject: '$PR_SUBJECT'"

  # Create the pull request using the GitHub CLI
  # The output of 'gh pr create' is the URL of the newly created PR
  PR_URL=$(gh pr create \
    --base "$TARGET_BRANCH" \
    --head "$SOURCE_BRANCH" \
    --title "$PR_SUBJECT" \
    --body "This PR was automatically created by the 'create-pr' GitHub Action.")
  
  if [[ -n "$PR_URL" ]]; then
    echo "Successfully created new PR: $PR_URL"
    PR_CREATED="true"
  else
    echo "::error::Failed to create a new pull request."
    exit 1
  fi
fi

# --- 5. Set Outputs ---
echo "Setting outputs..."
echo "pr-url=$PR_URL" >> $GITHUB_OUTPUT
echo "pr-created=$PR_CREATED" >> $GITHUB_OUTPUT

echo "Action finished successfully."

