#!/bin/bash
# Block until an opencode backend answers, then exit 0.
#
# scripts/launcher.sh runs this on whichever side can reach the backend: on the
# host when a host opencode CLI attaches to the published host port, inside the
# container otherwise (where the compose service name resolves but no host port
# exists). A single process does the polling, so waiting costs one
# `docker compose exec` instead of one per attempt.
#
# Usage: waitforserver [origin] [timeout]
#   origin   backend origin to poll, in precedence order: $1, $BACKEND_ORIGIN,
#            $OPENCODE_BACKEND_ORIGIN, then http://opencode:4096 (the only
#            origin that resolves from inside the container).
#   timeout  seconds to wait before giving up, in precedence order: $2,
#            $WAITFORSERVER_TIMEOUT, then 40.
#
# The origin itself is the probe: anything below 400 means the HTTP server is
# up, which is the same test the launcher's pre-wait health check makes.
#
set -uo pipefail

origin="${1:-${BACKEND_ORIGIN:-${OPENCODE_BACKEND_ORIGIN:-http://opencode:4096}}}"
timeout="${2:-${WAITFORSERVER_TIMEOUT:-40}}"

if ! [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "waitforserver: timeout must be a positive whole number of seconds, got '$timeout'" >&2
    exit 2
fi

# Columns the progress line may use: the terminal's own width when it reports
# one, never more than 80, and never so few that the bar disappears. A fixed
# width per wait keeps the redraws from resizing as the numbers change.
progress_width() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
        cols="$(tput cols 2>/dev/null || true)"
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    ((cols > 80)) && cols=80
    ((cols < 24)) && cols=24
    printf '%s' "$cols"
}

# Redraw the progress bar in place on a single line: a carriage return, the bar,
# and the numbers behind it. The bar is full at 100%, i.e. once the whole
# timeout has been waited, and each poll advances it by the share of the timeout
# that poll consumed. The elapsed time is what drives the fill, so time spent
# inside curl counts the same as time spent sleeping.
#   progress <elapsed-seconds> <timeout-seconds> <columns> [<percent>]
progress() {
    local elapsed="$1" limit="$2" width="$3" percent="${4:-}"

    if [[ -z "$percent" ]]; then
        percent=$((elapsed * 100 / limit))
        ((percent > 100)) && percent=100
    fi

    # Room for the bar is what the status text leaves over, brackets included.
    # The percent is padded and elapsed never exceeds the timeout, so the status
    # keeps its width for the whole wait and a shorter redraw cannot leave
    # characters from the previous one behind.
    status="$(printf '%3d%% %ss/%ss' "$percent" "$elapsed" "$limit")"
    bar_width=$((width - ${#status} - 2))
    ((bar_width > 0)) || bar_width=1

    filled=$((percent * bar_width / 100))
    printf -v filled_span '%*s' "$filled" ''
    printf -v empty_span '%*s' "$((bar_width - filled))" ''
    printf '\r[%s%s] %s' "${filled_span// /#}" "${empty_span// /.}" "$status"
}

# The deadline is wall clock from the first probe, not a count of sleeps: the
# time curl spends in each attempt counts against the timeout, so a backend that
# accepts connections but never answers (or a slow DNS lookup) cannot stretch
# the wait past its budget.
start=$(date +%s)
columns="$(progress_width)"
while true; do
    # -s/-f keep the poll quiet and treat any non-error status as "up"; the
    # short timeouts stop a wedged backend from stalling the whole attempt.
    if curl -fs --connect-timeout 2 --max-time 5 -o /dev/null "$origin" 2>/dev/null; then
        progress "$(($(date +%s) - start))" "$timeout" "$columns" 100
        printf '\n'
        exit 0
    fi

    elapsed=$(($(date +%s) - start))
    progress "$elapsed" "$timeout" "$columns"

    if ((elapsed > timeout)); then
        printf '\n'
        echo "Timed out after ${elapsed}s (limit ${timeout}s) waiting for $origin" >&2
        exit 1
    fi

    sleep 1
done
