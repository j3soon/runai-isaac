#!/bin/bash -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${DIR}"

show_help() {
    echo ""
    echo "Usage: $0 <email> <project>"
    echo ""
    echo "Arguments:"
    echo "  email:         Email address for the new user (must be a valid email address)"
    echo "  project:       Project name to assign roles to (scope)"
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

if [ "$#" -ne 2 ]; then
    echo "Error: This script requires exactly 2 arguments."
    show_help
    exit 1
fi

EMAIL=$1
PROJECT=$2

# Validate email format
if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: Invalid email format"
    exit 1
fi

# Validate project is not empty
if [ -z "$PROJECT" ]; then
    echo "Error: Project name cannot be empty"
    exit 1
fi

# Get the authentication token
TOKEN=$(./get_token.sh)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get authentication token"
    exit 1
fi

# Create the user
# Ref: https://api-docs.run.ai/latest/tag/Users#operation/create_user
USER_RESPONSE=$(curl -s -k -X POST \
  "${RUNAI_URL}/api/v1/users" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-raw "{
    \"email\": \"${EMAIL}\"
  }")

# Get project ID
# Ref: https://api-docs.run.ai/latest/tag/Projects/#operation/get_projects
PROJECT_RESPONSE=$(curl -s -k -X GET \
  "${RUNAI_URL}/api/v1/org-unit/projects" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header 'Content-Type: application/json')
# Extract project ID from the response
PROJECT_ID=$(echo "$PROJECT_RESPONSE" | jq -r --arg project_name "$PROJECT" '.projects[] | select(.name==$project_name) | .id')
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Project '$PROJECT' not found"
    exit 1
fi

# Get a list of roles
# Ref: https://api-docs.run.ai/latest/tag/Roles#operation/get_roles_v1
ROLES_RESPONSE=$(curl -s -k -X GET \
  "${RUNAI_URL}/api/v1/authorization/roles" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header 'Content-Type: application/json')

# Extract role IDs for the roles we want to assign
L2_RESEARCHER_ID=$(echo "$ROLES_RESPONSE" | jq -r '.[] | select(.name=="L2 researcher") | .id')
ENV_ADMIN_ID=$(echo "$ROLES_RESPONSE" | jq -r '.[] | select(.name=="Environment administrator") | .id')
TEMPLATE_ADMIN_ID=$(echo "$ROLES_RESPONSE" | jq -r '.[] | select(.name=="Template administrator") | .id')
if [ -z "$L2_RESEARCHER_ID" ] || [ -z "$ENV_ADMIN_ID" ] || [ -z "$TEMPLATE_ADMIN_ID" ]; then
    echo "Error: Failed to find required role IDs"
    exit 1
fi

# Array of role IDs to assign
ROLE_IDS=("$L2_RESEARCHER_ID" "$ENV_ADMIN_ID" "$TEMPLATE_ADMIN_ID")
# Loop through roles and assign them
for ROLE_ID in "${ROLE_IDS[@]}"; do
    # Ref: https://api-docs.run.ai/latest/tag/Access-rules#operation/create_access_rule
    curl -s -k -X POST \
      "${RUNAI_URL}/api/v1/authorization/access-rules" \
      --header "Authorization: Bearer ${TOKEN}" \
      --header 'Content-Type: application/json' \
      --data-raw "{
        \"subjectId\": \"${EMAIL}\",
        \"subjectType\": \"user\",
        \"roleId\": ${ROLE_ID},
        \"scopeId\": \"${PROJECT_ID}\",
        \"scopeType\": \"project\"
      }"
done

echo "Username: $(echo "$USER_RESPONSE" | jq -r '.username')"
echo "Temporary password: $(echo "$USER_RESPONSE" | jq -r '.tempPassword')"
