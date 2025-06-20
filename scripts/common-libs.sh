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

function getKVListValueByQueryPathAndKey() {
    local searchQueryPath=$1
    local searchKey=$2
    local searchQueryPathConverted=$(convertQueryToEnv "${searchQueryPath}__${searchKey}")
    local foundValue=$(set | grep -e "^${searchQueryPathConverted}=" | cut -d"=" -f1 --complement)
    echo $foundValue
}

function jfrogGetArtifactStorageMeta() {
    local targetArtifactPath=$1
    local queryKey=$2
    local artifactResultFile=$3
    echo "[INFO] Getting artifactory meta /api/storage/${targetArtifactPath}?${queryKey} ..."
    echo "[INFO] Result file: $artifactResultFile"
    
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
    local createNewConfig="$6"

    if [[ ! -f "$yamlFile" ]]; then
        if [[ "${createNewConfig}" == "true" ]]; then
            mkdir -p $(dirname $yamlFile)
            touch ${yamlFile}
        else
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate yamlFile [$yamlFile]"
            return 1
        fi        
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
    local yqQueryCheck="(${searchParentPath}[] | select(${searchKeyName} == \"$matchValue\"))"
    local yqQueryWrite="(${searchParentPath}[] | select(${searchKeyName} == \"$matchValue\") | ${postSearchKeyName}) = \"$newValue\""
    
    echo "[DEBUG] yqQueryCheck=$yqQueryCheck"
    yq -e "$yqQueryCheck" "$yamlFile"
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Yaml Query Path not found"
        return 1
    fi

    echo "[DEBUG] yqQueryWrite=$yqQueryWrite"
    yq -e -i "$yqQueryWrite" "$yamlFile"
    local returnCode=$?
    sed -i 's/{? {/{{ /g' "$yamlFile"
    sed -i "s/: ''} : ''}/ }}/g" "$yamlFile"
    return $returnCode
}

function setItemValueInMultiListByMatchingSearch() {
    local yamlFile="$1"
    local queryPath="$2"
    local matchValue="$3"
    ## This shall contain the @@FOUND@@ token
    local postSearchQueryPath="$4"
    local newValue="$5"
    local commaDelimitedYamlFile="$6"
    ## Fail if update failed
    local strictUpdate="${7:-true}"

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
            exit 1
        fi
    fi
    for eachYamlFile in ${finalYamlList//,/ }
    do
        setItemValueInListByMatchingSearch "$eachYamlFile" "$queryPath" "$matchValue" "$postSearchQueryPath" "$newValue"
        if [[ $? -gt 0 ]] && [[ "$strictUpdate" == "true" ]]; then
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed updating file: $eachYamlFile"
            echo "[DEBUG] cmd: setItemValueInListByMatchingSearch \"$eachYamlFile\" \"$queryPath\" \"$matchValue\" \"$postSearchQueryPath\" \"$newValue\""
            exit 1
        fi
    done
}

# Get the export link from the enterprise backend export API
function ghGetMembersCsvDownloadLink() {
    local authToken="$1"
    local cookieSession="$2"
    local responseOutFile="${3:-raw-response.out}"
    response=$(curl -k -s \
                -w "status_code:[%{http_code}]" \
                --request POST \
                "https://github.com/enterprises/partior/people/export?authenticity_token=${authToken}" \
                --header "Cookie: user_session=${cookieSession}; __Host-user_session_same_site=${cookieSession}" \
                -o "$responseOutFile")

    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to get GitHub members download link"
        echo "[DEBUG] Curl: https://github.com/enterprises/partior/people/export?authenticity_token=xx"
        echo "$response"
        return 1
    fi
    
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')

    local exportUrl="nil"
    if [[ $responseStatus -eq 201 ]]; then
        exportUrl=$( jq -r .export_url < $responseOutFile)
        echo "$exportUrl"
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 201 when querying members download link: [$responseStatus]" 
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
        echo "[DEBUG] $(cat $responseOutFile)"
        return 1
    fi

}

# Download Github member csv file from the export link
function ghGetMembersCsvFile() {
    local cookieSession="$1"
    local membersListDownloadLink="$2"
    local responseOutFile="${3:-members.csv}"

    local response=""
    response=$(curl -k -s \
                -w "status_code:[%{http_code}]" \
                -XGET \
                --header "Cookie: user_session=$cookieSession" \
                "${membersListDownloadLink}" \
		        -o "$responseOutFile")
    if [[ $? -ne 0 ]]; then
        echo "[ACTION_CURL_ERROR] $BASH_SOURCE (line:$LINENO): Error running curl to download GitHub members csv file"
        echo "[DEBUG] Curl: ${membersListDownloadLink}"
        echo "$response"
        return 1
    fi
    
    local responseStatus=$(echo $response | awk -F'status_code:' '{print $2}' | awk -F'[][]' '{print $2}')

    if [[ $responseStatus -eq 200 ]]; then
        cat "$responseOutFile"
    else
        echo "[ACTION_RESPONSE_ERROR] $BASH_SOURCE (line:$LINENO): Return code not 200 when querying members csv file: [$responseStatus]" 
        echo "[ERROR] $(echo $response | jq '.errors | .name')"
        echo "[DEBUG] $(cat $responseOutFile)"
        return 1
    fi
}

# Function to convert csv file to json and select only username and email
function convertGhCsvToJson() {
    local csvFile="$1"
    local targetJsonFile="${2:-tmp.json}"

    # Check for input file 
    if [[ ! -f "$csvFile" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate CSV file [$csvFile]"
        exit 1
    fi

    echo "[" > "$targetJsonFile"
    isFirstItem=true
    while read -r eachLine; do
        foundUsername=$(echo $eachLine | cut -d"," -f1)
        foundEmail=$(grep -oP '[\.\w-]+@[\.\w]+' <<< $eachLine | tail -1)
        if ($isFirstItem); then
            echo "  {" >> "$targetJsonFile"
            isFirstItem=false
        else
            echo "  ,{" >> "$targetJsonFile"
        fi
        echo "    \"github_login\": \""$foundUsername"\"," >> "$targetJsonFile"
        echo "    \"github_verified_emails\": \""$foundEmail"\"" >> "$targetJsonFile"
        echo "  }" >> "$targetJsonFile"
        # Perform actions on each line here
    done < "$csvFile"

    echo "]" >> "$targetJsonFile"
    cat "$targetJsonFile" | jq . > "$targetJsonFile".tmp
    mv "$targetJsonFile".tmp "$targetJsonFile"
}

## Function to find github user from the generated json file by email or username
function findGhUser() {
    local targetUser="$1"
    local sourceJsonFile="$2"
    local targetUserFile="${3:-user.tmp}"
    local targetEmailFile="${4:-email.tmp}"

    # Check for input file 
    if [[ ! -f "$sourceJsonFile" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate JSON file [$sourceJsonFile]"
        exit 1
    fi
    
    ## if user empty, do not fail, but proceed with default filler value
    if [[ -z "$targetUser" ]]; then
        echo "invalid-user-input"
        exit 0
    fi

    ## if input is email, find the username
    if [[ "$targetUser" =~ "@" ]]; then
        foundItem=$(jq -r ".[] | select(.github_verified_emails | contains(\"$targetUser\")) | .github_login" $sourceJsonFile)
        if [[ -z "$foundItem" ]]; then
            echo "not-found" > $targetUserFile
            foundItem="not-found"
        else
            echo "$foundItem" > $targetUserFile
        fi
        echo "$targetUser" > $targetEmailFile
        
    else
        foundItem=$(jq -r ".[] | select(.github_login | contains(\"$targetUser\")) | .github_verified_emails" $sourceJsonFile)
        if [[ -z "$foundItem" ]]; then
            echo "not-found" > $targetEmailFile
            foundItem="not-found"
        else
            echo "$foundItem" > $targetEmailFile
        fi
        echo "$targetUser" > $targetUserFile
    fi
    echo "$foundItem"
}


