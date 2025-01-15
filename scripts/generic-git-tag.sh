
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
    git config --local user.name github-actions
    git config --local user.email github-actions@github.com
    #git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
    echo "[INFO] Deleting remotee tag if existed..."
    git push --delete origin $finalVersion || true
    echo "[INFO] Push tag..."
    git push --tags
}


startTag "${artifactVersion}"

