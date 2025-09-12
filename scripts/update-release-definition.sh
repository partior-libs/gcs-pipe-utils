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
      | awk '{print $2}' | sed 's#refs/heads/##' | sort -V | tail -n 1 || true)

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

update_release_def() {
  local file="$1"
  local type="$2"
  local name="$3"
  local base_version="$4" # This is the raw version like "0.0.0"
  local final_version    # This will be the fully constructed version string

  
  if [[ "$type" == "commonconfig" ]]; then
    local prefix="${name#pctl-}"
    final_version="${prefix}-${base_version}"
    echo "[INFO] Type is 'commonconfig'. Constructed prefixed version: $final_version"
  else
    final_version="$base_version"
    echo "[INFO] Type is '$type'. Using version as-is: $final_version"
  fi

  local tmp_file="${file}.tmp"
  echo "[INFO] Updating $type.$name → $final_version in $file"

  awk -v comp_name="$name" -v new_ver="$final_version" '
    # Detect top-level keys (lines that do not start with whitespace).
    /^[^ \t]/ {
      # Check if this top-level key is "base:". If so, set a flag.
      if ($0 ~ /^base:/) {
        in_base_section = 1
      } else {
        # If it is any other top-level key, unset the flag.
        in_base_section = 0
      }
    }
    # only runs if we are inside the base section
    (in_base_section && /name:/) {
      if ($0 ~ "name: *\"?" comp_name "\"?" ) {
        in_correct_component = 1
      } else {
        in_correct_component = 0
      }
    }
    (in_base_section && in_correct_component && /version:/) {
      indent = $0
      sub(/version:.*/, "", indent)
      print indent "version: \"" new_ver "\""
      next
    }
    { print }
  ' "$file" > "$tmp_file"

  mv "$tmp_file" "$file"
}


echo "[INFO] Processing component list: $COMPONENT_NAME"
for name in $(echo "$COMPONENT_NAME" | tr ',' ' '); do
  echo "-----------------------------------------------------"
  echo "[INFO] Processing component: $name"
  update_release_def "$DEFINITION_FILE" "$COMPONENT_TYPE" "$name" "$NEW_VERSION"
done
echo "-----------------------------------------------------"

# Check if anything changed
if git diff --quiet; then
  echo "[INFO] No changes detected in $DEFINITION_FILE. Skipping commit."
  exit 0
fi

git config user.name github-actions
git config user.email github-actions@github.com

git add "$DEFINITION_FILE"
git commit -m "[BOT] CI: Update $COMPONENT_TYPE components to $NEW_VERSION"

# Display the FULL DIFF of the commit we are about to push for confirmation.
echo "[INFO] Displaying full diff for confirmation:"
git show

git push origin "$TARGET_BRANCH"

echo "[INFO] Release definition update completed successfully."
