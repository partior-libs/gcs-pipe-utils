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

listQueryPath="$1"
prependIdentifier="$2"

if [[ ! -z "$prependIdentifier" ]]; then
    prependIdentifier="${prependIdentifier}__"
fi

function convertListToJsonSequence() {
    local searchQueryPath="$1"

    local listCount=$(getListCount "$searchQueryPath")

    if [[ $listCount -eq 0 ]]; then
        echo "[INFO] Sequence list from [$searchQueryPath] is 0. Skipping"
        exit 0
    fi

    local tmpBuffer=""
    for eachSequenceItem in `seq 0 $((${listCount}-1))`
    do    
        if [[ -z "$tmpBuffer" ]]; then
            tmpBuffer="[ '${prependIdentifier}${eachSequenceItem}'"
        else
            tmpBuffer="$tmpBuffer, '${prependIdentifier}${eachSequenceItem}'"
        fi
    done
    tmpBuffer="$tmpBuffer ]"
    echo $tmpBuffer
}

finalJsonList=$(convertListToJsonSequence "$listQueryPath")
echo "[INFO] Found list value: $finalJsonList"
echo ::set-output name=list::"$finalJsonList"