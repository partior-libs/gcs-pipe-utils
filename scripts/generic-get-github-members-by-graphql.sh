set +e

## Sourcing the common libs
if [[ ! -z $BASH_SOURCE ]]; then
    ACTION_BASE_DIR=$(dirname $BASH_SOURCE)
    source $(find $ACTION_BASE_DIR/.. -type f | grep common-libs.sh)
elif [[ $(find . -type f -name common-libs.sh | wc -l) > 0 ]]; then
    source $(find . -type f | grep common-libs.sh)
elif [[ $(find .. -type f -name common-libs.sh | wc -l) > 0 ]]; then
    source $(find .. -type f | grep common-libs.sh)
else
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to find and source common-libs.sh"
    exit 1
fi


targetSearchUser="$1"
targetJsonFile="$2"
orgListFile="$3"
targetUsernameValueFile="${4:-user.tmp}"
targetUserEmailValueFile="${5:-email.tmp}"

TEMP_DIR="./tempGithubMembers"           # Temp directory for per-org data

function processAllOrgs() {
    local targetJsonFile="$1"
    local orgListFile="$2"
    mkdir -p "$TEMP_DIR"
    rm -f "$TEMP_DIR"/*.json "$targetJsonFile"

    if [[ ! -f "$orgListFile" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Org list file '$orgListFile' not found." >&2
        return 1
    fi

    local -a orgList=()
    mapfile -t orgList < "$orgListFile"

    if [[ ${#orgList[@]} -eq 0 ]]; then
        echo "[INFO] Org list from [$orgListFile] is empty. Skipping."
        return 0
    fi

    for org in "${orgList[@]}"; do
        echo "[INFO] Processing org: $org"

        local token
        if ! token=$(getGithubTokenForOrg "$org"); then
            echo "[ERROR] Skipping org [$org] due to token generation failure."
            continue
        fi

        if ! authenticateGhCli "$token"; then
            echo "[ERROR] Skipping org [$org] due to GitHub CLI auth failure."
            continue
        fi

        local outputFile="$TEMP_DIR/${org}_filtered.json"
        if ! queryMembersForOrg "$org" "$outputFile"; then
            echo "[ERROR] Skipping org [$org] due to query failure."
            continue
        fi

        echo "[INFO] Finished processing org: $org"
    done

    # Merge and deduplicate final result
    if compgen -G "$TEMP_DIR/*_filtered.json" > /dev/null; then
        jq -s 'add | unique_by(.github_id)' "$TEMP_DIR"/*_filtered.json > "$targetJsonFile"
        echo "[INFO] Final consolidated member data saved to $targetJsonFile"
    else
        echo "[INFO] No member data collected. Skipping final JSON generation."
    fi
}

processAllOrgs "$targetJsonFile" "$orgListFile"

echo "[INFO] Preview Json..."
cat $targetJsonFile | jq . 

echo "[INFO] Lookup for user [$targetSearchUser]..."
foundUser=$(findGhUser "$targetSearchUser" "$targetJsonFile" "$targetUsernameValueFile" "$targetUserEmailValueFile")
if [[ $? -gt 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to lookup user [$targetSearchUser]"
    echo "[ERROR_MSG] $(echo $foundUser)"
    exit 1
fi

echo "[INFO] Found user lookup: [$foundUser]..."

exit 0