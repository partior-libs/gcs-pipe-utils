
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
githubPatToken="$7"

echo "[INFO] Artifact Base Name: ${artifactBaseName}"
echo "[INFO] Artifact Version: ${artifactVersion}"
echo "[INFO] YAML Store key: ${yamlStorePathKey}"
# yamlEnvListQueryPath="artifact.packager.store-version.git.target-envs"

function updateEnvConfig() {
    local targetEnv="$1"
    local targetConfigFile="$2"

    echo UPPERCASE_TARGET_ENV=${targetEnv^^} >> $GITHUB_ENV

    ## Update version
    yq -i "${yamlStorePathKey} = \"${artifactVersion}\"" ${targetConfigFile}

    echo "[INFO] Stored version in config file..."
    cat ${targetConfigFile} | yq

    ## If redeployment, there will be no new changes to version file
    if (git status | grep "nothing to commit"); then 
        echo VERSION_UPDATED=false >> $GITHUB_ENV
    else 
        echo VERSION_UPDATED=true >> $GITHUB_ENV 
        echo "[INFO] Preparing to push into Git..."
        git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
        git config --local user.name "github-actions[bot]"
        git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
        git add ${targetConfigFile}
        git commit -m "[CI-Bot][${targetEnv^^}] Auto updated ${artifactBaseName}-${artifactVersion}"
        echo "[INFO] Fetch for any changes.."
        git fetch
        echo "[INFO] Merge any changes.."
        git merge --strategy-option ours -m "[CI-Bot][${targetEnv^^}] Auto updated ${artifactBaseName}-${artifactVersion}"
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
        local targetConfigFile=$(echo $targetConfigFileRaw | sed "s/@@ENV_NAME@@/${envKeyName}/g")
        echo "[INFO] Updating config file: $targetConfigFile"
        ## Fail if config file not found
        if [[ ! -f "${targetConfigFile}" ]]; then
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to locate deploy config file: $targetConfigFile"
            exit 1
        fi
        # updateEnvConfig
        echo "[INFO] Viewing transformed config: $targetConfigFile"
        cat $targetConfigFile
        echo "[INFO] Update completed: $targetConfigFile"
    done
}

startUpdateConfig

