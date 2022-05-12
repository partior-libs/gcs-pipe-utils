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

promotionQueryPath=artifacts.yaml-config
promotionQueryPathInEnv=$(echo $promotionQueryPath | sed "s/-/_/g" | sed "s/\./__/g")

fileQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__file
echo [DEBUG] fileQueryPath=$fileQueryPath
fileQueryValue=${!fileQueryPath}
echo [DEBUG] fileQueryValue=$fileQueryValue

filesQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__files
echo [DEBUG] fileQueryPath=$filesQueryPath
filesQueryValue=${!filesQueryPath}
echo [DEBUG] filesQueryValue=$filesQueryValue

searchListQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__search_list_key_path
echo [DEBUG] searchListQueryPath=$searchListQueryPath
searchListQueryValue=${!searchListQueryPath}
echo [DEBUG] searchListQueryValue=$searchListQueryValue

searchListMatchQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__search_list_match_key_path_value
echo [DEBUG] searchListMatchQueryPath=$searchListMatchQueryPath
searchListMatchQueryValue=${!searchListMatchQueryPath}
echo [DEBUG] searchListMatchQueryValue=$searchListMatchQueryValue

versionQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__version_path
echo [DEBUG] versionQueryPath=$versionQueryPath
versionQueryValue=${!versionQueryPath}
echo [DEBUG] versionQueryValue=$versionQueryValue

artifactBaseNameQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__artifact_base_name
echo [DEBUG] artifactBaseNameQueryPath=$artifactBaseNameQueryPath
artifactBaseNameQueryValue=${!artifactBaseNameQueryPath}
echo [DEBUG] artifactBaseNameQueryValue=$artifactBaseNameQueryValue

artifactGroupQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__artifact_group
echo [DEBUG] artifactGroupQueryPath=$artifactGroupQueryPath
artifactGroupQueryValue=${!artifactGroupQueryPath}
echo [DEBUG] artifactGroupQueryValue=$artifactGroupQueryValue

artiSrcRepoQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__artifactory_src_repo
echo [DEBUG] artiSrcRepoQueryPath=$artiSrcRepoQueryPath
artiSrcRepoQueryValue=${!artiSrcRepoQueryPath}
echo [DEBUG] artiSrcRepoQueryValue=$artiSrcRepoQueryValue

artiPromoRepoQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__artifactory_promotion_repo
echo [DEBUG] artiPromoRepoQueryPath=$artiPromoRepoQueryPath
artiPromoRepoQueryValue=${!artiPromoRepoQueryPath}
echo [DEBUG] artiPromoRepoQueryValue=$artiPromoRepoQueryValue

artifactTypeQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__artifact_type
echo [DEBUG] artifactTypeQueryPath=$artifactTypeQueryPath
artifactTypeQueryValue=${!artifactTypeQueryPath}
echo [DEBUG] artifactTypeQueryValue=$artifactTypeQueryValue

## If contain special SEARCH key, then get version from array list
if [[ "$searchListQueryValue" =~ "@@SEARCH@@" ]]; then
    artifactSrcVersion=$(getItemValueFromMultiListByMatchingSearch "$fileQueryValue" "$searchListQueryValue" "$artifactBaseNameQueryValue" "$versionQueryValue" "$filesQueryValue")
    if [[ $? -gt 0 ]] || [[ -z "$artifactSrcVersion" ]]; then
        echo "[ERROR] $BASH_SOURCE (line:$LINENO): Failed get item value from list"
        echo $artifactSrcVersion
        exit 1
    fi
    echo [DEBUG] Updated versionQueryValue...
    echo [DEBUG] artifactSrcVersion=$artifactSrcVersion
else
    artifactSrcVersion=$(cat ${fileQueryValue} | yq "${versionQueryValue}")
fi

artifactReleaseVersion=$(echo $artifactSrcVersion | cut -d"-" -f1)
artifactSrcPackageName="${artifactBaseNameQueryValue}-${artifactSrcVersion}.${artifactTypeQueryValue}"
artifactReleasePackageName="${artifactBaseNameQueryValue}-${artifactReleaseVersion}.${artifactTypeQueryValue}"

jiraVersionIdentifierQueryPath=artifacts__jira__version_identifier
echo [DEBUG] jiraVersionIdentifierQueryPath=$versionIdentifierQueryPath
jiraVersionIdentifierQueryValue=${!jiraVersionIdentifierQueryPath}

jiraProjectKeyQueryPath=artifacts__jira__project_key
echo [DEBUG] jiraProjectKeyQueryPath=$jiraProjectKeyQueryPath
jiraProjectKeyQueryValue=${!jiraProjectKeyQueryPath}
        
echo YAML_ARTIFACT_FILE="${fileQueryValue}" >> $GITHUB_ENV
echo YAML_ARTIFACT_FILES="${filesQueryValue}" >> $GITHUB_ENV
echo YAML_VERSION_QUERY_PATH="${versionQueryValue}" >> $GITHUB_ENV
echo YAML_SEARCH_LIST_QUERY_PATH="${searchListQueryValue}" >> $GITHUB_ENV
echo YAML_SEARCH_LIST_MATCH_KEY_VALUE="${searchListMatchQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_BASE_NAME="${artifactBaseNameQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_GROUP="${artifactGroupQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_SRC_REPO="${artiSrcRepoQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_PROMO_REPO="${artiPromoRepoQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_TYPE="${artifactTypeQueryValue}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_SRC_VERSION="${artifactSrcVersion}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_RELEASE_VERSION="${artifactReleaseVersion}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_SRC_PACKAGE_NAME="${artifactSrcPackageName}" >> $GITHUB_ENV
echo FINAL_ARTIFACT_RELEASE_PACKAGE_NAME="${artifactReleasePackageName}" >> $GITHUB_ENV
echo JIRA_VERSION_IDENTIFIER="${versionIdentifierQueryValue}" >> $GITHUB_ENV
echo JIRA_PROJECT_KEY="${jiraProjectKeyQueryValue}" >> $GITHUB_ENV