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


targetSearchUser="$1"
targetJsonFile="$2"
targetCsvFile="$3"
targetUsernameValueFile="${4:-user.tmp}"
targetUserEmailValueFile="${5:-email.tmp}"

## For this script to work, there must be valid github auth token and cookie session in the following env
## GH_AUTH_TOKEN
## GH_AUTH_COOKIE_SESSION
authToken="${GH_AUTH_TOKEN}"
cookieSession="${GH_AUTH_COOKIE_SESSION}"

echo "[DEBUG] authToken: $authToken"
echo "[DEBUG] cookieSession: $cookieSession"

downloadLink=$(ghGetMembersCsvDownloadLink "$authToken" "$cookieSession")
if [[ $? -gt 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to mget dowload link:"
    echo "[ERROR_MSG] $downloadLink"
    exit 1
fi

echo "[INFO] Retrieved download link: $downloadLink"
echo "[INFO] Start Downloading CSV data..."
ghGetMembersCsvFile "$authToken" "$cookieSession" "$targetCsvFile"
if [[ $? -gt 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to dowload CSV member list"
    echo "[ERROR_MSG] $(cat $targetCsvFile)"
    exit 1
fi

echo "[INFO] Convert to Json..."
convertGhCsvToJson "$targetCsvFile" "$targetJsonFile"
if [[ $? -gt 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to dowload CSV member list"
    echo "[ERROR_MSG] $(cat $targetCsvFile)"
    exit 1
fi

echo "[INFO] Preview Json..."
cat $targetJsonFile | jq .

echo "[INFO] Lookup for user [$targetSearchUser]..."
foundUser=$(findGhUser "$targetSearchUser" "$targetJsonFile" "$targetUsernameValueFile" "$targetUserEmailValueFile")
if [[ $? -gt 0 ]]; then
    echo "[ERROR] $BASH_SOURCE (line:$LINENO): Unable to lookup user [$targetSearchUser]"
    echo "[ERROR_MSG] $(echo $foundUser)"
    exit 1
fi

echo "[INFO] Found user lookup: [$foundUser]..."

exit 0