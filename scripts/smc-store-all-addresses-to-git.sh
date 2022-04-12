#!/bin/bash +e
set +e

contractAddressesinPropFile="$1"
targetYamlFile="$2"
targetStoreYamlPath="$3"
artifactVersion="$4"
artifactBaseName="$5"
envName="$6"
targetRepo="$7"
githubPatToken="$8"

if [[ ! -f "$contractAddressesinPropFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Contracts extraction file not found: [$contractAddressesinPropFile]"
    exit 1
fi

if [[ ! -f "$targetYamlFile" ]]; then
    echo "[INFO] Address file not found. Creating an empty file"
    touch "$targetYamlFile"
fi

## Get timestamp
storeTimeStamp=$(date +"%Y%m%d_%H%M")

## Generic version
yq -i "$targetStoreYamlPath.artifact-version = \"$artifactVersion\"" $targetYamlFile
yq -i "$targetStoreYamlPath.last-deployed-timestamp = \"${storeTimeStamp}\"" $targetYamlFile

for eachContract in $(cat $contractAddressesinPropFile);
do
echo "[INFO] Processing $eachContract"
finalContractName=$(echo $eachContract | cut -d"=" -f1)
foundAddress=$(echo $eachContract | cut -d"=" -f1 --complement)
echo "[INFO] Found contract [$finalContractName] with address [$foundAddress]"
echo "[INFO] Storing into yaml path [$targetStoreYamlPath.${finalContractName}]..."
yq -i "$targetStoreYamlPath.contracts.${finalContractName}.address = \"${foundAddress}\"" $targetYamlFile
yq -i "$targetStoreYamlPath.contracts.${finalContractName}.version = \"${artifactVersion}\"" $targetYamlFile
yq -i "$targetStoreYamlPath.contracts.${finalContractName}.last-updated = \"${storeTimeStamp}\"" $targetYamlFile
done


echo "[INFO] Stored addresses in manifest file..."
cat $targetYamlFile | yq

echo "[INFO] Preparing to push into Git..."
git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config --local user.name "github-actions[bot]"
git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
git add $targetYamlFile
git commit -m "[Bot] $envName - Deployed $artifactBaseName-$artifactVersion"
git fetch
git merge --strategy-option ours -m "[Bot] $envName - Deployed $artifactBaseName-$artifactVersion"