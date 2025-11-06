import requests
import os
import time
import json
import yaml
import base64
import argparse
from datetime import datetime, timedelta

# Configuration
MAIN_DIR = "/workspace"


def read_env_variables(env_file_path):
    """Reads environment variables from a .env file.
    Args:
        env_file_path (str): The path to the .env file.
    Returns:
        dict: A dictionary containing the environment variables.
    """
    env_vars = {}
    with open(env_file_path, 'r') as f:
        for line in f:
            key, value = line.strip().split('=')
            env_vars[key] = value.strip('"')
    return env_vars


def base64_encode(data):
  """
  Encodes data using Base64.
  Args:
      data: The data to be encoded (can be a string, bytes, or any object that can be converted to bytes).
  Returns:
      The Base64-encoded string representation of the data.
  """

  # If the data is a string, encode it to bytes first using UTF-8 encoding
  if isinstance(data, str):
    data_bytes = data.encode('utf-8')
  else:
    data_bytes = data

  # Perform the Base64 encoding
  encoded_bytes = base64.b64encode(data_bytes)

  # Decode the encoded bytes back to a string for easier handling
  encoded_string = encoded_bytes.decode('utf-8')

  return encoded_string


def base64_decode(encoded_data):
  """
  Decodes Base64-encoded data.
  Args:
      encoded_data: The Base64-encoded string to be decoded.
  Returns:
      The decoded data as bytes. If the original data was a string, you may need to further decode it using an appropriate encoding (e.g., UTF-8).
  """

  # Encode the encoded string to bytes first, as base64.b64decode expects bytes
  encoded_bytes = encoded_data.encode('utf-8')

  # Perform the Base64 decoding
  decoded_bytes = base64.b64decode(encoded_bytes)

  return decoded_bytes


# Function to search for an item
def search_item(base_url, api_key, search_term):
    """
    Searches for an item in ITSM Catalog.
    Args:
        base_url (str): The ITSM URL.
        api_key (str): The ITSM API key.
        search_term (str): The term to search for.
    Returns:
        str: The response text from the ITSM API.
    """
    url = f"{base_url}/service_catalog/items/search?search_term=\"{search_term}\""
    headers = {
        "Authorization": "Basic " + base64_encode(api_key + ':X:X') + "\"",
        "Cookie": "current_workspace_id=2"
    }
    payload={}
    response = requests.request("GET", url, headers=headers, data=payload)

    return response.text


# Function to get item details
def get_item(base_url, api_key, item_id):
    """
    Gets details of an item in ITSM Catalog.
    Args:
        base_url (str): The ITSM URL.
        api_key (str): The ITSM API key.
        item_id (str): The ID of the item to retrieve.
    Returns:
        str: The response text from the ITSM API.
    """
    url = f"{base_url}/service_catalog/items/{item_id}"
    headers = {
        "Authorization": "Basic " + base64_encode(api_key + ':X:X') + "\"",
        "Cookie": "current_workspace_id=2"
    }
    payload={}
    response = requests.request("GET", url, headers=headers, data=payload)
    return response.text


# Function to create a new item
def create_item(base_url, api_key, item_name, category_id, custom_fields):
    """
    Creates a new item in ITSM Catalog.
    Args:
        item_name (str): The name of the new item.
    Returns:
        str: The response text from the ITSM API.
    """
    url = f"{base_url}/service-catalog/items"
    headers = {
        "Authorization": "Basic " + base64_encode(api_key + ':X:X') + "\"",
        "Cookie": "current_workspace_id=2",
        "Content-Type": "application/json"
    }

    payload = {
        "service_item": {
            "name": item_name,
            "category_id": category_id,
            "short_description": f"Service Automation for {item_name}",
            "description": f"<p>{item_name}</p>",
            "visibility": 2,
            "custom_fields": custom_fields
        },
        "workspace_id": 2
    }
    response = requests.request("POST", url, headers=headers, json=payload)
    print(response.text)
    print(response)
    return response.text


def get_ticket_details(base_url, api_key, ticket_id):
    """
    Gets details of a ticket in ITSM.
    Args:
        base_url (str): The ITSM URL .
        api_key (str): The ITSM API key.
        ticket_id (str): The ID of the ticket to retrieve.
    Returns:
        str: The response text from the ITSM API.
    """
    url = f"{base_url}/tickets/{ticket_id}?include=change"
    headers = {
        "Authorization": "Basic " + base64_encode(api_key + ':X:X') + "\"",
        "Cookie": "current_workspace_id=2"
    }
    payload={}

    response = requests.request("GET", url, headers=headers, data=payload)
    return response.text


def create_ticket(base_url, api_key, item_id, email, custom_fields):
    """
    Creates a new ticket in ITSM Catalog for a specific item.
    This function utilizes the ITSM API to submit a request for a service item. 
    It requires the ITSM URL, API key, item ID, requester's email, and custom fields.
    Args:
        base_url (str): The ITSM URL .
        api_key (str): The ITSM API key.
        item_id (str): The ID of the service item in the ITSM Catalog.
        email (str): The email address of the person requesting the service.
        custom_fields (dict): A dictionary containing custom fields and their values for the ticket.
    Returns:
        str: The response text from the ITSM API. This response will contain information about the created ticket.
    Example:
        >>> create_ticket(base_url="ITSM_URL", api_key="YOUR_API_KEY", item_id="106", email="test.com", custom_fields={"cr_description": "Release notes URL", "cr_plannedstart_date": "2024-03-14T10:00:00", "cr_plannedend_date": "2024-03-14T13:00:00", "environment": "production", "promotion_scope": "ptr-internal", "package_type": "internal", "artifacts_json": "[{\"prj_name\": \"platform-scripts\", \"platform\": \"platform\", \"component\": \"platform\", \"artifact_type\": \"terraform\", \"artifact_version\": \"0.43.5\"}]"})
        # Output: JSON response from ITSM API indicating the ticket creation status.
    """
    url = f"{base_url}/service_catalog/items/{item_id}/place_request"
    headers = {
        "Authorization": "Basic " + base64_encode(api_key + ':X:X') + "\"",
        "Cookie": "current_workspace_id=2",
        "Content-Type": "application/json"
    }

    payload = {
        "quantity": 1,
        "email": email,
        "custom_fields": custom_fields
    }
    response = requests.request("POST", url, headers=headers, json=payload)
    print(response.text)
    print(response)
    return response.text


def main():
    """
    Main function for ITSM Catalog Item Operations.
    Parses command-line arguments to determine the action to perform.
    Reads environment variables from config.env.
    Performs the specified action (search or create).
    """
    parser = argparse.ArgumentParser(description='ITSM Catalog Item Operations')
    parser.add_argument('action', type=str, help='Name of the function to initiate')
    args = parser.parse_args()
    ACTION = args.action
    ARTIFACT_TYPE = "terraform" # default value

    # Read environment variables from config.env
    env_vars = read_env_variables(f'./config.env')
    print("\n[INFO]: Below are the environment variables...\n")
    print(env_vars)
    ITSM_URL = env_vars['_ITSM_URL']
    ITSM_BASE_URL = ITSM_URL.split("/api/")[0]
    API_KEY = env_vars['_ITSM_KEY']
    ITEM_NAME = env_vars['_ITSM_CATALOG']
    ENVIRONMENT = env_vars['_ENVIRONMENT']
    PROJECT_NAME = env_vars['_PROJECT_NAME']
    CR_DESCRIPTION = env_vars['CR_DESCRIPTION'] # This one will be added into CR Description for reference.
    if env_vars['_PLATFORM'] == "multi":
        PLATFORM = "gcp"
    elif env_vars['_PLATFORM'] == "multiaws":
        PLATFORM = "aws"
    elif env_vars['_PLATFORM'] == "multiazure":
        PLATFORM = "azure"
    else:
        PLATFORM = env_vars['_PLATFORM']
    MODULE_TYPE = env_vars['_MODULE_TYPE']
##    GIT_HEAD_BRANCH = env_vars['_GIT_HEAD_BRANCH']
##   if (MODULE_TYPE == "terraform" or PROJECT_NAME == "platform-scripts") and GIT_HEAD_BRANCH == "main":
    if MODULE_TYPE == "terraform":
        ARTIFACT_TYPE = "terraform" #TODO: expected to add more types such as docker, helm and generic ... may be more
    elif MODULE_TYPE == "helm":     
        ARTIFACT_TYPE = "helm"
    elif MODULE_TYPE == "docker":     
        ARTIFACT_TYPE = "docker"
    else:
        ARTIFACT_TYPE = "generic"
    ARTIFACT_VERSION = env_vars['CURRENT_TAG'] # This is created version.
    ARTIFACT_PROVIDER = env_vars.get('_ARTIFACT_PROVIDER', 'NA')
    PTP_REQUESTER = env_vars['_PTP_REQUESTER']
    REPLICATE_GAR = env_vars.get('_REPLICATE_GAR', 'NA')
    PUSH_ECR = env_vars.get('_PUSH_ECR', 'NA')


    if ACTION == "search":
        print(f"Searching for item: {ITEM_NAME}")
        search_result = search_item(base_url=ITSM_URL, api_key=API_KEY, search_term=ITEM_NAME)
        if "id" in search_result:
            # Extract the item ID from the search result
            item_id = json.loads(search_result)["service_items"][0]["display_id"]

            print(f"Item ID found: {item_id}")

            if item_id is not None:
                # Get item details
                item_details = json.loads(get_item(base_url=ITSM_URL, api_key=API_KEY, item_id=item_id))

                service_item_details = {}
                service_item_details["Service_Catalog_Name"] = item_details["service_item"]["name"]
                service_item_details["Custom_Details"] = item_details["service_item"]["custom_fields"]
                service_item_details["Service_Catalog_ID"] = item_details["service_item"]["display_id"]

                print(service_item_details)

        else:
            print("[INFO]: Service Catalog Item not found")

    elif ACTION == "create":
        print(f"Searching for item: {ITEM_NAME}")
        search_result = search_item(base_url=ITSM_URL, api_key=API_KEY, search_term=ITEM_NAME)
        if "id" in search_result:
            # Extract the item ID from the search result
            item_id = json.loads(search_result)["service_items"][0]["display_id"]

            print(f"Item ID found: {item_id}")

            if item_id is not None:
                # Get item details
                item_details = json.loads(get_item(base_url=ITSM_URL, api_key=API_KEY, item_id=item_id))

                service_item_details = {}
                service_item_details["Service_Catalog_Name"] = item_details["service_item"]["name"]
                service_item_details["Custom_Details"] = item_details["service_item"]["custom_fields"]
                service_item_details["Service_Catalog_ID"] = item_details["service_item"]["display_id"]

                print(service_item_details)

        else:
            print(f"[INFO]: Service Catalog Item not found, Creating item: {ITEM_NAME}")

            if ENVIRONMENT == "development" or ENVIRONMENT == "testing":
                category_id = 100000002929
            elif ENVIRONMENT == "staging" or ENVIRONMENT == "production":
                category_id = 19000252799
            else:
                print("[ERROR] Invalid environment and no category id available")

            with open(f'{MAIN_DIR}/{PROJECT_NAME}/fs_config.yaml') as f:
                custom_fields = yaml.load(f, Loader=yaml.FullLoader)

            create_result = create_item(
                base_url=ITSM_URL, 
                api_key=API_KEY, 
                item_name=ITEM_NAME,
                category_id=category_id,
                custom_fields=custom_fields
            )

            print(create_item)

    elif ACTION == "ptp":
        print(f"Requesting promote to production: {PROJECT_NAME} by {PTP_REQUESTER}")
        item_id = 106
        item_details = json.loads(get_item(base_url=ITSM_URL, api_key=API_KEY, item_id=item_id))

        service_item_details = {}
        service_item_details["Service_Catalog_Name"] = item_details["service_item"]["name"]
        service_item_details["Custom_Details"] = item_details["service_item"]["custom_fields"]
        service_item_details["Service_Catalog_ID"] = item_details["service_item"]["display_id"]

        print(type(service_item_details))

        present = datetime.now()
        five_minutes_ago = present - timedelta(minutes=5)
        three_hours_from_now = present + timedelta(hours=3)

        custom_fields = {
            "cr_description": CR_DESCRIPTION, # custom_paragraph
            "cr_plannedstart_date": five_minutes_ago.isoformat(), # custom_date - should be json date format
            "cr_plannedend_date": three_hours_from_now.isoformat(), # custom_date
            "environment": "production", # custom_dropdown
            "promotion_scope": "ptr-internal", # custom_dropdown
            "package_type": "internal", # custom_dropdown
            "artifacts_json": json.dumps([{
                "prj_name": PROJECT_NAME,
                "platform": PLATFORM,
                "component": "platform",
                "artifact_type": ARTIFACT_TYPE,
                "artifact_version": ARTIFACT_VERSION,
                "artifact_provider": ARTIFACT_PROVIDER,
                "replicate_to_all_gars": REPLICATE_GAR,
                "push_to_ecr": PUSH_ECR
            }]) # custom_paragraph - this supposed to push as string
        }

        print("\n[INFO]: Below are the custom fields to create ticket...\n")
        print(custom_fields)

        create_result = json.loads(create_ticket(
            base_url=ITSM_URL, 
            api_key=API_KEY, 
            item_id=item_id,
            email=PTP_REQUESTER,
            custom_fields=custom_fields
        ))

        print("\n[INFO]: Below are the created ticket result...\n")
        print(create_result)

        # Print CR and SR Number and Reference link
        ticket_details = {}
        ticket_details["SR_Number"] = create_result["service_request"]["id"]
        ticket_details["SR_Ref_Link"] = f"{ITSM_BASE_URL}/a/tickets/{create_result['service_request']['id']}"
        time.sleep(60)
        ticket_info = json.loads(get_ticket_details(base_url=ITSM_URL, api_key=API_KEY, ticket_id=create_result["service_request"]["id"]))
        ticket_details["CR_Number"] = ticket_info["ticket"]["change_initiated_by_ticket"]["display_id"]
        ticket_details["CR_Ref_Link"] = f"{ITSM_BASE_URL}/a/changes/{ticket_info['ticket']['change_initiated_by_ticket']['display_id']}"
        ticket_details["CR_Approvers"] = ticket_info["ticket"]["change_initiated_by_ticket"]["cc_email"]["approvers_emails"]
        print("\n[INFO]: Below are the created ticket and associated CR details...\n")
        print(ticket_details)


if __name__ == "__main__":
    main()
