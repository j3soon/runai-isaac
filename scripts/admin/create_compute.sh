#!/bin/bash -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${DIR}"

check_environment_variable() {
    local var_name=$1
    if [ -z "${!var_name}" ]; then
        echo "Error: Environment variable $var_name is not defined."
        exit 1
    fi
}

check_environment_variable "RUNAI_URL"
check_environment_variable "RUNAI_CLIENT_ID"
check_environment_variable "RUNAI_CLIENT_SECRET"

# Get the authentication token
TOKEN=$(./get_token.sh)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get authentication token"
    exit 1
fi

# Create compute profiles for 0-8 GPUs
for i in {0..8}; do
    echo "Creating compute profile for ${i} GPUs..."
    
    # Create the compute profile
    curl -s -k -X POST \
      "${RUNAI_URL}/api/v1/asset/compute" \
      --header "Authorization: Bearer ${TOKEN}" \
      --header 'Content-Type: application/json' \
      --data-raw "{
        \"meta\": {
            \"name\": \"gpu${i}\",
            \"scope\": \"tenant\"
        },
        \"spec\": {
            \"gpuDevicesRequest\": ${i}$([ "$i" -eq 1 ] && echo ",
            \"gpuRequestType\": \"portion\",
            \"gpuPortionRequest\": 1.0")
        }
    }"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create compute profile gpu${i}"
        exit 1
    fi
done

echo "All compute profiles created."
