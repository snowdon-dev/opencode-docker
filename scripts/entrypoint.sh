#!/bin/bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Your existing root-only workspace setup
if [ -n "$PROJECT_WORKSPACE" ] &&
   [ ! -e "$PROJECT_WORKSPACE" ] &&
   [ ! -d "$PROJECT_WORKSPACE" ]; then
    dir="$(dirname "$PROJECT_WORKSPACE")"
    mkdir -p "$dir"
    chown -R "$HOST_UID:$HOST_GID" "$dir"
    ln -s "/workspace/project" "$PROJECT_WORKSPACE"
fi

# Run the requested command as the host user/group.
exec su-exec "$HOST_UID:$HOST_GID" "$@"

