
#!/bin/bash +e

artifactVersion="$1"
targetRepo="$2"
githubPatToken="$3"

echo "[INFO] Artifact Version: ${artifactVersion}"
echo "[INFO] Target Repo: ${targetRepo}"


function startTag() {
    local finalVersion="v$1"
    echo "[INFO] Preparing to push into Git..."
       
    echo "[INFO] Deleting remote tag if existed..."
    deleteTag "$targetRepo" "$finalVersion" "$githubPatToken"

    echo "[INFO] Push tags..."
    currentSha=$(git rev-parse HEAD)
    createTag "$targetRepo" "$finalVersion" "$currentSha" "$githubPatToken"
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error during tag creation"
        return 1
    fi
}

function deleteTag() {
    local targetRepo="$1"
    local targetTag="$2"
    local githubPatToken="$3"

    local targetUrl="https://api.github.com/repos/${targetRepo}/git/refs/tags/$targetTag"
    local tmpOutputFile=curlResponse.tmp
    rm -f $tmpOutputFile

    echo "[INFO] Deleting tag with API: $targetUrl..." 
    local curlParam="-w 'status_code:[%{http_code}]' \
        -X DELETE \
        -H \"Accept: application/vnd.github.v3+json\" \
        -H \"Authorization: token ${githubPatToken}\" \
        $targetUrl -o $tmpOutputFile"

    local curlParamWithoutToken="-w 'status_code:[%{http_code}]' \
        -X DELETE \
        -H \"Accept: application/vnd.github.v3+json\" \
        -H \"Authorization: token ***\" \
        $targetUrl"

    ## Start querying
    rm -f $versionStoreFilename
    local execCurl="curl -k -s"
    local response=""
    response=$(sh -c "$execCurl $curlParam")
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to delete tag."
        echo "[DEBUG] Curl: $execCurl $curlParamWithoutToken"
        echo "[DEBUG] $(echo $response)"
        exit 1
    fi
    #echo "[DEBUG] response...[$response]"
    #responseBody=$(echo $response | awk -F'status_code:' '{print $1}')
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')
    #echo "[INFO] responseBody: $responseBody"
    echo "[INFO] Query status code: $responseStatus"
    #echo "[DEBUG] Latest [$tmpOutputFile] version:"
    #echo "$(cat $tmpOutputFile)" 

    if [[ $responseStatus -ne 204 ]]; then
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 204 when deleting tag with $targetUrl: [$responseStatus]"
        echo "[DEBUG] $execCurl $curlParam" 
        echo "$(cat $tmpOutputFile)" 
        return 1
    else
        echo "[INFO] Successfully deleted tag [$targetTag]"
        return 0
    fi       
}

function createTag() {
    local targetRepo="$1"
    local targetTag="$2"
    local targetSha="$3"
    local githubPatToken="$4"

    local targetUrl="https://api.github.com/repos/${targetRepo}/git/refs"
    local tmpOutputFile=curlResponse.tmp
    rm -f $tmpOutputFile

    echo "[INFO] Creating tag with API: $targetUrl..." 
    local curlParam="-w 'status_code:[%{http_code}]' \
        -X POST \
        -H \"Accept: application/vnd.github.v3+json\" \
        -H \"Authorization: token ${githubPatToken}\" \
        -H \"Content-Type: application/json\" \
        -d '{
        \"ref\": \"refs/tags/'$targetTag'\",
        \"sha\": \"'$targetSha'\"
        }' \
        $targetUrl -o $tmpOutputFile"

    local curlParamWithoutToken="-w 'status_code:[%{http_code}]' \
        -X POST \
        -H \"Accept: application/vnd.github.v3+json\" \
        -H \"Authorization: token ***\" \
        -H \"Content-Type: application/json\" \
        -d '{
        \"ref\": \"refs/tags/'$targetTag'\",
        \"sha\": \"'$targetSha'\"
        }' \
        $targetUrl"

    ## Start querying
    rm -f $versionStoreFilename
    local execCurl="curl -k -s"
    local response=""
    response=$(sh -c "$execCurl $curlParam")
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to create tag."
        echo "[DEBUG] Curl: $execCurl $curlParamWithoutToken"
        echo "[DEBUG] $(echo $response)"
        exit 1
    fi
    #echo "[DEBUG] response...[$response]"
    #responseBody=$(echo $response | awk -F'status_code:' '{print $1}')
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')
    #echo "[INFO] responseBody: $responseBody"
    echo "[INFO] Query status code: $responseStatus"
    #echo "[DEBUG] Latest [$tmpOutputFile] version:"
    #echo "$(cat $tmpOutputFile)" 

    if [[ $responseStatus -ne 201 ]]; then
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 201 when creating tag with $targetUrl: [$responseStatus]"
        echo "[DEBUG] $execCurl $curlParam" 
        echo "$(cat $tmpOutputFile)" 
        return 1
    else
        echo "[INFO] Successfully created tag [$targetTag]"
        return 0
    fi       
}

startTag "${artifactVersion}"
if [[ $? -ne 0 ]]; then
    echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Unable to tag"
    exit 1
fi
