#!/bin/bash +e
set +e

yamlConfigQueryPathList=$1
propertySourceFile=$2
envName=$3
targetRepo="$4"
githubPatToken="$5"

if [[ ! -f "$propertySourceFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Property file not found [${propertySourceFile}]"
    exit 1
fi

function getEnvNameFromYamlPath() {
    local yamlQueryPath=$1

    local convertedEnvName=$(echo $yamlQueryPath | sed "s/\./__/g" | sed "s/-/_/g")
    echo $convertedEnvName 
}

function getEnvListCount() {
    local yamlQueryPath=$1
    local searchQueryListPath=${yamlQueryPath}.[[:digit:]]*.
    set | grep -e "$(getEnvNameFromYamlPath $searchQueryListPath)" | wc -l
}

function getValueByYamlQueryPath() {
    local queryPath=$1
    local envQueryPath=$(getEnvNameFromYamlPath $queryPath)
    local queryValue=$(set | grep -e "^${envQueryPath}=" | cut -d"=" -f1 --complement)
    echo $queryValue
}

function validateAllKeys() {
    local yamlDomainQueryPath=$1
    local envStoreFile=$yamlDomainQueryPath.file
    local envStoreTargetKeyName=$yamlDomainQueryPath.target-key-name
    local envStoreYamlStorePath=$yamlDomainQueryPath.yaml-store-path
    local envStoreYamlStoreType=$yamlDomainQueryPath.yaml-store-type
    local envStoreKeySources=$yamlDomainQueryPath.key-sources

    local storeFile=$(getValueByYamlQueryPath $envStoreFile)
    if [[ -z "${storeFile}" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Query path [$envStoreFile] is missing"
        exit 1
    fi
    if [[ -z "$(getValueByYamlQueryPath $envStoreTargetKeyName)" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Query path [$envStoreTargetKeyName] is missing"
        exit 1
    fi
    if [[ -z "$(getValueByYamlQueryPath $envStoreYamlStorePath)" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Query path [$envStoreYamlStorePath] is missing"
        exit 1
    fi

    local storeType=$(getValueByYamlQueryPath $envStoreYamlStoreType)
    if [[ -z "${storeType}" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Query path [$envStoreYamlStoreType] is missing"
        exit 1
    fi
    if [[ $(getEnvListCount $envStoreKeySources) -eq 0 ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Query path list [$envStoreKeySources] is 0"
        exit 1
    fi

    local supportedType="list|string"
    if [[ ! "${storeType}" =~ ^($supportedType)$ ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unsupported type for store type [${storeType}]. Supported type: ($supportedType)"
        exit 1
    fi

    if [[ ! -f "${storeFile}" ]]; then
        echo "[WARNING] $BASH_SOURCE (line:$LINENO): Target config file not found. Creating a new file [$storeFile]"
    fi
}

function getKeySourceValue() {
    local keySourceName=$1
    local foundValue=$(cat $propertySourceFile | grep -e "^$keySourceName=" | cut -d"=" -f1 --complement)
    if [[ -z "$foundValue" ]]; then
        return 1
    fi
    echo $foundValue
}

function storeAllKeySources() {
    local keySourceQueryPath=$1
    local envYamlStoreType=$2
    local envTargetStoreFile=$3
    local envYamlStorePath=$4
    local envTargetKeyName=$5

    local keySourceListCount=$(getEnvListCount "$keySourceQueryPath")
    local initialValue=true
    local stringTypeBuffer=""
    for eachKeySourceID in `seq 0 $((${keySourceListCount}-1))`
    do
        local currentKeySourceDomain="${keySourceQueryPath}.${eachKeySourceID}"
        local envCurrentKeySourceName=$(getValueByYamlQueryPath "${currentKeySourceDomain}.name")
        local currentKeySourceValue=$(getKeySourceValue $envCurrentKeySourceName)
        if [[ $? -ne 0 ]]; then
            echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed retrieving value [$envCurrentKeySourceName] from [$propertySourceFile]"
            echo "[DEBUG] Error msg: $currentKeySourceValue"
            exit 1
        fi

        if [[ "$envYamlStoreType" == "string" ]]; then
            if [[ "$initialValue" == "true" ]]; then
                stringTypeBuffer=$currentKeySourceValue
                initialValue=false;
            else
                stringTypeBuffer=$stringTypeBuffer,$currentKeySourceValue
            fi
        elif [[ "$envYamlStoreType" == "list" ]]; then
            if [[ "$initialValue" == "true" ]]; then
                echo "   [WRITE]" currentValue=$currentKeySourceValue yq -i "$envYamlStorePath.$envTargetKeyName = [strenv(currentValue)]" $envTargetStoreFile
                currentValue=$currentKeySourceValue yq -i "$envYamlStorePath.$envTargetKeyName = [strenv(currentValue)]" $envTargetStoreFile
                initialValue=false;
            else
                echo "   [WRITE]" currentValue=$currentKeySourceValue yq -i "$envYamlStorePath.$envTargetKeyName += [strenv(currentValue)]" $envTargetStoreFile
                currentValue=$currentKeySourceValue yq -i "$envYamlStorePath.$envTargetKeyName += [strenv(currentValue)]" $envTargetStoreFile
            fi
        fi
    done

    if [[ "$envYamlStoreType" == "string" ]]; then
        echo "   [WRITE]" currentValue=$stringTypeBuffer yq -i "$envYamlStorePath.$envTargetKeyName = strenv(currentValue)" $envTargetStoreFile
        currentValue=$stringTypeBuffer yq -i "$envYamlStorePath.$envTargetKeyName = strenv(currentValue)" $envTargetStoreFile
    fi
    echo "[INFO] Preview updated file: $envTargetStoreFile"
    cat $envTargetStoreFile
    echo "[INFO] End of Preview"
    addChangestoGit "$envTargetStoreFile" "$envTargetKeyName"
}

function addChangestoGit() {
    targetYamlFile=$1
    targetKey=$2

    echo "[INFO] Stored configured mapped key objects in config file..."
    cat $targetYamlFile | yq

    echo "[INFO] Preparing to push into Git..."
    git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git config --local user.name "github-actions[bot]"
    git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
    git add $targetYamlFile
    git commit -m "[Bot] $envName - Updated [$targetKey] in config"
    git fetch
    git merge --strategy-option ours -m "[Bot] $envName - Updated [$targetKey] in config"
}

function startStoringEngine() {
    yamlConfigQueryPath=$1
    ## Check if array list is found, else exit gracefully
    local configListCount=$(getEnvListCount "$yamlConfigQueryPath")
    if [[ $configListCount -eq 0 ]]; then
        echo "[INFO] No configuration was found on this query path: $yamlConfigQueryPath"
        exit 0
    fi

    ## Access each config list
    for eachStoreID in `seq 0 $((${configListCount}-1))`
    do
        local currentStoreDomain="${yamlConfigQueryPath}.${eachStoreID}"
        local envStoreEnabled=$(getValueByYamlQueryPath "${currentStoreDomain}.enabled")
        if [[ "${envStoreEnabled}" == "true" ]]; then
            echo "[INFO] Processing store config for yaml path: [${currentStoreDomain}]..."
            validateAllKeys "$currentStoreDomain"
            local keySourceQueryPath=${currentStoreDomain}.key-sources
            local envTargetStoreFile=$(getValueByYamlQueryPath "${currentStoreDomain}.file")
            local envYamlStoreType=$(getValueByYamlQueryPath "${currentStoreDomain}.yaml-store-type")
            local envYamlStorePath=$(getValueByYamlQueryPath "${currentStoreDomain}.yaml-store-path")
            local envTargetKeyName=$(getValueByYamlQueryPath "${currentStoreDomain}.target-key-name")

            storeAllKeySources "$keySourceQueryPath" "$envYamlStoreType" "$envTargetStoreFile" "$envYamlStorePath" "$envTargetKeyName"
            
        fi
    done
}

## Start here
IFS=', ' read -r -a queryPathList <<< "$yamlConfigQueryPathList"
for eachQueryPath in "${queryPathList[@]}"
do
    echo "[INFO] Starting with configuration on query path: $eachQueryPath"
    startStoringEngine "$eachQueryPath"
done

