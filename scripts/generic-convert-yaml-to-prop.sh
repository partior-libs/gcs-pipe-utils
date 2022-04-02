#!/bin/bash +e
set +e
inputYamlFile=$1
deploymentYamlQueryPath=$2
finalDeploymentConfFile=$3

tmpDeploymentConfFile=deployment-tmp.prop

if [[ ! -f "$inputYamlFile" ]]; then
echo [ERROR] Deployment config YAML file not found: $inputYamlFile
exit 1
fi

if [[ -z "$deploymentYamlQueryPath" ]]; then
echo [ERROR] Deployment conf YAML query path is empty
exit 1
fi

rm -f $tmpDeploymentConfFile
cat $inputYamlFile | yq -o props "${deploymentYamlQueryPath}" > $tmpDeploymentConfFile

rm -f $finalDeploymentConfFile

IFS=$'\n'       # make newlines the only separator
isList=false
tmpBuffer=""
tmpKey=""
for eachTemplateLine in $(cat ${tmpDeploymentConfFile})    
do
currentKey=$(echo $eachTemplateLine | cut -d"=" -f1 | xargs)
currentValue=$(echo $eachTemplateLine | cut -d"=" -f1 --complement| xargs)
## Making sure list is converted to comma delimited
if [[ "$currentKey" =~ [\.] ]] && [[ ${currentKey##*.} =~ ^[0-9]+$ ]]; then
    isList=true
    if [[ -z "$tmpKey" ]]; then
        tmpKey=${currentKey%.*}
    elif [[ ! "$tmpKey" == "${currentKey%.*}" ]]; then
        echo $tmpKey=$tmpBuffer >> $finalDeploymentConfFile
        tmpKey=${currentKey%.*}
        tmpBuffer=""
    fi

    if [[ -z "$tmpBuffer" ]]; then
        tmpBuffer=$currentValue
    else
        tmpBuffer=$tmpBuffer,$currentValue
    fi
else
    if [[ "$isList" == "true" ]]; then
        isList=false
        echo $tmpKey=$tmpBuffer >> $finalDeploymentConfFile
        tmpKey=""
        tmpBuffer=""
    fi
    echo $currentKey=$currentValue >> $finalDeploymentConfFile
fi
done
unset IFS

echo [INFO] Transformed deployment-override.conf
cat $finalDeploymentConfFile