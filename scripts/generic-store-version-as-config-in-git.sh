
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
yamlEnvListQueryPath="$2"
targetConfigFileRaw="$3"
artifactBaseName="$4"
artifactVersion="$5"
targetRepo="$6"
createNewConfig="$7"
githubPatToken="$8"
matchValue="$9"
postSearchQueryPath="${10}"
commaDelimitedYamlFile="${11}"
strictUpdate="${12:-true}"



echo "[INFO] Artifact Base Name: ${artifactBaseName}"
echo "[INFO] Artifact Version: ${artifactVersion}"
echo "[INFO] YAML Store key: ${yamlStorePathKey}"
echo "[INFO] Target Repo: ${targetRepo}"
echo "[INFO] Strict Update: ${strictUpdate}"
if [[ ! -z "$matchValue" ]]; then
    echo "[INFO] List Search Enabled - Match item value: ${matchValue}"
    echo "[INFO] List Search Enabled - Post match query: ${postSearchQueryPath}"
    echo "[INFO] List Search Enabled - Multi files: ${commaDelimitedYamlFile}"
fi
# yamlEnvListQueryPath="artifact.packager.store-version.git.target-envs"

function updateEnvConfig() {
    local targetEnv="$1"
    local targetConfigFile="$2"

    echo UPPERCASE_TARGET_ENV=${targetEnv^^} >> $GITHUB_ENV

    echo "[INFO] Yaml file before update..."
    cat ${targetConfigFile} | yq

    ## Update version
    if [[ ! -z "$matchValue" ]]; then
        echo "[INFO] Updating with matching item in list..."
        setItemValueInListByMatchingSearch "$targetConfigFile" "$yamlStorePathKey" "$matchValue" "$postSearchQueryPath" "$artifactVersion"
        if [[ $? -ne 0 ]] && [[ "$strictUpdate" == "true" ]]; then
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed updating file: $targetConfigFile"
            echo "[DEBUG] cmd: setItemValueInListByMatchingSearch \"$targetConfigFile\" \"$yamlStorePathKey\" \"$matchValue\" \"$postSearchQueryPath\" \"$artifactVersion\""
            exit 1
        fi
    else
        yq -i "${yamlStorePathKey} = \"${artifactVersion}\"" ${targetConfigFile}
        if [[ $? -ne 0 ]] && [[ "$strictUpdate" == "true" ]]; then
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Error updating config file [${targetConfigFile}] with key [${yamlStorePathKey}] and value [${artifactVersion}]"
            exit 1
        fi
    fi

    ## If redeployment, there will be no new changes to version file
    if (git status | grep "nothing to commit"); then 
        if [[ ! -f VERSION_UPDATED ]]; then
            echo VERSION_UPDATED=false >> $GITHUB_ENV
        fi
    else 
        touch VERSION_UPDATED
        VERSION_UPDATED=true
        echo VERSION_UPDATED=true >> $GITHUB_ENV 
        echo "[INFO] Preparing to push into Git..."
        git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
        git config --local user.name "github-actions[bot]"
        git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
        git add ${targetConfigFile}
        git commit -m "[CI-Bot][${targetEnv^^}] Auto updated ${artifactBaseName}-${artifactVersion}"
    fi

}


function startUpdateConfig() {
    local targetEnvCount=$(getListCount "$yamlEnvListQueryPath")
    if [[ $targetEnvCount -eq 0 ]]; then
        echo "[INFO] targetEnvCount is 0. Skipping..."
        exit 0
    fi

    for eachEnvID in `seq 0 $((${targetEnvCount}-1))`
    do
        local envKeyName=$(getValueByQueryPath "${yamlEnvListQueryPath}__${eachEnvID}")
        echo "[INFO] Env name: $envKeyName"

        local finalYamlList=""
        if [[ ! -z "$targetConfigFileRaw" ]]; then
            if [[ ! -z "$commaDelimitedYamlFile" ]]; then
                finalYamlList=$targetConfigFileRaw,$commaDelimitedYamlFile
            else
                finalYamlList=$targetConfigFileRaw
            fi
        else
            if [[ ! -z "$commaDelimitedYamlFile" ]]; then
                finalYamlList=$commaDelimitedYamlFile
            else
                echo "[ERROR] $BASH_SOURCE (line:$LINENO): Target file(s) cannot be empty."
                exit 1
            fi
        fi
        for eachYamlFile in ${finalYamlList//,/ }
        do
            local updatedYamlFile=$(echo ${eachYamlFile} | sed "s/@@ENV_NAME@@/${envKeyName}/g")
            echo "[INFO] Updating yaml file: ${updatedYamlFile}"
            ## Fail if config file not found
            if [[ ! -f "${updatedYamlFile}" ]]; then
                if [[ "${createNewConfig}" == "true" ]]; then
                    mkdir -p $(dirname $updatedYamlFile)
                    touch ${updatedYamlFile}
                else
                    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate target yaml file: ${updatedYamlFile}"
                    exit 1
                fi
            fi
            updateEnvConfig "${envKeyName}" "${updatedYamlFile}"

            echo "[INFO] Viewing transformed config: ${updatedYamlFile}"
            cat ${updatedYamlFile}
            echo "[INFO] Update completed: ${updatedYamlFile}"

        done


        

    done
    ## Perform merge with remote to ensure picking up the latest changes
    if [[ "${VERSION_UPDATED}" == "true" ]]; then
        echo "[INFO] Fetch for any changes.."
        git fetch
        echo "[INFO] Merge any changes.."
        git merge --strategy-option ours -m "[CI-Bot][${targetEnv^^}] Auto updated ${artifactBaseName}-${artifactVersion}"
    fi
}

VERSION_UPDATED=false
startUpdateConfig

