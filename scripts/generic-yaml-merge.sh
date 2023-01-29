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

srcYamlFile="$1"
targetYamlFile="$2"
yamlQueryPath="${3-empty}"
outputFile="$4"
configMode="${5-input}"

yqRunnerFile=runner-$(date '+%Y%m%d%H%M%S').sh
echo "[INFO] Source YAML: $srcYamlFile"
echo "[INFO] Target YAML: $targetYamlFile"
echo "[INFO] YAML Query Path: $yamlQueryPath"

if [[ ! -f "$srcYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Source config YAML file not found: $srcYamlFile"
    exit 1
fi

yq $yamlQueryPath $srcYamlFile > /dev/null
if [[ $? -gt 0 ]] || [[ -z "$yamlQueryPath" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Invalid Yaml query path [$yamlQueryPath]"
    exit 1 
fi

if [[ "$(yq $yamlQueryPath $srcYamlFile)" == "null" ]] || [[ "$(yq $yamlQueryPath $srcYamlFile)" == "null" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Yaml query path [$yamlQueryPath] not found in source yaml: $srcYamlFile"
    exit 1
fi

if [[ -z "$targetYamlFile" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Target config YAML file not found: $targetYamlFile"
    exit 1
fi

if [[ "$(yq $yamlQueryPath $targetYamlFile)" == "null" ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Yaml query path [$yamlQueryPath] not found in target yaml: $targetYamlFile"
    exit 1
fi

echo "[INFO] Merging.."
echo "yq '$yamlQueryPath *= load(\"$srcYamlFile\") $yamlQueryPath' $targetYamlFile > $outputFile" > $yqRunnerFile
chmod 755 $yqRunnerFile
./$yqRunnerFile
# mykey=$mykey  yq 'eval(strenv(mykey)) = load("local.yml") eval(strenv(mykey))' sample2.yml
# rm -f $tmpDeploymentConfFile
# cat $inputYamlFile | yq -o props "${deploymentYamlQueryPath}" > $tmpDeploymentConfFile

# rm -f $finalDeploymentConfFile

# IFS=$'\n'       # make newlines the only separator
# isList=false
# tmpBuffer=""
# tmpKey=""
# for eachTemplateLine in $(cat ${tmpDeploymentConfFile})    
# do
# currentKey=$(echo $eachTemplateLine | cut -d"=" -f1 | xargs)
# currentValue=$(echo $eachTemplateLine | cut -d"=" -f1 --complement| xargs)
# ## Making sure list is converted to comma delimited
# if [[ "$currentKey" =~ [\.] ]] && [[ ${currentKey##*.} =~ ^[0-9]+$ ]]; then
#     isList=true
#     if [[ -z "$tmpKey" ]]; then
#         tmpKey=${currentKey%.*}
#     elif [[ ! "$tmpKey" == "${currentKey%.*}" ]]; then
#         echo $tmpKey=$tmpBuffer >> $finalDeploymentConfFile
#         tmpKey=${currentKey%.*}
#         tmpBuffer=""
#     fi

#     if [[ -z "$tmpBuffer" ]]; then
#         tmpBuffer=$currentValue
#     else
#         tmpBuffer=$tmpBuffer,$currentValue
#     fi
# else
#     if [[ "$isList" == "true" ]]; then
#         isList=false
#         echo $tmpKey=$tmpBuffer >> $finalDeploymentConfFile
#         tmpKey=""
#         tmpBuffer=""
#     fi
#     echo $currentKey=$currentValue >> $finalDeploymentConfFile
# fi
# done
# unset IFS

# echo [INFO] Transformed deployment-override.conf
# cat $finalDeploymentConfFile