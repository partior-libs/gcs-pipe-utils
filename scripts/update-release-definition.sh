#!/bin/bash
set -e

cd release-repo

TARGET_BRANCH="$SOURCE_BRANCH"

if [[ "$STRATEGY_ENABLED" != "true" ]]; then
  echo "Target branching strategy disabled. Skipping."
  exit 0
fi

if [[ "$SMART_FILTER" == "true" ]]; then
  BRANCH_PREFIX=$(echo "$SOURCE_BRANCH" | sed 's/\.[^.]*$//')
  REMOTE_REPO_URL="https://x-access-token:${GH_TOKEN}@github.com/partior-quorum/deploy-orchestro.git"

  echo "Looking for latest hotfix branch with prefix: $BRANCH_PREFIX"
  LATEST_HOTFIX_BRANCH=$(git ls-remote --heads "$REMOTE_REPO_URL" \
    | grep "refs/heads/$BRANCH_PREFIX" \
    | awk '{print $2}' \
    | sed 's#refs/heads/##' \
    | sort -V | tail -n 1)

  if [[ -n "$LATEST_HOTFIX_BRANCH" ]]; then
    TARGET_BRANCH="$LATEST_HOTFIX_BRANCH"
  elif [[ "$CREATE_BRANCH" == "true" ]]; then
    TARGET_BRANCH="$BRANCH_PREFIX$HOTFIX_SUFFIX"
  else
    echo "::error:: No matching hotfix branch found and creation disabled."
    exit 1
  fi
fi

echo "Checking out target branch: $TARGET_BRANCH"
if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  git checkout "$TARGET_BRANCH"
else
  git checkout -b "$TARGET_BRANCH"
fi

git config user.name github-actions
git config user.email github-actions@github.com

DEFINITION_FILE="release-workflow/release-definition.yaml"
YAML_PATH_UPDATE="(.base.${COMPONENT_TYPE}[] | select(.name == \"$COMPONENT_NAME\")).version"

echo "Updating component: $COMPONENT_NAME under type: $COMPONENT_TYPE to version: $NEW_VERSION"

# Check if component exists
EXISTS=$(yq e ".base.${COMPONENT_TYPE}[] | select(.name == \"$COMPONENT_NAME\") | length" "$DEFINITION_FILE")

if [[ -n "$EXISTS" && "$EXISTS" -gt 0 ]]; then
  yq -i "$YAML_PATH_UPDATE = \"$NEW_VERSION\"" "$DEFINITION_FILE"
else
  echo "Component not found. Appending..."
  yq -i ".base.${COMPONENT_TYPE} += [{\"name\": \"$COMPONENT_NAME\", \"version\": \"$NEW_VERSION\"}]" "$DEFINITION_FILE"
fi

if git diff --quiet; then
  echo "No changes to commit."
  exit 0
fi

git add "$DEFINITION_FILE"
git commit -m "[BOT] CI: Update $ARTIFACT_BASE_NAME ($COMPONENT_NAME) to $NEW_VERSION"
git push --set-upstream origin "$TARGET_BRANCH"

echo "Release definition updated successfully."
