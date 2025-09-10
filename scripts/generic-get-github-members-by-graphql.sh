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
TMP_ORG_TOKEN_FILENAME="org-token-file.txt"

function consolidateJsonFilters() {
    local inputDir="$1"
    local outputFile="$2"

    # Expand matching files into an array
    local files=("$inputDir"/*_filtered.json)

    # Check if there are any matching files
    if [ ! -e "${files[0]}" ]; then
        echo "[INFO] No member data collected in '$inputDir'. Skipping final JSON generation."
        return 0
    fi

    # Validate each input file is a valid JSON array
    for file in "${files[@]}"; do
        if ! jq -e 'type == "array"' "$file" > /dev/null 2>&1; then
            echo "[ERROR] File '$file' is not a valid JSON array. Aborting."
            return 1
        fi
    done

    # Merge, deduplicate, and sort
    jq -s '
        flatten
        | map(select(.github_login and .github_verified_emails))
        | unique_by(.github_verified_emails)
        | sort_by(.github_login)
    ' "${files[@]}" > "$outputFile"

    echo "[INFO] Final consolidated member data saved to $outputFile"
}

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
    consolidateJsonFilters "$TEMP_DIR" "$targetJsonFile"
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