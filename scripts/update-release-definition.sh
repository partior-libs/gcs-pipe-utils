#!/bin/bash
set -euo pipefail

RELEASE_REPO="${RELEASE_REPO:-}"
SOURCE_BRANCH="${SOURCE_BRANCH:-}"
NEW_VERSION="${NEW_VERSION:-}"
COMPONENT_NAME="${COMPONENT_NAME:-}"
COMPONENT_TYPE="${COMPONENT_TYPE:-}"
ARTIFACT_BASE_NAME="${ARTIFACT_BASE_NAME:-}"
STRATEGY_ENABLED="${STRATEGY_ENABLED:-false}"
SMART_FILTER="${SMART_FILTER:-false}"
CREATE_BRANCH="${CREATE_BRANCH:-false}"
HOTFIX_SUFFIX="${HOTFIX_SUFFIX:-}"
GH_TOKEN="${GH_TOKEN:-}"

echo "[INFO] Cloning release repo..."
: "${RELEASE_REPO:=partior-quorum/deploy-orchestro}"

echo "Cloning release repo: $RELEASE_REPO ..."
git clone "https://x-access-token:${GH_TOKEN}@github.com/${RELEASE_REPO}.git" release-repo
cd release-repo

TARGET_BRANCH="$SOURCE_BRANCH"
if [[ "$STRATEGY_ENABLED" != "true" ]]; then
  echo "[INFO] Branching strategy disabled, using source branch: $TARGET_BRANCH"
else
  if [[ "$SMART_FILTER" == "true" ]]; then
    BRANCH_PREFIX=$(echo "$SOURCE_BRANCH" | sed 's/\.[^.]*$//')
    REMOTE_REPO_URL="https://x-access-token:${GH_TOKEN}@github.com/${RELEASE_REPO}.git"
    LATEST_HOTFIX_BRANCH=$(git ls-remote --heads "$REMOTE_REPO_URL" \
      | grep "refs/heads/$BRANCH_PREFIX" \
      | awk '{print $2}' | sed 's#refs/heads/##' | sort -V | tail -n 1)

    if [[ -n "$LATEST_HOTFIX_BRANCH" ]]; then
      TARGET_BRANCH="$LATEST_HOTFIX_BRANCH"
    elif [[ "$CREATE_BRANCH" == "true" ]]; then
      TARGET_BRANCH="$BRANCH_PREFIX$HOTFIX_SUFFIX"
    else
      echo "[ERROR] No matching hotfix branch found and branch creation disabled."
      exit 1
    fi
  fi
fi

echo "[INFO] Using target branch: $TARGET_BRANCH"
git checkout "$TARGET_BRANCH" || {
  if [[ "$CREATE_BRANCH" == "true" ]]; then
    git checkout -b "$TARGET_BRANCH"
  else
    echo "[ERROR] Target branch $TARGET_BRANCH not found."
    exit 1
  fi
}

DEFINITION_FILE="release-workflow/release-definition.yaml"

# UPDATED FUNCTION
# This function now uses `awk` to perform a surgical text replacement.
# This avoids the common issue of YAML parsers (like yq) reformatting
# the entire file, thus guaranteeing a minimal git diff.
update_release_def() {
  local file="$1"
  local type="$2" # Note: component type is not used by awk, but kept for signature consistency
  local name="$3"
  local version="$4"

  echo "[INFO] Updating $type.$name → $version in $file"
  awk -i inplace -v comp_name="$name" -v new_ver="$version" '
    /name:/ {
      if ($0 ~ "name: *\"?" comp_name "\"?" ) {
        in_correct_component = 1
      } else {
        in_correct_component = 0
      }
    }

    # If we are in the correct component block and find the version line...
    (in_correct_component && /version:/) {
      match($0, /^([ \t]+)version:/, m)
      print m[1] "version: \"" new_ver "\""
      next
    }

    # Print every line by default
    { print }
  ' "$file"
}


# Perform the update
update_release_def "$DEFINITION_FILE" "$COMPONENT_TYPE" "$COMPONENT_NAME" "$NEW_VERSION"

# Check if anything changed
if git diff --quiet; then
  echo "[INFO] No changes detected in $DEFINITION_FILE. Skipping commit."
  exit 0
fi

git config user.name github-actions
git config user.email github-actions@github.com

git add "$DEFINITION_FILE"
git commit -m "[BOT] CI: Update $COMPONENT_TYPE/$COMPONENT_NAME to $NEW_VERSION"
git push origin "$TARGET_BRANCH"

echo "[INFO] Release definition update completed successfully."
