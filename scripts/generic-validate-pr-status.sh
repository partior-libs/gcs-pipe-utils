
#!/bin/bash +e

targetRepo="$1"
prNum="$2"

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

## Check mergeable flag
mergeableFlag=$(jq -r ".mergeable" $prDetailJsonFile)
if [[ $? -ne 0 ]] || [[ -z "${mergeableFlag}" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to retrieve draff flag. Response content:"
    cat $prDetailJsonFile
    exit 1
fi

if [[ "${mergeableFlag}" == "MERGEABLE" ]]; then
    echo "[INFO] PR [${prNum}] is MERGEABLE."
else
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): PR [${prNum}] is unmergable [${MERGEABLE}]. Resolve the issue and try again."
    echo ${prURL}
    exit 1
fi

## Check isDraft flag
draftFlag=$(jq -r ".isDraft" $prDetailJsonFile)
if [[ $? -ne 0 ]] || [[ -z "${draftFlag}" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to retrieve draff flag. Response content:"
    cat $prDetailJsonFile
    exit 1
fi

if [[ "${draftFlag}" == "false" ]]; then
    echo "[INFO] PR [${prNum}] in not in draft stage."
elif [[ "${draftFlag}" == "true" ]]; then
    echo "[INFO] PR [${prNum}] still in draft stage. Correct it before proceeding."
    echo ${prURL}
    exit 1
else
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unknown PR draft status [${draftFlag}]"
    echo ${prURL}
    exit 1
fi

## Check state flag
stateFlag=$(jq -r ".state" $prDetailJsonFile)
if [[ $? -ne 0 ]] || [[ -z "${stateFlag}" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to retrieve status flag. Response content:"
    echo ${prURL}
    cat $prDetailJsonFile
    exit 1
fi
if [[ "${stateFlag}" == "OPEN" ]]; then
    echo "[INFO] PR [${prNum}] in OPEN state."
elif [[ "${stateFlag}" == "MERGED" ]]; then
    echo "[INFO] PR [${prNum}] already merged. Skipping validation."
    echo ${prURL}
    exit 0
elif [[ "${stateFlag}" == "CLOSED" ]]; then
    echo "[INFO] PR [${prNum}] was closed prematurely. Reopen it before proceeding..."
    echo ${prURL}
    exit 1
else
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unknown PR state [${stateFlag}]"
    echo ${prURL}
    exit 1
fi


checkRunFlag=$(jq -r '.statusCheckRollup[] | select(."__typename"=="CheckRun") | select(."conclusion"!="SUCCESS" and ."conclusion"!="NEUTRAL")' $prDetailJsonFile)
if [[ $? -ne 0 ]] || [[ ! -z "${checkRunFlag}" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Jobs (type:checkRun) found unsuccessful"
    echo ${prURL}
    jq -r '.statusCheckRollup[] | select(."__typename"=="CheckRun") | select(."conclusion"!="SUCCESS" and ."conclusion"!="NEUTRAL")' $prDetailJsonFile
    exit 1
fi

statusContextFlag=$(jq -r '.statusCheckRollup[] | select(."__typename"=="StatusContext") | select(."state"!="SUCCESS" and ."state"!="NEUTRAL")' $prDetailJsonFile)
if [[ $? -ne 0 ]] || [[ ! -z "${statusContextFlag}" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Jobs (type:statusContext) found unsuccessful"
    echo ${prURL}
    jq -r '.statusCheckRollup[] | select(."__typename"=="StatusContext") | select(."state"!="SUCCESS" and ."state"!="NEUTRAL")' $prDetailJsonFile
    exit 1
fi


## Approving PR
echo "[INFO] Approving PR for merging..."
gh pr review ${prNum} -a --repo ${targetRepo}
if [[ $? -ne 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to approve PR [${prNum}]"
    exit 1
fi
## Check reviewDecision flag
reviewDecisionFlag=$(gh pr view ${prNum} --json reviewDecision --repo ${targetRepo} --jq '.reviewDecision')
if [[ $? -ne 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to retrieve draff flag. Response content:"
    cat $prDetailJsonFile
    exit 1
fi
if [[ -z "${reviewDecisionFlag}" ]]; then
    echo "[INFO] PR [${prNum}] is not configured for mandatory review"
elif [[ "${reviewDecisionFlag}" == "APPROVED" ]]; then
    echo "[INFO] PR [${prNum}] has been approved by reviewer"
elif [[ "${reviewDecisionFlag}" == "REVIEW_REQUIRED" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): PR [${prNum}] has not been fully approved by reviewer"
    echo ${prURL}
    exit 1
else
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unknown approval status [${reviewDecisionFlag}]"
    echo ${prURL}
    exit 1
fi

echo "[INFO] PR validation completed and approved."