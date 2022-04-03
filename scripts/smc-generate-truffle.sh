#!/bin/bash +e

inputYamlFile=$1
truffleYamlQueryPath=$2
truffleTemplateFile=$3
finalTruffleJsFile=$4

# inputYamlFile=${{ steps.pipeline-config.outputs.override-truffle-config_git-config_override-config-file }}
# truffleYamlQueryPath=${{ steps.pipeline-config.outputs.override-truffle-config_git-config_yaml-path-key }}
# truffleTemplateFile=${{ steps.pipeline-config.outputs.override-truffle-config_template-file }}
# finalTruffleJsFile=${{ env.TRUFFLE_CONFIG_JS }}

tmpTruffleJsonFile=truffle-tmp.json

if [[ ! -f "$inputYamlFile" ]]; then
echo "[ERROR] $BASH_SOURCE (line:$LINENO): Truffle config YAML file not found: $inputYamlFile"
exit 1
fi

if [[ ! -f "$truffleTemplateFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Truffle template file not found: $truffleTemplateFile"
    exit 1
fi

if [[ -z "$truffleYamlQueryPath" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Truffle YAML query path is empty"
    exit 1
fi

rm -f $tmpTruffleJsonFile
cat $inputYamlFile | yq -o json "${truffleYamlQueryPath}" > $tmpTruffleJsonFile
## Add colon at the end of file
sed -i '$ s/$/;/' $tmpTruffleJsonFile

rm -f $finalTruffleJsFile

IFS=$'\n'       # make newlines the only separator
for eachTemplateLine in $(cat ${truffleTemplateFile})    
do
echo [INFO] Processing template line: [$eachTemplateLine]
if [[ "$eachTemplateLine" == *"@@TRUFFLE_CONFIG_DATA@@"* ]]; then
    for eachNetworkDataLine in $(cat ./$tmpTruffleJsonFile)
    do
        echo [INFO] Processing truffle config line: [$eachNetworkDataLine]
        if [[ "$eachNetworkDataLine" == *":"* ]]; then
        networkKey=$(echo "$eachNetworkDataLine" | cut -d":" -f1)
        networkValue=$(echo "$eachNetworkDataLine" | cut -d":" -f1 --complement)
        networkKey=$(echo "$networkKey" | sed "s/\"//g")
        echo "    $networkKey:$networkValue" >> $finalTruffleJsFile
        else
        echo "    $eachNetworkDataLine" >> $finalTruffleJsFile
        fi
    done
else
    echo "$eachTemplateLine" >> $finalTruffleJsFile
fi
done
unset IFS

echo [INFO] Transformed truffle-config.js
cat $finalTruffleJsFile