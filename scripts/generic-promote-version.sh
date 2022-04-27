#!/bin/bash +e
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

jiraUsername="$1"
jiraToken="$2"
jiraBaseUrl="$3"
sourceVersion="$4"
releaseVersion="$5"
versionIdentifier="$6"
jiraProjectKey="$7"

echo "[INFO] Jira Base Url: $jiraBaseUrl"
echo "[INFO] Source Version: $sourceVersion"
echo "[INFO] Release Version: $releaseVersion"
echo "[INFO] Jira Version Identifier: $versionIdentifier"
echo "[INFO] Jira Project Key: $jiraProjectKey"

# Get the Id of source version from jira
function getSourceVersionId() {
    local responseOutFile=$1
    local response=""
    response=$(curl -k -s -u $jiraUsername:$jiraToken \
                -w "status_code:[%{http_code}]" \
                -X GET \
                "$jiraBaseUrl/rest/api/3/project/$jiraProjectKey/versions" -o $responseOutFile)

    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to get the project version details."
        echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/3/project/$jiraProjectKey/versions"
        echo "$response"
        return 1
    fi
    
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')

    if [[ $responseStatus -eq 200 ]]; then
        sourceVersionId=$( jq -r --arg versionIdentifier "${versionIdentifier}" --arg sourceVersion "$sourceVersion" '.[] | select(.name=='\"${versionIdentifier}_$sourceVersion\"') | .id' < $responseOutFile)
        echo "$(echo $sourceVersionId | tr -d '"')"
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 when querying project details: [$responseStatus]" 
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
        echo "[DEBUG] $(cat $responseOutFile)"
        return 1
    fi
    
}

function updateVersionStatusInJira() {
    local payloadData=$1
    local versionId=$2
    local responseOutFile=response.tmp 
    local response=""
    response=$(curl -k -s -u $jiraUsername:$jiraToken \
            -w "status_code:[%{http_code}]" \
            -X PUT \
            -H "Content-Type: application/json" \
            --data "$payloadData" \
            "$jiraBaseUrl/rest/api/3/version/$versionId" -o $responseOutFile)
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to update version details."
        echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/3/version/$versionId"
        echo "$response"
        return 1
    fi

    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')


    if [[ $responseStatus -eq 200 ]]; then
        echo "[INFO] Version updated successfully"
        echo "$response" 
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 when updating version: [$responseStatus]" 
        echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/3/version/$versionId"
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
        echo "[DEBUG] $(cat $responseOutFile)"
        return 1
    fi
}

versionsOutputFile=versions.tmp
releaseDate=$(date '+%Y-%m-%d')
buildUrl=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
# Getting source version id
sourceVersionId=$(getSourceVersionId "$versionsOutputFile")
if [[ $? -ne 0 ]]; then
	echo "[ERROR] $BASH_SOURCE (line:$LINENO): Error getting Jira Source Version ID"
	echo "[DEBUG] echo $sourceVersionId"
	exit 1
fi
# Getting the IDs of all versions whose names startwith "$versionIdentifier_$releaseVersion"
filteredIds=$( jq -r --arg releaseVersion "$releaseVersion" --arg versionIdentifier "$versionIdentifier" '.[] | select(.archived==false and .released==false) | select (.name|startswith('\"${versionIdentifier}_${releaseVersion}\"')) | .id' < $versionsOutputFile)
sourceCiUrl=$( jq -r --arg sourceVersion "$sourceVersion" --arg versionIdentifier "$versionIdentifier" '.[] | select(.name=='\"${versionIdentifier}_$sourceVersion\"') | .description' < $responseOutFile )
echo "Filtered Ids:${filteredIds[*]}"
for versionId in ${filteredIds[@]}; do
    if (( $versionId == $sourceVersionId )); then
        echo "Promoting the version from $sourceVersion to $releaseVersion"
        data='{"name" : "'${versionIdentifier}_${releaseVersion}'","releaseDate" : "'${releaseDate}'","released" : true,"description":"Promoted from '$sourceVersion' to '$releaseVersion' \n '$buildUrl' \n '$sourceCiUrl'"}'
        updateVersionStatusInJira "$data" "$versionId"
        filteredIds=( "${filteredIds[@]/$versionId}" )
    else
        echo "Archiving pre-release version whose id is $versionId"
        data='{"archived" : true}'
        updateVersionStatusInJira "$data" "$versionId"
    fi
done
