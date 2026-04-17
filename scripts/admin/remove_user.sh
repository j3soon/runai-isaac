#!/bin/bash -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${DIR}"

show_help() {
    echo ""
    echo "Usage: $0 <email>"
    echo ""
    echo "Arguments:"
    echo "  email:         Email address for the user to remove (must be a valid email address)"
    echo ""
    echo "Environment variables required:"
    echo "  RUNAI_URL:           Run:AI API URL"
    echo "  RUNAI_CLIENT_ID:     Run:AI Client ID"
    echo "  RUNAI_CLIENT_SECRET: Run:AI Client Secret"
}

check_environment_variable() {
    local var_name=$1
    if [ -z "${!var_name}" ]; then
        echo "Error: Environment variable $var_name is not defined."
        show_help
        exit 1
    fi
}

check_environment_variable "RUNAI_URL"
check_environment_variable "RUNAI_CLIENT_ID"
check_environment_variable "RUNAI_CLIENT_SECRET"

if [ "$#" -ne 1 ]; then
    echo "Error: This script requires exactly 1 argument."
    show_help
    exit 1
fi

EMAIL=$1

# Validate email format
if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: Invalid email format"
    exit 1
fi

# Get the authentication token
TOKEN=$(./get_token.sh)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get authentication token"
    exit 1
fi

# Get the user ID
# Ref: https://api-docs.run.ai/latest/tag/Users/#operation/get_users
USERS_RESPONSE=$(curl -s -k -X GET \
  "${RUNAI_URL}/api/v1/users?search=${EMAIL}" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header 'Content-Type: application/json')

USER_ID=$(echo "$USERS_RESPONSE" | jq -r --arg email "$EMAIL" '.[] | select(.username==$email) | .id' | head -n 1)
if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
    echo "Error: User '$EMAIL' not found"
    exit 1
fi

# Delete the user by ID.
# Ref: https://api-docs.run.ai/latest/tag/Users/#operation/delete_user_by_id
HTTP_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -X DELETE \
  "${RUNAI_URL}/api/v1/users/${USER_ID}" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header 'Content-Type: application/json')

if [ "$HTTP_STATUS" != "204" ]; then
    echo "Error: Failed to delete user '$EMAIL' (HTTP ${HTTP_STATUS})"
    exit 1
fi

echo "Removed user '$EMAIL' (userId: ${USER_ID})"
