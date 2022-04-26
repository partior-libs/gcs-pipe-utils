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


function getSourceVersionId() {
    echo "Inside function"
    local responseOutFile=$1
    local response=""
    response=$(curl -k -s -u $jiraUsername:$jiraToken \
                -w "status_code:[%{http_code}]" \
                -X GET \
                "$jiraBaseUrl/rest/api/3/project/$jiraProjectKey/versions" -o $responseOutFile)
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to get the project details."
        echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/latest/project/$jiraProjectKey/versions"
        echo "$response"
        return 1
    fi
    echo "After curl"
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')


    if [[ $responseStatus -eq 200 ]]; then
        local versionId=$( jq -r --arg versionIdentifier "$versionIdentifier_" --arg sourceVersion "$sourceVersion"'.[] | select(.name=='\"$versionIdentifier$sourceVersion\"') | .id' < $responseOutFile | tr -d '"')
        echo "$versionId"
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 when querying project details: [$responseStatus]" 
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
		echo "[DEBUG] $(cat $responseOutFile)"
		return 1
    fi
    
}

function promoteVersionInJira() {
    local sourceVersionId=$1
	local versionIdentifier=$2
	local releaseVersion=$3
	local releaseDate=$(date '+%Y-%m-%d')
    local responseOutFile=response.tmp
	local response=""
	response=$(curl -k -s -u $jiraUsername:$jiraToken \
                -w "status_code:[%{http_code}]" \
                -X PUT \
                -H "Content-Type: application/json" \
                --data '{"name" : "'${versionIdentifier}_${releaseVersion}'","releaseDate" : "'${releaseDate}'","released" : true}' \
                "$jiraBaseUrl/rest/api/2/version/$soureVersionId" -o $responseOutFile)
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to update version details."
        echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/2/version/$soureVersionId"
        echo "$response"
        return 1
    fi

    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')


    if [[ $responseStatus -eq 200 ]]; then
        echo "[INFO] Version renamed and released successfully"
	    echo "$response" 
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 when updating version: [$responseStatus]" 
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
		echo "[DEBUG] $(cat $responseOutFile)"
		return 1
    fi
}

function archiveVersionsInJira() {
    local versionsFile=$1
    local versionIdentifier=$2
    local releaseVersion=$3
    local responseOutFile=response.tmp
    local response=""
    # Get all the IDs of pre-release versions
    local archiveVersions=$( jq -r --arg releaseVersion "$releaseVersion" --arg versionIdentifier "$versionIdentifier_" '.[] | select(.archive==false and .release==false) | select (.name|startswith('\"$versionIdentifier$releaseVersion\"')) | .id' < $versionsFile)
    for versionId in archiveVersions; do
        response=$(curl -k -s -u $jiraUsername:$jiraToken \
                -w "status_code:[%{http_code}]" \
                -X PUT \
                -H "Content-Type: application/json" \
                --data '{"archived" : true}' \
                "$jiraBaseUrl/rest/api/2/version/$versionId" -o $responseOutFile)
        if [[ $? -ne 0 ]]; then
            echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to update version status."
            echo "[DEBUG] Curl: $jiraBaseUrl/rest/api/2/version/$versionId"
            echo "$response"
            return 1
        fi

        local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')


        if [[ $responseStatus -eq 200 ]]; then
            echo "[INFO] Version status updated successfully"
            echo "$response" 
        else
            echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 while updating version status: [$responseStatus]" 
            echo "[ERROR] $(echo $response | jq '.errors | .name')"
            echo "[DEBUG] $(cat $responseOutFile)"
            return 1
        fi
    done
}

versionsOutputFile=versions.tmp
# Getting source version id
sourceVersionId=$(getSourceVersionId "$versionsOutputFile")
if [[ $? -ne 0 ]]; then
	echo "[ERROR] $BASH_SOURCE (line:$LINENO): Error getting Jira Source Version ID"
	echo "[DEBUG] echo $sourceVersionId"
	exit 1
fi
promoteVersionInJira "$sourceVersionId" "$versionIdentifier" "$releaseVersion"
archiveVersionsInJira "$versionsOutputFile" "$versionIdentifier" "$releaseVersion"
