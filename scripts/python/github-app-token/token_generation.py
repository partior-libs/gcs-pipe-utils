import sys
import time
import jwt
import logging
import requests

GH_API_URL = "https://api.github.com"
# --url "https://api.github.com/app/installations/INSTALLATION_ID/access_tokens" \


def get_app_jwt(client_id: str, signing_key: str):
    """
    Gets app JWT given app ID.

    Args:
        client_id (string): App client ID
        signing_key (string): Private key suitable for the chosen algorithm

    Returns:
        string: encoded JWT token
    """
    logging.info(
        "AJ: Executing function 'get_app_jwt' with parameters: client_id=%s",
        client_id,
    )

    payload = {
        "iat": int(time.time()),  # issued at time
        "exp": int(time.time()) + 600,  # expiry - 10min max
        "iss": client_id,  # github app's client ID
        "alg": "RS256",  # mac algo must be R256
        # (https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app#about-json-web-tokens-jwts)
    }

    encoded_jwt = jwt.encode(payload, signing_key, algorithm="RS256")
    logging.debug(f"AJ: Encoded JWT is {encoded_jwt}")

    return encoded_jwt


def get_app_installation_id(jwt: str, org: str = None) -> str:
    """
    Get app installation ID for token generation

    Args:
        jwt (string): JWT
        org (string): Organization name
    Returns:
        id (string): Installation id
    """
    logging.info(f"CS: Executing function 'get_app_installations_id': org={org}")
    url = GH_API_URL + "/app/installations"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {jwt}",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
    }
    resp = requests.get(url, headers=headers)
    status_code = resp.status_code
    response = resp.json() if status_code != 204 else None

    if status_code != 200 or not (response and isinstance(response, list)):
        raise Exception(f"Failed to GET installation id, response: {response}")

    for app in response:
        logging.debug(f'CS: app id in response for {app["account"]["login"]} is: {app["id"]}')
        if org is None:
            app_id = app["id"]
            break
        elif "account" in app and app["account"]["login"] == org:
            app_id = app["id"]

    if not app_id:
        raise Exception("Failed to set app ID")

    logging.info(f"Success in executing function 'get_app_installations_id' with id: {id}")
    return app_id


def get_app_installation_access_token(jwt, installation_id):
    """
    Get app installation access token for 1 hour

    Args:
        jwt (string): JWT
        installation_id (string): app installation id
    Returns:
        token (string): token
    """
    logging.info(
        "CS: Executing function 'get_app_installations_access_tokens' for: installation_id=%s",
        installation_id,
    )
    url = GH_API_URL + f"/app/installations/{installation_id}/access_tokens"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {jwt}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    resp = requests.post(url, headers=headers)
    status_code = resp.status_code
    response = resp.json() if status_code != 204 else None

    logging.debug(f"Response for 'get_app_installations_access_tokens' is : {str(response)}")
    if status_code != 201:
        raise Exception(f"Failed to obtain token from API ({status_code}), response: {response}")

    token = response.get("token")
    if token:
        logging.info(f"Successfully obtained token for id: {installation_id}")

    return token


if __name__ == "__main__":
    logging.error("error: module not directly callable")
    sys.exit(1)
