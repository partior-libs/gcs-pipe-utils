#!/bin/bash +e
set +e
baseValueFile=$1
targetConfigFile=$2

tmpConfigFile=tmp-deployment.conf

rm -f $tmpConfigFile

if [[ ! -f "$baseValueFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Deployment config base file not found: $baseValueFile"
    exit 1
fi

if [[ ! -f "$targetConfigFile" ]]; then
    echo "[WARNING] Target deployment conf file not found. Create a new file: $targetConfigFile"
fi


IFS=$'\n'       # make newlines the only separator
## Start overriding existing key
for eachConfigLine in $(cat ${targetConfigFile} | grep -v -e "^\s*#" | grep "=" | xargs -i echo {})    
do
    currentConfigKey=$(echo $eachConfigLine | cut -d"=" -f1 | xargs)
    currentConfigValue=$(echo $eachConfigLine | cut -d"=" -f1 --complement| xargs)
    for eachBaseLine in $(cat ${baseValueFile} | grep -v -e "^\s*#" -e "^\s*$" | xargs -i echo {})    
    do
        currentBaseKey=$(echo $eachBaseLine | cut -d"=" -f1 | xargs)
        currentBaseValue=$(echo $eachBaseLine | cut -d"=" -f1 --complement| xargs)
        if [[ "$currentConfigKey" == "$currentBaseKey" ]]; then
            currentConfigValue=$currentBaseValue
        fi
    done
    echo $currentConfigKey=$currentConfigValue >> $tmpConfigFile
done

echo "[INFO] Start adding new base key into target conf"
echo "## New keys from base file" >> $tmpConfigFile 
## Start adding keys not in target config
for eachBaseLine in $(cat ${baseValueFile} | grep -v -e "^\s*#" | grep "=" | xargs -i echo {})    
do
    currentBaseKey=$(echo $eachBaseLine | cut -d"=" -f1 | xargs)
    currentBaseValue=$(echo $eachBaseLine | cut -d"=" -f1 --complement| xargs)
    # echo found [$currentConfigKey=$currentConfigValue]
    if (grep -q -e "^$currentBaseKey=" ${targetConfigFile}); then
        echo "[INFO] Base key [$currentBaseKey] present in target config. Sipping.."
    else
        echo $currentBaseKey=$currentBaseValue >> $tmpConfigFile
    fi
    
done
unset IFS

cp -vf $tmpConfigFile $targetConfigFile
echo [INFO] Transformed config file
cat $targetConfigFile
