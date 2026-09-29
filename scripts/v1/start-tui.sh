#!/bin/bash

# Start the v1 TUI against a running opencode backend.
#
# $1          1 when the opencode CLI is on the host (the launcher runs this
#             script itself), 0 when it runs as the container-side `tui`
#             service (see the entrypoint in docker-compose.yml). It is shifted
#             off so it never reaches opencode.
# $BACKEND_ORIGIN  where the backend answers: the published host port on the
#             host side, the compose service name inside the network.
#
# v1 has no shared background service: the TUI takes the backend as a
# subcommand argument (`opencode attach <url>`).

use_host="$1"
shift

if ((use_host)); then
    # `command` skips any exported shell function that could shadow the binary.
    # It is a builtin, so it cannot be combined with `exec`: running it as the
    # last statement keeps the script's exit status as the command's.
    command opencode attach "$BACKEND_ORIGIN" "$@"
else
    exec opencode attach "$BACKEND_ORIGIN" "$@"
fi
