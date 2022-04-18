
#!/bin/bash +e

artifactVersion="$1"
targetRepo="$2"
githubPatToken="$3"

echo "[INFO] Artifact Version: ${artifactVersion}"
echo "[INFO] Target Repo: ${targetRepo}"


function startTag() {
    local finalVersion="v$1"
    git tag $finalVersion
    echo "[INFO] Preparing to push into Git..."
    git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git config --local user.name "github-actions[bot]"
    git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
    echo "[INFO] Deleting remote tag if existed..."
    git push --delete origin $finalVersion || true

}


startTag "${artifactVersion}"

