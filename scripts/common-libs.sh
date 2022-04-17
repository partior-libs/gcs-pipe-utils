## Most of the function here require the variable names flatten from its yaml key name.
## Example, in yaml, "sample=project.config.feature-enabled=false" structured as:
##                  sample-project
#                       config
#                           feature-enabled: false
##  The equivalent flatten key:
##                  - sample_project__config_feature__enabled=false

function getListCount() {
    local searchQueryPath="$1"
    local searchQueryPathConverted="$(convertQueryToEnv "$searchQueryPath")"
    set | grep -o -e "^${searchQueryPathConverted}__[[:digit:]]*" | sort -u | wc -l
}

function convertQueryToEnv() {
    local inputQueryPath=$1
    local converted=$(echo $inputQueryPath | sed  "s/\./__/g" |  sed "s/\-/_/g" )
    echo $converted
}

function getValueByQueryPath() {
    local searchQueryPath=$1
    local searchQueryPathConverted=$(convertQueryToEnv "$searchQueryPath")
    local foundValue=$(set | grep -e "^${searchQueryPathConverted}=" | cut -d"=" -f1 --complement)
    echo $foundValue
}

function jfrogGetArtifactStorageMeta() {
    local targetArtifactPath=$1
    local queryKey=$2
    local artifactResultFile=$3
    echo "[INFO] Getting latest versions for RC, DEV and Release..."

    rm -f $versionStoreFilename
    local response=""
    response=$(jfrog rt curl -XGET "/api/storage/${targetArtifactPath}?${queryKey}" \
        -w "status_code:[%{http_code}]" \
        -o $artifactResult)
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to get latest version."
        echo "[DEBUG] Curl: /api/storage/${targetArtifactPath}?${queryKey}"
        exit 1
    fi

    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')
    echo "[INFO] Query status code: $responseStatus"
    

    if [[ $responseStatus -ne 200 ]]; then
        
        echo "[WARNING] Artifact query return no result:"
        echo "$(cat $artifactResult)"
        return false
    fi
    return true
}