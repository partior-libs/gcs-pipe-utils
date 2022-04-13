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
exclusionList="$2"

function checkIfStringInCommaList() {
    local stringToCheck="$1"
    ## Ensure no spaces
    local commaList="$(echo $2 | sed 's/ //g')"
    for eachItem in ${commaList//,/ }
    do
        local eachItemNoSpace="$(echo $eachItem | sed 's/ //g')"
        if [[ "$stringToCheck" ==  "$eachItemNoSpace" ]]; then
            return 0
        fi
    done
    return 1
}

function convertListToJsonArray() {
    local searchQueryPath="$1"
    local exclusionList"$2"

    local listCount=$(getListCount "$searchQueryPath")

    if [[ $listCount -eq 0 ]]; then
        echo "[INFO] Sequence list from [$searchQueryPath] is 0. Skipping"
        exit 0
    fi

    local tmpBuffer=""
    for eachSequenceItem in `seq 0 $((${listCount}-1))`
    do
        local listSearchPath=$searchQueryPath.$eachSequenceItem
        local pathValue="$(getValueByQueryPath $listSearchPath)"
        if (checkIfStringInCommaList "$pathValue" "$exclusionList"); then
            continue
        else
            
            if [[ -z "$tmpBuffer" ]]; then
                tmpBuffer="[ '$pathValue'"
            else
                tmpBuffer="$tmpBuffer, '$pathValue'"
            fi
        fi
    done
    tmpBuffer="$tmpBuffer ]"
    echo $tmpBuffer
}

finalJsonList=$(convertListToJsonArray "$listQueryPath" "$exclusionList")
echo "[INFO] Found list value: $finalJsonList"
echo ::set-output name=list::"$finalJsonList"