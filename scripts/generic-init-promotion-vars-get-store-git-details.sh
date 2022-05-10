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

storeVersionEnabledQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__store_version__enabled
echo [DEBUG] storeVersionEnabledQueryValue=$storeVersionEnabledQueryPath
storeVersionEnabledQueryValue=${!storeVersionEnabledQueryPath}

storeVersionGitEnabledQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__store_version__git__enabled
echo [DEBUG] storeVersionGitEnabledQueryValue=$storeVersionGitEnabledQueryPath
storeVersionGitEnabledQueryValue=${!storeVersionGitEnabledQueryPath}

storeVersionGitRepoQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__store_version__git__repo
echo [DEBUG] storeVersionGitRepoQueryValue=$storeVersionGitRepoQueryPath
storeVersionGitRepoQueryValue=${!storeVersionGitRepoQueryPath}

storeVersionGitSearchListQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__search_list_key_path
echo [DEBUG] storeVersionGitSearchListQueryPath=$storeVersionGitSearchListQueryPath
storeVersionGitSearchListQueryValue=${!storeVersionGitSearchListQueryPath}

storeVersionGitSearchListMatchQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__search_list_match_key_path_value
echo [DEBUG] storeVersionGitSearchListMatchQueryPath=$storeVersionGitSearchListMatchQueryPath
storeVersionGitSearchListMatchQueryValue=${!storeVersionGitSearchListMatchQueryPath}

storeVersionGitStoreKeyQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__store_version__git__yaml_store_path_key
echo [DEBUG] storeVersionGitStoreKeyQueryValue=$storeVersionGitStoreKeyQueryPath
storeVersionGitStoreKeyQueryValue=${!storeVersionGitStoreKeyQueryPath}

storeVersionGitTargetEnvFileQueryPath=${promotionQueryPathInEnv}__${SEQUENCE_ITEM_NO}__store_version__git__target_env_file
echo [DEBUG] storeVersionGitTargetEnvFileQueryValue=$storeVersionGitTargetEnvFileQueryPath
storeVersionGitTargetEnvFileQueryValue=${!storeVersionGitTargetEnvFileQueryPath}

echo STORE_VERSION_ENABLE="${storeVersionEnabledQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_ENABLE="${storeVersionGitEnabledQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_REPO="${storeVersionGitRepoQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_SEARCH_LIST_QUERY_PATH="${storeVersionGitSearchListQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_SEARCH_LIST_MATCH_QUERY_VALUE="${storeVersionGitSearchListMatchQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_STORE_KEY="${storeVersionGitStoreKeyQueryValue}" >> $GITHUB_ENV
echo STORE_VERSION_GIT_TARGET_ENV_FILE="${storeVersionGitTargetEnvFileQueryValue}" >> $GITHUB_ENV