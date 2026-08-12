#!/bin/bash -ex
set -o pipefail

# Bump whenever the command contract changes, so a guide can state a minimum and a user can
# check what an image ships. An image predating this flag exits 1 with "Unknown option
# --version", which identifies it as version 1.
#
# Images are built once and used long afterwards, so several generations of this script are in
# circulation at any time. Keep the contract additive: new behaviour arrives as an opt-in flag,
# never as a changed default, so an instruction written years ago still works on a freshly built
# image, and a new-flag instruction run against an old image fails by name rather than silently
# doing something else. Extend this file rather than forking a run_v2.sh -- every Dockerfile in
# the repository copies this one path to /run.sh.
RUN_SH_VERSION=2

show_help() {
  echo -e "\nUsage: $0 [OPTIONS] <commands>\n"
  echo "Options:"
  echo "  --download-src    The source file or folder to download"
  echo "  --download-dest   The destination file or folder to download to"
  echo "  --upload-src      The source file or folder to upload"
  echo "  --upload-dest     The destination file or folder to upload to"
  echo "  --shell           Run each command through the shell (v2+), so quoting, \$VARIABLES,"
  echo "                    pipes, redirects and && work as written. Without it each command is"
  echo "                    word-split only, which is the default for backward compatibility."
  echo "  --version         Print the /run.sh contract version and exit"
  echo -e "\nThis script downloads the necessary files, executes the specified commands, and then uploads the output files.\n"
  echo -e "With --shell, prefix the last command with 'exec' so it replaces this script as PID 1"
  echo -e "and receives SIGTERM directly on workload stop. Do not use exec alongside --upload-*,"
  echo -e "since the upload step runs after the commands.\n"
}

resolve_path() {
  local path="$1"
  if [[ "$path" != "omniverse://"* && ! "$path" == /* ]]; then
    path="$(pwd)/$path"
  fi
  echo "$path"
}

# Ref: https://stackoverflow.com/a/14203146
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --download-src)
      DOWNLOAD_SRC=$(resolve_path "$2")
      shift # past argument
      shift # past value
      ;;
    --download-dest)
      DOWNLOAD_DEST=$(resolve_path "$2")
      shift # past argument
      shift # past value
      ;;
    --upload-src)
      UPLOAD_SRC=$(resolve_path "$2")
      shift # past argument
      shift # past value
      ;;
    --upload-dest)
      UPLOAD_DEST=$(resolve_path "$2")
      shift # past argument
      shift # past value
      ;;
    --shell)
      USE_SHELL=1
      shift # past argument
      ;;
    --version)
      set +x
      echo "$RUN_SH_VERSION"
      exit 0
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [ "$#" -lt 1 ]; then
  echo "Error: Incorrect number of arguments. Expected more than 1, got $#."
  show_help
  exit 1
fi

echo "Assigned to K8s node with hostname: $NODE_NAME"

echo "Setting ulimit to hard limit for open files and stack size..."
echo "Current ulimit:"
ulimit -a
echo "Current hard ulimit:"
ulimit -Ha
ulimit -n $(ulimit -Hn)
ulimit -s $(ulimit -Hs)
echo "Current ulimit:"
ulimit -a

if [ -n "$DOWNLOAD_SRC" ] || [ -n "$DOWNLOAD_DEST" ]; then
  if [ -e "$DOWNLOAD_DEST" ]; then
    if [ -d "$DOWNLOAD_DEST" ]; then
      echo "Directory exists at '$DOWNLOAD_DEST', deleting contents..."
      # dotglob catches hidden entries; nullglob keeps an empty directory from passing a
      # literal '*' to rm. The previous {*,.*} form expanded to '.' and '..', so it relied on
      # rm refusing those and on '|| true' to swallow the resulting error -- which also
      # swallowed genuine failures.
      ( shopt -s dotglob nullglob; rm -rf "$DOWNLOAD_DEST"/* )
    else
      echo "File exists at '$DOWNLOAD_DEST', deleting..."
      rm -f "$DOWNLOAD_DEST"
    fi
  fi
  echo "Copying files from '$DOWNLOAD_SRC' to '$DOWNLOAD_DEST'..."
  ( cd /omnicli && ./omnicli copy "$DOWNLOAD_SRC" "$DOWNLOAD_DEST" )
fi

echo "Will run commands: '$@'"
while [[ $# -gt 0 ]]; do
  echo "Running command: '$1'"
  if [ -n "$USE_SHELL" ]; then
    # Full shell semantics: expansion, quoting, pipes, redirects, operators. Commands share
    # one shell, so an export in an earlier command is visible to a later one.
    eval "$1"
  else
    # Default: unquoted word splitting only. No parameter expansion, so "$VAR" arrives
    # literally, and >, | and && become plain arguments rather than operators.
    $1
  fi
  shift
done

if [ -n "$UPLOAD_SRC" ] || [ -n "$UPLOAD_DEST" ]; then
  echo "Copying files from '$UPLOAD_SRC' to '$UPLOAD_DEST'..."
  ( cd /omnicli && ./omnicli copy "$UPLOAD_SRC" "$UPLOAD_DEST" )
fi
