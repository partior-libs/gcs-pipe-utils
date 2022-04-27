
#!/bin/bash +e

targetRepo="$1"
prNum="$2"
qualifiedSourceBranches="$3"
qualifiedTargetBranches="$4"

prDetailJsonFile=prDetail.$(date +%s).json
prURL=https://github.com/${targetRepo}/pull/${prNum}

echo "[INFO] Listing all OPEN PRs"
gh pr list --repo ${targetRepo}

echo "[INFO] Retrieving PR [${prNum}] details.."
echo gh pr view ${prNum} --json state,statusCheckRollup,isDraft,mergeable,mergeStateStatus,reviewDecision --repo ${targetRepo}
gh pr view ${prNum} --json state,statusCheckRollup,isDraft,mergeable,mergeStateStatus,reviewDecision --repo ${targetRepo} > $prDetailJsonFile
if [[ $? -ne 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to query PR [${prNum}] details from [${targetRepo}]"
    exit 1
fi

echo "[INFO] PR merged successfully"
