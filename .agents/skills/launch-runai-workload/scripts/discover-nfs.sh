#!/bin/bash

set -euo pipefail

project=""
asset_name=""

usage() {
  cat <<'EOF'
Usage: discover-nfs.sh --project NAME [--name ASSET_NAME]

Resolve authorized NFS data-source assets for a Run:ai project without
printing the bearer token.

Options:
  --project NAME   Run:ai project whose accessible assets should be listed.
  --name NAME      Return only the exact NFS asset name.
  -h, --help       Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --project)
      (($# >= 2)) || die "--project requires a value"
      project=$2
      shift 2
      ;;
    --name)
      (($# >= 2)) || die "--name requires a value"
      asset_name=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$project" ]] || die "--project is required"

for required_command in runai jq curl; do
  command -v "$required_command" >/dev/null 2>&1 \
    || die "$required_command is required"
done

if [[ -z "${SSL_CERT_FILE:-}" && -s "${HOME}/.runai/certs/root-ca.crt" ]]; then
  export SSL_CERT_FILE="${HOME}/.runai/certs/root-ca.crt"
fi

runai whoami >/dev/null 2>&1 \
  || die "Run:ai authentication is invalid; log in before discovering assets"

projects_json=$(runai project list --no-pagination --json)
project_id=$(printf '%s' "$projects_json" | jq -r --arg project "$project" '
  [.projects[] | select(.name == $project) | .id][0] // empty
')
[[ -n "$project_id" ]] || die "project is not visible: $project"

config_json=$(runai config describe --json)
base_url=$(printf '%s' "$config_json" | jq -r '.control_plane.url // empty')
[[ -n "$base_url" ]] || die "Run:ai control-plane URL is missing"

access_token=$(runai auth get-token --output plaintext)
[[ -n "$access_token" ]] || die "Run:ai returned an empty access token"
trap 'unset access_token' EXIT

curl_args=(--fail --silent --show-error)
if [[ -n "${SSL_CERT_FILE:-}" && -s "$SSL_CERT_FILE" ]]; then
  curl_args+=(--cacert "$SSL_CERT_FILE")
fi

response=$(curl "${curl_args[@]}" \
  -H "Authorization: Bearer $access_token" \
  --get \
  --data-urlencode "projectId=$project_id" \
  "$base_url/api/v1/asset/datasource")

normalized=$(printf '%s' "$response" | jq --arg name "$asset_name" '
  [
    .entries[]
    | select((.meta.kind // .kind // "") == "nfs")
    | {
        name: (.meta.name // .name),
        scope: (.meta.scope // .scope),
        server: .spec.nfs.server,
        path: .spec.nfs.path,
        mountPath: .spec.nfs.mountPath,
        readOnly: .spec.nfs.readOnly
      }
    | select($name == "" or .name == $name)
  ]
')

count=$(printf '%s' "$normalized" | jq 'length')
((count > 0)) || die "no matching NFS data-source asset is accessible"
printf '%s\n' "$normalized"
