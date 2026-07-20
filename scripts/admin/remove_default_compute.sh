#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${DIR}"

check_environment_variable() {
    local var_name=$1
    if [ -z "${!var_name}" ]; then
        echo "Error: Environment variable ${var_name} is not defined."
        exit 1
    fi
}

check_environment_variable "RUNAI_URL"
check_environment_variable "RUNAI_CLIENT_ID"
check_environment_variable "RUNAI_CLIENT_SECRET"

command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required."
    exit 1
}

TOKEN=$(./get_token.sh)

COMPUTE_NAMES=(
    "cpu-only"
    "half-gpu"
    "one-gpu"
    "small-fraction"
    "two-gpus"
)

for name in "${COMPUTE_NAMES[@]}"; do
    echo "Looking up compute profile: ${name}"

    response=$(curl -sS -k \
        "${RUNAI_URL}/api/v1/asset/compute?name=${name}&scope=tenant" \
        --header "Authorization: Bearer ${TOKEN}")

    asset_id=$(jq -r \
        --arg name "${name}" \
        '.entries[]? | select(.meta.name == $name) | .meta.id' \
        <<<"${response}" |
        head -n 1)

    if [ -z "${asset_id}" ] || [ "${asset_id}" = "null" ]; then
        echo "Compute profile '${name}' was not found. Skipping."
        continue
    fi

    echo "Deleting ${name} (${asset_id})..."

    status_code=$(curl -sS -k \
        -o /tmp/runai-delete-compute-response.json \
        -w '%{http_code}' \
        -X DELETE \
        "${RUNAI_URL}/api/v1/asset/compute/${asset_id}" \
        --header "Authorization: Bearer ${TOKEN}")

    if [ "${status_code}" = "202" ]; then
        echo "Deletion accepted for '${name}'."
    else
        echo "Failed to delete '${name}', HTTP ${status_code}:"
        cat /tmp/runai-delete-compute-response.json
        echo
        exit 1
    fi
done

rm -f /tmp/runai-delete-compute-response.json
echo "Finished removing compute profiles."
