## Most of the function here require the variable names flatten from its yaml key name.
## Example, in yaml, "sample=project.config.feature-enabled=false" structured as:
##                  sample-project
#                       config
#                           feature-enabled: false
##  The equivalent flatten key:
##                  - sample_project__config_feature__enabled=false

function getListCount() {
    local searchQueryPath="$1"
    local searchQueryPathConverted="$(convertQueryToEnv "$searchQueryPath")"
    set | grep -o -e "^${searchQueryPathConverted}__[[:digit:]]*" | sort -u | wc -l
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