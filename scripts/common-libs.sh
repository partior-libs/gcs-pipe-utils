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
    echo "[INFO] Getting artifactory meta /api/storage/${targetArtifactPath}?${queryKey} ..."

    rm -f $artifactResultFile
    local response=""
    response=$(jfrog rt curl -XGET /api/storage/${targetArtifactPath}?${queryKey} \
        -w "status_code:[%{http_code}]" \
        -o $artifactResultFile)
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to get artifact metadata."
        echo "[DEBUG] Curl: /api/storage/${targetArtifactPath}?${queryKey}"
        exit 1
    fi

    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')
    echo "[INFO] Query status code: $responseStatus"
    

    if [[ $responseStatus -ne 200 ]]; then
        
        echo "[WARNING] Artifact query return no result:"
        echo "$(cat $artifactResultFile)"
        return 1
    fi
    return 0
}

function getItemValueFromListByMatchingSearch() {
    local yamlFile="$1"
    local queryPath="$2"
    local matchValue="$3"
    ## This shall contain the @@FOUND@@ token
    local postSearchQueryPath="$4"

    if [[ ! -f "$yamlFile" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate yamlFile [$yamlFile]"
        return 1
    fi

    if [[ -z "$queryPath" ]] || [[ -z "$matchValue" ]]; then
        return 0
    fi

    if [[ ! "$queryPath" =~ '@@SEARCH@@' ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): queryPath does not contain token @@SEARCH@@"
        return 1
    fi
    local searchParentPath=$(echo $queryPath | awk -F'.@@SEARCH@@' '{print $1}')
    local searchKeyName=$(echo $queryPath | awk -F'.@@SEARCH@@' '{print $2}')

    if [[ ! "$postSearchQueryPath" =~ '@@FOUND@@' ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): postSearchQueryPath does not contain token @@FOUND@@"
        return 1
    fi
    local postSearchKeyName=$(echo $postSearchQueryPath | awk -F'@@FOUND@@' '{print $2}')
    local yqQuery="${searchParentPath}[] | select(${searchKeyName} == \"$matchValue\") | ${postSearchKeyName}"

    yq "$yqQuery" "$yamlFile"

}

function getItemValueFromMultiListByMatchingSearch() {
    local yamlFile="$1"
    local queryPath="$2"
    local matchValue="$3"
    ## This shall contain the @@FOUND@@ token
    local postSearchQueryPath="$4"
    local commaDelimitedYamlFile="$5"

    local finalYamlList=""
    if [[ ! -z "$yamlFile" ]]; then
        if [[ ! -z "$commaDelimitedYamlFile" ]]; then
            finalYamlList=$yamlFile,$commaDelimitedYamlFile
        else
            finalYamlList=$yamlFile
        fi
    else
        if [[ ! -z "$commaDelimitedYamlFile" ]]; then
            finalYamlList=$commaDelimitedYamlFile
        else
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): file and files cannot be empty."
            return 1
        fi
    fi
    for eachYamlFile in ${finalYamlList//,/ }
    do
        local returnValue=""
        returnValue=$(getItemValueFromListByMatchingSearch "$eachYamlFile" "$queryPath" "$matchValue" "$postSearchQueryPath")
        if [[ $? -eq 0 ]] && [[ ! -z "$returnValue" ]]; then
            echo $returnValue
            return 0
        fi
    done

}

function setItemValueInListByMatchingSearch() {
    local yamlFile="$1"
    local queryPath="$2"
    local matchValue="$3"
    ## This shall contain the @@FOUND@@ token
    local postSearchQueryPath="$4"
    local newValue="$5"

    if [[ ! -f "$yamlFile" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate yamlFile [$yamlFile]"
        return 1
    fi

    if [[ -z "$queryPath" ]] || [[ -z "$matchValue" ]]; then
        return 0
    fi

    if [[ -z "$newValue" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): newValue cannot be empty"
        return 1
    fi

    if [[ ! "$queryPath" =~ '@@SEARCH@@' ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): queryPath does not contain token @@SEARCH@@"
        return 1
    fi
    local searchParentPath=$(echo $queryPath | awk -F'.@@SEARCH@@' '{print $1}')
    local searchKeyName=$(echo $queryPath | awk -F'.@@SEARCH@@' '{print $2}')

    if [[ ! "$postSearchQueryPath" =~ '@@FOUND@@' ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): postSearchQueryPath does not contain token @@FOUND@@"
        return 1
    fi
    local postSearchKeyName=$(echo $postSearchQueryPath | awk -F'@@FOUND@@' '{print $2}')
    local yqQuery="(${searchParentPath}[] | select(${searchKeyName} == \"$matchValue\") | ${postSearchKeyName}) = $newValue"

    yq -i "$yqQuery" "$yamlFile"
    sed -i 's/{? {/{{ /g' "$yamlFile"
    sed -i "s/: ''} : ''}/ }}/g" "$yamlFile"
}