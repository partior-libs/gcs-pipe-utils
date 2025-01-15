#!/bin/bash +e
set +e

deployConfigFile="$1"
artifactBaseName="$2"
versionKeyPath="$3"
artifactVersion="$4"
artifactVersionPath="$5"
targetEnv="$6"
targetRepo="$7"
githubPatToken="$8"

echo UPPERCASE_TARGET_ENV=${targetEnv^^} >> $GITHUB_ENV

## Fail if config file not found
if [[ ! -f "${deployConfigFile}" ]]; then
    echo "[ERROR] Unable to locate deploy config file: $deployConfigFile"
    exit 1
fi

## Update version
yq -i "${versionKeyPath} = \"${artifactVersionPath}\"" ${deployConfigFile}

echo "[INFO] Stored version in config file..."
cat ${deployConfigFile} | yq

## If redeployment, there will be no new changes to version file
if (git status | grep "nothing to commit"); then 
    echo VERSION_UPDATED=false >> $GITHUB_ENV
else 
    echo VERSION_UPDATED=true >> $GITHUB_ENV 
    echo "[INFO] Preparing to push into Git..."
    git config --local user.name github-actions
        git config --local user.email github-actions@github.com
    git remote set-url origin https://${githubPatToken}@github.com/${targetRepo}
    git add ${deployConfigFile}
    git commit -m "[CI-Bot][${targetEnv^^}] Backup artifact ${artifactBaseName}-${artifactVersion}"
    echo "[INFO] Fetch for any changes.."
    git fetch
    echo "[INFO] Merge any changes.."
    git merge --strategy-option ours -m "[CI-Bot][${targetEnv^^}] Backup artifact ${artifactBaseName}-${artifactVersion}"
fi