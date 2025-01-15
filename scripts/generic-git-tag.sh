
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
    echo "[INFO] Deleting remote tag if existed..."
    curl -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${githubPatToken}" \
        https://api.github.com/repos/${targetRepo}/git/refs/tags/$finalVersion
    #git push --delete origin $finalVersion || true
    echo "[INFO] Push tag..."
    git push --tags
}


startTag "${artifactVersion}"

