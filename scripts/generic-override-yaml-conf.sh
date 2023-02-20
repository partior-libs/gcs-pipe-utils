#!/bin/bash +e
set +e
inputYamlFile="$1"
targetYamlFile="$2"
deploymentYamlQueryPath="$3"
targetWriteQueryPath="$4"
finalDeploymentYamlConfFile="$5"

tmpDeploymentConfFile=deployment-tmp.yaml

function replaceKeyValue() {
    local mergeQueryPath="$1"
    local mergeSrcYaml="$2"
    local mergeTargetQueryPath="$3"
    local mergeTargetYaml="$4"
    local mergeOutputFile="$5"

    local yqRunnerFile=runner-$(date '+%Y%m%d%H%M%S').sh

    echo "yq '$mergeTargetQueryPath = load(\"$mergeSrcYaml\") $mergeQueryPath' $mergeTargetYaml > $mergeOutputFile.tmp" > $yqRunnerFile
    chmod 755 $yqRunnerFile
    ./$yqRunnerFile
    rm -f ./$yqRunnerFile
    mv -f $mergeOutputFile.tmp $mergeOutputFile
}

if [[ ! -f "$inputYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Source config YAML file not found: $inputYamlFile"
    exit 1
fi

if [[ ! -f "$targetYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Target config YAML file not found: $targetYamlFile"
    exit 1
fi

if [[ -z "$deploymentYamlQueryPath" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Deployment conf YAML query path is empty"
    exit 1
fi

if [[ -z "$targetWriteQueryPath" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Target write YAML query path is empty"
    exit 1
fi

replaceKeyValue "$deploymentYamlQueryPath" "$inputYamlFile" "$targetWriteQueryPath" "$targetYamlFile" "$finalDeploymentYamlConfFile"

echo [INFO] Transformed deployment-override.yaml
cat $finalDeploymentYamlConfFile