#!/bin/bash -e

show_help() {
    echo ""
    echo "Usage: $0"
    echo ""
    echo "Environment variables required:"
    echo "  RUNAI_URL:          Run:AI API URL"
    echo "  RUNAI_CLIENT_ID:    Run:AI Client ID" 
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

if [ "$#" -ne 0 ]; then
    echo "Error: This script does not accept any arguments."
    show_help
    exit 1
fi

# Get the token response and store it in a variable
# Ref: https://run-ai-docs.nvidia.com/guides/reference/api/rest-auth#example-command-to-get-an-api-token
RESPONSE=$(curl -s -k -X POST \
  "${RUNAI_URL}/api/v1/token" \
  --header 'Accept: */*' \
  --header 'Content-Type: application/json' \
  --data-raw "{
  \"grantType\":\"client_credentials\",
  \"clientId\":\"${RUNAI_CLIENT_ID}\",
  \"clientSecret\":\"${RUNAI_CLIENT_SECRET}\"
}")

# Extract just the accessToken value using jq
echo "$RESPONSE" | jq -r '.accessToken'
