#!/bin/bash +e
targetStoreYqlBase="$1"
targetSMCYamlFilename="$2"
commonConfigDir="$3"
sourceSMCBaseDir="$4"
smcWs="$5"
yamlEnvListQueryPath="${6:-artifact-commonconfig.smc-address-file.maps}"

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

## These are controller yaml structure. Cannot change unless the structure changed in the controller
sourceKVName=source-yql-path
targetContractStoreName=target-contract-name

echo "[INFO] SMC Dir: $smcWs"
echo "[INFO] Common Config Dir: $commonConfigDir"
if [[ ! -d $commonConfigDir ]]; then
echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed to locate commonConfigDir: $commonConfigDir"
exit 1
fi

listMapCount=$(getListCount "$yamlEnvListQueryPath")
if [[ $listMapCount -eq 0 ]]; then
    echo "[INFO] listMapCount is 0. Skipping..."
    exit 0
fi

envList=$(ls $commonConfigDir)
baseDir=$(pwd)
echo "[INFO] Start processing..."
for eachEnv in ${envList// / }
do
    echo "[INFO] SMC Processing for env ${eachEnv}..."
    finalEnvSrcYamlFile=${sourceSMCBaseDir}/${eachEnv}.yml
    echo "[INFO] SMC source file: ${finalEnvSrcYamlFile}"

    finalEnvTargetSMCYamlFile=${commonConfigDir}/${eachEnv}/${targetSMCYamlFilename}
    echo "[INFO] SMC target file to be created/updated: ${finalEnvTargetSMCYamlFile}"
    touch ${finalEnvTargetSMCYamlFile}

    echo "[INFO] $listMapCount map(s) to be processed on ${eachEnv}..."
    echo "$targetStoreYqlBase:" > ${finalEnvTargetSMCYamlFile}
    for eachMapID in `seq 0 $((${listMapCount}-1))`
    do
        echo "[INFO] Processing list [$((${eachMapID}+1)) out of ${listMapCount}]..."
        sourceKeyValue=$(getKVListValueByQueryPathAndKey "${yamlEnvListQueryPath}__${eachMapID}" "${sourceKVName}")
        targetKeyName=$(getKVListValueByQueryPathAndKey "${yamlEnvListQueryPath}__${eachMapID}" "${targetContractStoreName}" )
        echo "[INFO] sourceKeyName: ${sourceKeyValue}"
        echo "[INFO] targetKeyName: ${targetKeyName}"
        
        finalWriteKeyValue=$(yq "$sourceKeyValue" "$finalEnvSrcYamlFile")
        echo "[INFO] finalWriteKeyValue: ${finalWriteKeyValue}"

        echo "  - contractName: $targetKeyName" >> ${finalEnvTargetSMCYamlFile}
        echo "    address: $finalWriteKeyValue" >> ${finalEnvTargetSMCYamlFile}

    done
    echo "[INFO] SMC update for env eachEnv has completed! Final content for [$finalEnvTargetSMCYamlFile]"
    cat ${finalEnvTargetSMCYamlFile}
    echo
done
echo "[INFO] SMC consolidation completed"