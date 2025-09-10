from token_generation import get_app_jwt, get_app_installation_id, get_app_installation_access_token
import argparse
import os
import logging

# Implemented based on
# https://partior.atlassian.net/wiki/spaces/DEVSECOPS/pages/716079124/Using+Github+App+Token+Implementing+JWT-Based+App+Token+Generation+in+Python#Implementation-(Python-with-jwt)


def main():
    # 1. Parse command line args
    parser = argparse.ArgumentParser(
        description="Generates a Github app token for a given organization."
    )
    parser.add_argument(
        "-a", "--app-id", dest="app_id", help="Github App ID", required=True, type=str
    )
    parser.add_argument(
        "-k", "--app-key", dest="app_key", help="Github App Private Key", required=True, type=str
    )
    parser.add_argument(
        "-o",
        "--org",
        dest="org",
        help="Github Org the token is to be authorized with",
        required=True,
        type=str,
    )
    args = parser.parse_args()

    # 2. Get encoded JWT for the provided client ID
    encoded_jwt = get_app_jwt(args.app_id, args.app_key)

    # 3. Get app installation ID
    installation_id = get_app_installation_id(encoded_jwt, args.org)

    # 4. Get app token
    app_token = get_app_installation_access_token(encoded_jwt, installation_id)

    # 5. Write token to ENV var
    if app_token is not None:
        token_env_var_name = "APP_TOKEN"
        # logging.info(f"[INFO] App token created. Storing in ${token_env_var_name}...")
        logging.info(f"[INFO] App token created successfully")
        print(app_token)  # write to stdout
        # write_to_github_env(token_env_var_name, app_token)
    else:
        logging.error(f"[ERROR] Failed to create token for org: {args.org} (appId: {args.app_id})")
        sys.exit(1)


if __name__ == "__main__":
    main()
