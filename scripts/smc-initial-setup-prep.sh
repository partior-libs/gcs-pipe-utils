#!/bin/bash +e
set +e

function getListCount() {
    local searchQueryPath=$1
    local searchQueryPathConverted=$(convertQueryToEnv "$searchQueryPath")
    set | grep -e "^${searchQueryPathConverted}__" | wc -l
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

function convertListToJsonArray() {
    local searchQueryPath=$1
    local listCount=$(getListCount "$searchQueryPath")

    if [[ $listCount -eq 0 ]]; then
        echo "[INFO] Sequence list from [$searchQueryPath] is 0. Skipping"
        exit 0
    fi

    local tmpBuffer=""
    for eachSequenceItem in `seq 0 $((${listCount}-1))`
    do
        local listSearchPath=$searchQueryPath.$eachSequenceItem
        if [[ -z "$tmpBuffer" ]]; then
            tmpBuffer="[ '$(getValueByQueryPath $listSearchPath)'"
        else
            tmpBuffer="$tmpBuffer, '$(getValueByQueryPath $listSearchPath)'"
        fi
    done
    tmpBuffer="$tmpBuffer ]"
    echo $tmpBuffer
}
finalJsonList=$(convertListToJsonArray "smc-initial-setup.setup-sequence")
echo "[INFO] Found list value: $finalJsonList"
echo ::set-output name=list::"$finalJsonList"