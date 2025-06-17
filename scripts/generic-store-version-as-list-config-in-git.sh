
#!/bin/bash +e

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

yamlStorePathKey="$1"
yamlTargetListQueryPath="$2"
updateNameKey="$3"
artifactBaseName="$4"
updateVersionKey="$5"
artifactVersion="$6"
targetRepo="$7"
createNewConfig="$8"
githubPatToken="$9"
strictUpdate="${10:-true}"

echo "[INFO] Artifact Base Name: ${artifactBaseName}"
echo "[INFO] Artifact Version: ${artifactVersion}"
echo "[INFO] Update Name Key: ${updateNameKey}"
echo "[INFO] Update Version Key: ${updateVersionKey}"
echo "[INFO] YAML Store key: ${yamlStorePathKey}"
echo "[INFO] Target Repo: ${targetRepo}"
echo "[INFO] Strict Update: ${strictUpdate}"

function updateConfig() {
    local targetConfigFile="$1"

    echo "[INFO] Yaml file before update..."
    cat ${targetConfigFile} | yq

    ## Determine if the target is a list or a single value
    local isList=$(yq "$yamlStorePathKey | type" "$targetConfigFile")

    ## Update version based on the structure
    if [[ "$isList" == "!!seq" ]]; then
        echo "[INFO] Updating with matching item in list..."
        if [[ -z "$artifactBaseName" || -z "$updateNameKey" ]]; then
            echo "[ERROR] When updating a list, 'artifactBaseName' and 'updateNameKey' must be provided."
            exit 1
        fi
        local fullYamlStorePathKey="$yamlStorePathKey.@@SEARCH@@.$updateNameKey"
        local postSearchQueryPath="$yamlStorePathKey.@@FOUND@@.$updateVersionKey"
        setItemValueInListByMatchingSearch "$targetConfigFile" "$fullYamlStorePathKey" "$artifactBaseName" "$postSearchQueryPath" "$artifactVersion"
        local execReturnCode=$?
        if [[ $execReturnCode -ne 0 ]] && [[ "$strictUpdate" == "true" ]]; then
            echo "[ERROR] execReturnCode=$execReturnCode"
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed updating file: $targetConfigFile"
            echo "[DEBUG] cmd: setItemValueInListByMatchingSearch \"$targetConfigFile\" \"$yamlStorePathKey\" \"$artifactBaseName\" \"$postSearchQueryPath\" \"$artifactVersion\""
            exit 1
        else
            echo "[INFO] execReturnCode=$execReturnCode"
            if [[ $execReturnCode -ne 0 ]]; then
                echo "[WARN] Update failed on [$targetConfigFile]. Skipping...(because strictUpdate=$strictUpdate)"
            fi
        fi
    elif [[ "$isList" == "!!str" ]]; then
        echo "[INFO] Updating a single value structure..."
        yq -i "${yamlStorePathKey} = \"${artifactVersion}\"" "${targetConfigFile}"
        local execReturnCode=$?
        if [[ $execReturnCode -ne 0 ]] && [[ "$strictUpdate" == "true" ]]; then
            echo "[ERROR] execReturnCode=$execReturnCode"
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Error updating config file [${targetConfigFile}] with key [${yamlStorePathKey}] and value [${artifactVersion}]"
            exit 1
        else
            echo "[INFO] execReturnCode=$execReturnCode"
            if [[ $execReturnCode -ne 0 ]]; then
                echo "[WARN] Update failed on [$targetConfigFile]. Skipping...(because strictUpdate=$strictUpdate)"
            fi
        fi
    elif [[ "$isList" == "!!null" ]]; then
        echo "[ERROR] The path ${yamlStorePathKey} does not exist in the file ${targetConfigFile}"
        exit 1
    fi
}


function startUpdateConfig() {
    local targetFileCount=$(getListCount "$yamlTargetListQueryPath")
    local updatedFiles=()
    if [[ $targetFileCount -eq 0 ]]; then
        echo "[INFO] targetFileCount is 0. Skipping..."
        exit 0
    fi

    for eachFileID in `seq 0 $((${targetFileCount}-1))`
    do
        local eachYamlFile=$(getValueByQueryPath "${yamlTargetListQueryPath}__${eachFileID}")
        echo "[INFO] Updating yaml file: ${eachYamlFile}"
        ## Fail if config file not found
        if [[ ! -f "${eachYamlFile}" ]]; then
            if [[ "${createNewConfig}" == "true" ]]; then
                mkdir -p $(dirname $eachYamlFile)
                touch ${eachYamlFile}
            else
                echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate target yaml file: ${eachYamlFile}"
                exit 1
            fi
        fi
        updateConfig "${eachYamlFile}"
        updatedFiles+=("${eachYamlFile}")

        echo "[INFO] Viewing transformed config: ${eachYamlFile}"
        cat ${eachYamlFile}
        echo "[INFO] Update completed: ${eachYamlFile}"
    done

    ## If redeployment, there will be no new changes to version file
    if (git status | grep "nothing to commit"); then 
        if [[ ! -f VERSION_UPDATED ]]; then
            echo VERSION_UPDATED=false >> $GITHUB_ENV
        fi
    else 
        touch VERSION_UPDATED
        VERSION_UPDATED=true
        echo VERSION_UPDATED=true >> $GITHUB_ENV 
        if [[ ${#updatedFiles[@]} -gt 0 ]]; then
            echo "[INFO] Preparing to push into Git..."
            git config --local user.name github-actions
            git config --local user.email github-actions@github.com
            git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
            git add "${updatedFiles[@]}"
            git commit -m "[CI-Bot] Auto updated ${artifactBaseName}-${artifactVersion}"
        else
            echo "[INFO] No files were updated, skipping commit."
        fi
    fi
    
    ## Perform merge with remote to ensure picking up the latest changes
    if [[ "${VERSION_UPDATED}" == "true" ]]; then
        echo "[INFO] Fetch for any changes.."
        git fetch
        echo "[INFO] Merge any changes.."
        git merge --strategy-option ours -m "[CI-Bot] Auto updated ${artifactBaseName}-${artifactVersion}"
    fi
}

VERSION_UPDATED=false
startUpdateConfig

