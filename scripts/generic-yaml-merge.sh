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

srcYamlFile="$1"
targetYamlFile="$2"
yamlQueryPath="${3-empty}"
outputFile="$4"
configMode="${5-input}"
controllerConfigKey="${6-merge-yaml-config}"

## Global constants
CTLR_EXCLUDE_LIST_KEYNAME="exclude-keys"

echo "[INFO] Source YAML: $srcYamlFile"
echo "[INFO] Target YAML: $targetYamlFile"
echo "[INFO] YAML Query Path: $yamlQueryPath"
echo "[INFO] Controller Config Key Path: $controllerConfigKey"

function mergeYaml() {
    local mergeQueryPath="$1"
    local mergeSrcYaml="$2"
    local mergeTargetYaml="$3"
    local mergeOutputFile="$4"

    local yqRunnerFile=runner-$(date '+%Y%m%d%H%M%S').sh

    echo "yq '$mergeQueryPath *= load(\"$mergeSrcYaml\") $mergeQueryPath' $mergeTargetYaml > $mergeOutputFile" > $yqRunnerFile
    chmod 755 $yqRunnerFile
    ./$yqRunnerFile
    rm -f ./$yqRunnerFile
}

if [[ ! -f "$srcYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Source config YAML file not found: $srcYamlFile"
    exit 1
fi

yq $yamlQueryPath $srcYamlFile > /dev/null
if [[ $? -gt 0 ]] || [[ -z "$yamlQueryPath" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Invalid Yaml query path [$yamlQueryPath]"
    exit 1 
fi

if [[ "$(yq $yamlQueryPath $srcYamlFile)" == "null" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Yaml query path [$yamlQueryPath] not found in source yaml: $srcYamlFile"
    exit 1
fi

if [[ -z "$targetYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Target config YAML file not found: $targetYamlFile"
    exit 1
fi

if [[ "$(yq $yamlQueryPath $targetYamlFile)" == "null" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Yaml query path [$yamlQueryPath] not found in target yaml: $targetYamlFile"
    exit 1
fi

echo "[INFO] Merging.."

## Merge first, filter later with exclusion list
mergeYaml "$yamlQueryPath" "$srcYamlFile" "$targetYamlFile" "$outputFile"

## If config from controller, expect to have exclusion list
if [[ "$configMode" == "controller" ]]; then
    searchQueryPath=$controllerConfigKey.$CTLR_EXCLUDE_LIST_KEYNAME
    local listCount=$(getListCount "$searchQueryPath")

    ## Restore keys which are in exclusion list
    if [[ $listCount -gt 0 ]]; then
        echo "[INFO] Sequence list from [$searchQueryPath] is $listCount. Begin exclusion filter..."
        for eachSequenceItem in `seq 0 $((${listCount}-1))`
        do
            
            listSearchPath=$searchQueryPath.$eachSequenceItem
            pathValue="$(getValueByQueryPath $listSearchPath)"
            echo "[INFO] Exclusion for key: $listSearchPath"
            echo "[INFO] Original Key Value: $pathValue"
            ## If key in target file is null, delete the key to prevent unwanted keys in final merged
            if [[ "$(yq $listSearchPath $targetYamlFile)" == "null" ]]; then
                echo "[INFO] Key not found in override file. Restoring..."
                cat "$outputFile" | delKey=$listSearchPath yq 'del(eval(strenv(delKey)))' > "$outputFile.tmp"
            else
                echo "[INFO] Restoring key ..."
                mergeYaml "$listSearchPath" "$targetYamlFile" "$outputFile" "$outputFile.tmp"
            fi
            mv -f "$outputFile.tmp" "$outputFile"
        done
    else
        echo "[INFO] Sequence list from [$searchQueryPath] is $listCount. Skip exclusion filter..."
    fi
fi

echo [INFO] Merged yaml...
cat $outputFile