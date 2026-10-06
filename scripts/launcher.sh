#!/usr/bin/env bash

# FEATURE: mark running processes (e.g. bg task counts) so `ls` can show them;
# the repl already marks its own.
# FEATURE: a repl should keep the server open until the repl dies (a normal
# start closes it with the TUI).
# FEATURE: read launcher env vars from an env file usable outside any
# OPENCODE_WORKSPACE (no zsh profile needed).

set -euo pipefail

SD_OPENCODE="${SD_OPENCODE:-$HOME/opencode}"
SD_REPO_HOME="${SD_REPO_HOME:-/home/${USER:-}/repos}"

LABEL_CONTAINER_PROJECT_NAME="com.docker.compose.project"
LABEL_ONE_OFF="com.docker.compose.oneoff"

LABEL_MANAGED_OPENCODE="dev.snowdon.opencode.managed"
LABEL_WORKSPACE_OPENCODE="dev.snowdon.opencode.workspace"
LABEL_DEV_CONTAINER="dev.snowdon.image.opencode.devcontainer"
LABEL_DEV_CONTAINER_VERSION="dev.snowdon.image.opencode.version"
LABEL_IMAGE_WORKSPACE="dev.snowdon.opencode.workspace"
LABEL_NETWORK_MANAGED="dev.snowdon.opencode.managed"
LABEL_NETWORK_WORKSPACE="dev.snowdon.opencode.workspace"
LABEL_TUI_OPENCODE="dev.snowdon.opencode.tui"
# Worktree parent of a workspace: on the container (docker ps) and, same key,
# on a worktree's image and network (`docker image ls` / `docker network ls`).
# Those labels outlive the container, relating a worktree's resources to its
# repository once it is gone (see _ws_resource_ls).
LABEL_PARENT_OPENCODE="dev.snowdon.opencode.parent"
LABEL_WORKSPACE_PARENT_OPENCODE="dev.snowdon.opencode.workspace_parent"

LOOPBACK="127.0.0.1"

COMPOSE_NET_DIR="$SD_OPENCODE/compose/net"
COMPOSE_VOL_DIR="$SD_OPENCODE/compose/vol"
COMPOSE_SYS_DIR="$SD_OPENCODE/compose/sys"
COMPOSE_IMAGE_DIR="$SD_OPENCODE/compose/image"
COMPOSE_ENV_DIR="$SD_OPENCODE/compose/env"
COMPOSE_SECRET_DIR="$SD_OPENCODE/compose/secret"

TREE_ROOT="${SD_AGENT_TREE_ROOT:-$SD_REPO_HOME/agent-trees}"

# Global root Dockerfile, when it exists
ROOT_DOCKERFILE_PATH="$SD_OPENCODE/Dockerfile"

DOCKER_ARGS="${DOCKER_ARGS:-}"
SD_YOLO_HOME="${SD_YOLO_HOME:-false}"
SD_YOLO="${SD_YOLO:-false}"

OPENCODE_COMPOSE="${OPENCODE_COMPOSE:-}"
OPENCODE_CPUSET="${OPENCODE_CPUSET:-}"
OPENCODE_CPUS="${OPENCODE_CPUS:-}"

# Host file the api key secret is read from before every launch; only read to
# decide whether the secret is merged (compose/secret/). compose mounts the
# file itself at /run/secrets/api_key, so only this path - exported for the
# secret's `file:` interpolation - enters the environment, never the key.
OPENCODE_KEY_FILE="${OPENCODE_KEY_FILE:-$HOME/.config/opencode-docker/opencode.key}"
export OPENCODE_KEY_FILE

# .git dirs mount read-only by default; SD_READ_ONLY=false opts out (see
# _opencode_args_prepare).
SD_READ_ONLY="${SD_READ_ONLY:-true}"
if [[ "$SD_READ_ONLY" != true ]]; then
    global_skip_assert_worktree=1
fi

# Container environment

CONTAINER_WORKSPACE_ROOT="/workspace/project"
CONTAINER_USER="${OPENCODE_CONTAINER_USER:-other}"
CONTAINER_HOME="${OPENCODE_CONTAINER_HOME:-/home/${CONTAINER_USER}}"

# Published images are tagged <variant>-<version>: one opencode version layer
# (opencode/Dockerfile.v1, v2 sibling) per variant, on shared toolchain bases.
# IMAGE_VERSION picks the layer for the workspace and throwaway tui images,
# the tui's client config file, and the host-side start-tui helper (v2 dropped
# `opencode attach` for `--server`).

image_url_set=false
[[ -n "${OPENCODE_IMAGE_URL:-}" ]] && image_url_set=true
IMAGE_VERSION="${OPENCODE_IMAGE_VERSION:-}"
IMAGE_COMPONENT=""
IMAGE_URL="${OPENCODE_IMAGE_URL:-devsnowdon/opencode-docker:duck-${IMAGE_VERSION:-v1}}"
OPENCODE_IMAGE_URL_TUI="${OPENCODE_IMAGE_URL_TUI:-devsnowdon/opencode-docker:empty-${IMAGE_VERSION:-v1}}"
export OPENCODE_IMAGE_URL_TUI

function parse_cache() {
    if [[ -n "${OPENCODE_CACHE:-}" ]]; then
        # Validate before deriving anything from the request, so a typo fails
        # the same way whether or not OPENCODE_CACHE also picks the variant
        # below. Classifying by scanning for known ids would silently drop
        # unknown ones, turning a typo into a bigger cache set ("go bogus" ->
        # full toolchain).
        local id
        local cache_lower="${OPENCODE_CACHE,,}"
        for id in $cache_lower; do
            case "$id" in
            all | false | go | rust | python | node) ;;
            *)
                echo "Error: unknown toolchain cache id: $id (valid ids: all, go, node, python, rust)" >&2
                exit 1
                ;;
            esac
        done

        local is_duck=0 is_full=0
        if [[ "$cache_lower" == "all" ]]; then
            is_full=1
        elif [[ "$cache_lower" != "false" ]]; then
            for id in $cache_lower; do
                case "$id" in
                go | rust) is_full=1 ;;
                python | node) is_duck=1 ;;
                esac
            done
        else
            echo "Running without toolchain cache"
        fi
        if [[ "$image_url_set" == false ]]; then
            # Variant follows the requested cache
            IMAGE_URL="devsnowdon/opencode-docker:"
            IMAGE_VERSION=v2
            if ((is_full)); then
                IMAGE_COMPONENT="full"
                OPENCODE_IMAGE_URL+="full-$IMAGE_VERSION"
                OPENCODE_CACHE="go rust python node"
            elif ((is_duck)); then
                IMAGE_COMPONENT="duck"
                OPENCODE_IMAGE_URL+="duck-$IMAGE_VERSION"
                OPENCODE_CACHE="python node"
            else
                IMAGE_COMPONENT="empty"
                OPENCODE_IMAGE_URL+="empty-$IMAGE_VERSION"
                OPENCODE_CACHE=""
            fi
            IMAGE_URL="$OPENCODE_IMAGE_URL"
            export OPENCODE_IMAGE_URL
        fi
    fi
}

function parse_image_url() {
    # Set by the user: nothing to derive
    if [[ -n "$IMAGE_VERSION" ]]; then
        return
    fi

    local prefixes=(
        'registry.lan:5000/snowdon-dev/opencode:'
        'devsnowdon/opencode-docker:'
    )

    local matched=false

    for prefix in "${prefixes[@]}"; do
        if [[ "$IMAGE_URL" == "$prefix"* ]]; then
            matched=true

            local tag="${IMAGE_URL#"$prefix"}"

            # Expected format: <component>-v<version>
            if [[ "$tag" != *-v* ]]; then
                echo "Error: invalid image tag '$tag' (expected <component>-v<version>)" >&2
                return 1
            fi

            local component="${tag%%-v*}"
            local version="${tag#"$component-v"}"

            # Validate component.
            case "$component" in
            empty | full | duck)
                ;;
            *)
                echo "Error: invalid component '$component' (expected empty, full, or duck)" >&2
                return 1
                ;;
            esac

            # Validate version.
            if [[ ! "$version" =~ ^[1-2]+$ ]]; then
                echo "Error: invalid version '$version' (expected a number)" >&2
                return 1
            fi

            IMAGE_COMPONENT="$component"
            IMAGE_VERSION="v$version"
            break
        fi
    done

    # Unknown prefix: custom URL, no validation
    if [[ "$matched" != true ]]; then
        echo "NOTICE: custom image URL '$OPENCODE_IMAGE_URL'" >&2
        return 0
    fi
}

parse_cache
parse_image_url

if [[ -z "$IMAGE_VERSION" ]]; then
    echo "Error: IMAGE_VERSION is not set, and is required." >&2
    echo "Set the environment variable OPENCODE_IMAGE_VERSION to set it manually" >&2
    exit 1
fi

# Per-version opencode CLI details, both picked from IMAGE_VERSION:
#   OPENCODE_CLIENT_CONFIG  client config file in ~/.config/opencode, mounted
#       read-only into the tui from the repository copy (docker-compose.yml),
#       so edits apply without an image rebuild. v1 layers tui.json next to the
#       shared config; v2 has a single global cli.json.
#   OPENCODE_HEALTH_PATH    unauthenticated readiness endpoint the backend
#       health check and wait poll. v1 serves /api/health; v2 /global/health.
#       Probing it rather than the origin keeps the check working with
#       OPENCODE_SERVER_PASSWORD set.
# Unknown version keeps the v1 values: the image it selects does not exist
# either, and the launcher reports that itself.
#case "$IMAGE_VERSION" in
#    v1)
#        OPENCODE_HEALTH_PATH="/api/health"
#        ;;
#    v2)
#        OPENCODE_HEALTH_PATH="/"
#        ;;
#    *)
#        echo "Warning: unknown OPENCODE_IMAGE_VERSION '$IMAGE_VERSION', assuming the v1 client" >&2
#        OPENCODE_HEALTH_PATH="/api/health"
#        ;;
#esac

function _set_opencode_image_info() {
    if [[ -f "${OPENCODE_DOCKERFILE:-}" ]] && [[ -z "${OPENCODE_CONTEXT:-}" ]]; then
        tmpdpath="$(realpath "$OPENCODE_DOCKERFILE")"
        OPENCODE_CONTEXT="$(dirname "$tmpdpath")"
        OPENCODE_DOCKERFILE="$tmpdpath"
        export OPENCODE_CONTEXT OPENCODE_DOCKERFILE
    fi
}

_set_opencode_image_info

OPENCODE_DOCKERFILE="${OPENCODE_DOCKERFILE:-}"
OPENCODE_CONTEXT="${OPENCODE_CONTEXT:-}"

# DIR beats ROOT (the assert-dirs-exists method): an explicit per-project dir
# is what must exist, so it becomes the root from there on. The right-hand
# sides must stay the DIR values: reading the ROOT back was a self-assignment
# that, with the repl child re-sourcing this file (roots are plain vars, only
# dirs exported by the parent), hit an unbound variable under `set -u` and
# killed every repl at startup.
[[ -n "${OPENCODE_CACHE_DIR:-}" ]] && OPENCODE_CACHE_ROOT="$OPENCODE_CACHE_DIR"
[[ -n "${OPENCODE_DATA_DIR:-}" ]] && OPENCODE_DATA_ROOT="$OPENCODE_DATA_DIR"
[[ -n "${OPENCODE_CONFIG_DIR:-}" ]] && OPENCODE_CONFIG_ROOT="$OPENCODE_CONFIG_DIR"
OPENCODE_CONFIG_ROOT="${OPENCODE_CONFIG_ROOT:-"$HOME/.config/opencode-docker"}"
OPENCODE_DATA_ROOT="${OPENCODE_DATA_ROOT:-"$HOME/.local/share/opencode-docker"}"
OPENCODE_CACHE_ROOT="${OPENCODE_CACHE_ROOT:-"$HOME/.cache/opencode-docker"}"

# Managed network range: explicit CIDR ("172.20.0.0/16") or bare prefix, mask
# implied at 8 bits per octet ("172.20" -> /16).
NETWORK_RANGE="${OPENCODE_NET_RANGE:-172.20.0.0/16}"
# Mask of each network inside the range (a /16 slices into 256 /24s).
NET_SUBNET_MASK="${OPENCODE_NET_SUBNET:-29}"

# Container-side executables, installed at /usr/local/bin (opencode/Dockerfile.v1
# and its v2 sibling). start-tui is the only one also run on the host, straight
# from the repository, like waitforserver below: the CLI entrypoint that
# connects to the backend is version-specific (`opencode attach <url>` in v1,
# `opencode --server <url>` in v2).

GIT_CHANGES_EXE="git-changes"
END_BACKEND_SERVE_EXE="end-serve-backend"
START_BACKEND_SERVE_EXE="start-serve-backend"
START_TUI_EXE="start-tui"
START_TUI_EXE_HOST="$SD_OPENCODE/scripts/$IMAGE_VERSION/start-tui.sh"
WAIT_FOR_SERVER_EXE="waitforserver"

# Host-side copy of the backend wait; the image has its own at
# /usr/local/bin/waitforserver (dev/Dockerfile) for the in-container case.
WAITFORSERVER="$SD_OPENCODE/scripts/waitforserver.sh"

THIS_OTHER_ERROR="Error: Combinding --other,-o and --this,-t is invalid and equivalent no not specifying either."

# Cleanup
#
# Everything the EXIT trap can call is defined here, before the trap is armed
# and before anything that can exit early: the script is sourced, so an exit
# part-way (unknown cache id, no docker/podman on PATH) still runs the
# registered handlers, and one defined further down would not exist yet
# ("_cleanup: command not found" on top of the real error).

# Remove the merged docker-compose temp files
function _cleanup() {
    if [[ -n "$tmp_sd_root_dir" && -d "$tmp_sd_root_dir" ]]; then
        rm -rf -- "$tmp_sd_root_dir"
    fi
}

_cleanup_scaffold_name=""
_cleanup_scaffold_pid=""
_cleanup_scaffold_output=""

_cleanup_changes_name=""
_cleanup_changes_pid=""
_cleanup_changes_output=""

_cleanup_bg_name=""
_cleanup_bg_pid=""
_cleanup_bg_output=""

# An io-style run's in-flight state (io, changes --output): container name and
# compose client pid of the run still waiting (cleared once done: `run --rm`
# then dropped the container, and only an interrupted run leaves anything for
# the cleanup), plus the temp file its output streams into.
_cleanup_io_name=""
_cleanup_io_pid=""
_cleanup_io_outfile=""

_cleanup_repl_rcfile=""

if command -v git >/dev/null 2>&1; then
    has_git=true
else
    has_git=false
fi

declare -ga _cleanup_stack=()

_cleanup_run() {
    local i
    for ((i = ${#_cleanup_stack[@]} - 1; i >= 0; i--)); do
        "${_cleanup_stack[i]}"
    done
    _cleanup_stack=()
}
cleanup_add() {
    _cleanup_stack+=("$1")
}

cleanup_add _cleanup

# Create runtime variables

# Cleanup and signal traps
trap _cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Parsed NETWORK_RANGE: 32-bit base and prefix length (set by _net_parse).
net_base=""
net_mask=""

# Compose project name
oc_project_name=""

# Args used when creating the compose project (merged compose file)
opencode_compose_args=""

# Resolved backend origin (http://host:port) for the health check and the
# host-side TUI. Set once by opencode() after the container is up; the host
# port is random when docker-compose.yml publishes "0:4096".
backend_origin=""

# DRY_RUN=1 (the destructive commands' --dry-run flag) makes stop, delete and
# down report instead of acting: the destructive primitives below print the
# would-be command and succeed without touching a container, network or image.
# Read-only discovery still runs, so a dry run reports the real targets.
dry_run=0

# Set when actions should not assert the current workspace has a synced
# worktree, e.g. operations that release the lock.
global_skip_assert_worktree=0

network_name=""

# Global process-lifecycle storage, created before use (compose commands only)
tmp_sd_root_dir="$(mktemp -d)"
tmp_compose_dir="$tmp_sd_root_dir/compose"
tmp_compose_file=""
tmp_labels_file=""
tmp_io_file=""

# --- container driver init ---------------------------------------------------
# Only 'docker' is implemented; 'podman' is reserved (stubs below). 'auto'
# prefers docker, falling back to podman.
SD_DRIVER="${SD_DRIVER:-auto}"
DRIVER=""
case "${SD_DRIVER,,}" in
docker)
    DRIVER=docker
    ;;
podman)
    DRIVER=podman
    ;;
auto)
    if command -v docker >/dev/null 2>&1; then
        DRIVER=docker
    elif command -v podman >/dev/null 2>&1; then
        DRIVER=podman
    else
        echo "error: SD_DRIVER=auto found neither docker nor podman on PATH" >&2
        exit 1
    fi
    ;;
*)
    echo "error: unknown SD_DRIVER: $SD_DRIVER (valid: auto, docker, podman)" >&2
    exit 1
    ;;
esac

if [[ "$DRIVER" == "podman" ]]; then
    echo "error: the podman driver is not implemented yet; only docker is supported" >&2
    exit 1
fi

# Pass arbitrary args to docker
function docker_exec() {
    local -a docker_args=()
    if [[ -n ${DOCKER_ARGS:-} ]]; then
        read -r -a docker_args <<<"$DOCKER_ARGS"
    fi
    docker "${docker_args[@]}" "$@"
}

# Dispatch an operation to the active driver: _driver <op> [args...] runs
# ${DRIVER}_<op>. Every op is docker_<op> and (future drivers) <driver>_<op>,
# so adding a driver only means adding those functions.
function _driver() {
    local op="$1"
    shift
    "${DRIVER}_${op}" "$@"
}

# Run through docker_exec unless DRY_RUN is active, in which case print the
# command and succeed without executing. Wraps only the destructive primitives
# (stop/kill/rm, image/network rm), so discovery still runs on a dry run.
function _docker_run_destructive() {
    if ((dry_run)); then
        echo "DRY RUN: docker $*"
        return 0
    fi
    docker_exec "$@"
}

# --- docker driver -------------------------------------------------------
# Wraps docker_exec (which prepends DOCKER_ARGS) for every needed operation.
# The podman_<op> stubs mark the future driver's shape.

function docker_info() { docker_exec info; }
function docker_compose() {
    local -a compose_args=()
    if [[ -n ${COMPOSE_ARGS:-} ]]; then
        read -r -a compose_args <<<"$COMPOSE_ARGS"
    fi
    docker_exec compose "${compose_args[@]}" "$@"
}
function docker_network_ls() { docker_exec network ls "$@"; }
function docker_network_subnets() {
    docker_exec network inspect "$@" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
}
function docker_network_name() { docker_exec network inspect "$1" --format '{{.Name}}'; }
# Workspace a network was created for: its workspace label's value, empty when
# no launcher label at all. The status is docker's, so an existing network
# succeeds whether or not it is ours, while a missing id or name fails -
# _explain_network_create_failure reads both to tell the cases apart.
function docker_network_workspace() {
    docker_exec network inspect "$1" \
        --format "{{index .Labels \"$LABEL_NETWORK_WORKSPACE\"}}"
}
function docker_network_create() {
    local name="$1" subnet="$2" workspace="$3" parent="${4:-}"
    local -a args=(
        network create
        --driver bridge
        --subnet="$subnet"
        --label="$LABEL_NETWORK_MANAGED=true"
        --label="$LABEL_NETWORK_WORKSPACE=$workspace"
    )
    # A launcher-created network is external to compose, so compose ignores the
    # labels it declares for it: the worktree parent is recorded here instead,
    # matching the label the compose merge puts on a compose-created network.
    # Empty for a non-worktree workspace.
    [[ -n "$parent" ]] &&
        args+=("--label=$LABEL_WORKSPACE_PARENT_OPENCODE=$parent")
    docker_exec "${args[@]}" "$name"
}
function docker_network_rm() { _docker_run_destructive network rm "$@"; }
function docker_container_ls() { docker_exec ps "$@"; }
function docker_container_inspect() { docker_exec inspect "$@"; }
function docker_container_rm() { _docker_run_destructive rm "$@"; }
function docker_container_kill() { _docker_run_destructive kill "$@"; }
function docker_container_stop() { _docker_run_destructive stop "$@"; }
function docker_container_exec() { docker_exec exec "$@"; }
function docker_image_ls() { docker_exec image ls "$@"; }
function docker_image_rm() { _docker_run_destructive image rm "$@"; }
function docker_image_inspect() { docker_exec image inspect "$@"; }

# --- podman driver (stubs: not implemented yet) --------------------------
function _podman_stub() {
    echo "error: podman driver: '$1' not implemented yet" >&2
    return 1
}
function podman_info() { _podman_stub info; }
function podman_compose() { _podman_stub compose; }
function podman_network_ls() { _podman_stub network_ls; }
function podman_network_subnets() { _podman_stub network_subnets; }
function podman_network_name() { _podman_stub network_name; }
function podman_network_workspace() { _podman_stub network_workspace; }
function podman_network_create() { _podman_stub network_create; }
function podman_network_rm() { _podman_stub network_rm; }
function podman_container_ls() { _podman_stub container_ls; }
function podman_container_inspect() { _podman_stub container_inspect; }
function podman_container_rm() { _podman_stub container_rm; }
function podman_container_kill() { _podman_stub container_kill; }
function podman_container_stop() { _podman_stub container_stop; }
function podman_container_exec() { _podman_stub container_exec; }
function podman_image_ls() { _podman_stub image_ls; }
function podman_image_rm() { _podman_stub image_rm; }
function podman_image_inspect() { _podman_stub image_inspect; }

# --- app code ----------------------------------------------------------------
# Parse OPENCODE_NET_RANGE (CIDR "172.20.0.0/16" or bare prefix "172.20", mask
# implied at 8 bits/octet) into net_base (32-bit address) and net_mask (prefix).
function _net_parse() {
    local addr="${NETWORK_RANGE%%/*}"
    local mask="${NETWORK_RANGE##*/}"
    local -a octs
    IFS='.' read -r -a octs <<<"$addr"

    if ((${#octs[@]} < 1 || ${#octs[@]} > 4)); then
        echo "error: OPENCODE_NET_RANGE must have 1-4 octets (e.g. 172.20 or 172.20.0.0/16)" >&2
        return 1
    fi
    local o
    for ((o = 0; o < ${#octs[@]}; o++)); do
        if [[ ! "${octs[o]}" =~ ^[0-9]{1,3}$ ]] || ((10#${octs[o]} > 255)); then
            echo "error: invalid octet in OPENCODE_NET_RANGE: ${octs[o]}" >&2
            return 1
        fi
    done

    # A bare prefix implies 8 bits per given octet (172.20 -> /16), capped at /29
    if [[ "$NETWORK_RANGE" != */* ]]; then
        mask=$((${#octs[@]} * 8))
        ((mask > 29)) && mask=29
    fi
    if [[ ! "$mask" =~ ^[0-9]{1,2}$ ]] || ((mask < 1 || mask > 29)); then
        echo "error: OPENCODE_NET_RANGE mask must be between /1 and /29" >&2
        return 1
    fi

    local v=0
    for ((o = 0; o < 4; o++)); do
        ((v = (v << 8) | ${octs[o]:-0}))
    done

    net_mask=$mask
    # zero the host bits
    ((net_base = v & (0xFFFFFFFF << (32 - mask))))

    return 0
}

function int_to_ip4() {
    local v="$(($1 & 0xFFFFFFFF))"
    printf '%d.%d.%d.%d' \
        $(((v >> 24) & 255)) \
        $(((v >> 16) & 255)) \
        $(((v >> 8) & 255)) \
        $((v & 255))
}

function find_free_network() {
    if [[ ! "$NET_SUBNET_MASK" =~ ^[0-9]{1,2}$ ]] ||
        ((NET_SUBNET_MASK < 1 || NET_SUBNET_MASK > 29)); then
        echo "error: OPENCODE_NET_SUBNET must be between /1 and /29" >&2
        return 1
    fi

    if ! _net_parse; then
        return 1
    fi

    # A subnet wider than the range overlaps every slice of it; reject it.
    if ((NET_SUBNET_MASK < net_mask)); then
        echo "error: OPENCODE_NET_SUBNET (/$NET_SUBNET_MASK) must not be smaller than the network range mask (/$net_mask)" >&2
        return 1
    fi

    # Could search for the chosen network instead of loading all into memory:
    # inspect the first N `ls` results, fall back to loading all when none
    # matches. Only worth it for small-to-medium network counts; a large
    # number needs loading them all anyway.
    local -A used_networks
    local -a networks
    mapfile -t networks < <(_driver network_ls -q --filter "label=$LABEL_NETWORK_MANAGED=true")
    if ((${#networks[@]})); then
        while IFS= read -r subnet; do
            [[ -z "$subnet" ]] && continue
            used_networks["$subnet"]=1
        done < <(_driver network_subnets "${networks[@]}")
    fi

    # Slice the range into fixed-size subnets: a smaller subnet mask indexes
    # the slice bits (a /16 range slices into 256 x /24); an equal mask is a
    # single subnet (index 0).
    local count
    if ((NET_SUBNET_MASK > net_mask)); then
        ((count = 1 << (NET_SUBNET_MASK - net_mask)))
    else
        count=1
    fi

    # Randomize the search order so concurrent projects rarely collide.
    # count is a power of 2 (1 << free_bits), so any odd step is coprime to
    # it and every slot is visited exactly once. Two combined $RANDOM values
    # (each 0-32767) give a wider range.
    local start=0 step=1
    if ((count > 1)); then
        ((start = ((RANDOM << 15) | RANDOM) % count))
        ((step = 1 + 2 * (((RANDOM << 15) | RANDOM) % (count / 2))))
    fi

    local i idx addr a b c d
    for ((i = 0; i < count; i++)); do
        ((idx = (start + i * step) % count))
        ((addr = net_base | (idx << (32 - NET_SUBNET_MASK))))
        ((a = (addr >> 24) & 255))
        ((b = (addr >> 16) & 255))
        ((c = (addr >> 8) & 255))
        ((d = addr & 255))
        subnet="$a.$b.$c.$d/$NET_SUBNET_MASK"
        if [[ -z "${used_networks[$subnet]+x}" ]]; then
            printf '%s' "$subnet"
            return 0
        fi
    done

    return 1
}

# Create a docker network for the compose file. The optional third argument is
# the worktree parent of the workspace, recorded as a label (see
# docker_network_create).
#
# FEATURE: create network as a compose network, not external
# FEATURE: when doing a opencode:down, still tries create a network
# FEATURE: bg/scaffold leave their one-off network behind; bg could delete it
# for one-off runs, since it creates it.
function _network_builder() {
    local available_subnet nid
    local proj="$1"
    local workspace="$2"
    local parent="${3:-}"

    # Find an existing network. The lookup keys on the workspace path, so a
    # moved (renamed) workspace finds nothing although its network lives under
    # a name derived from the project; the create below then hits the
    # duplicate, diagnosed there instead of as a bare failure (see
    # _explain_network_create_failure).
    nid=$(
        _driver network_ls -q \
            --filter "label=$LABEL_NETWORK_MANAGED=true" \
            --filter "label=$LABEL_NETWORK_WORKSPACE=$workspace"
    )
    if [[ -n "$nid" ]]; then
        if network_name=$(_driver network_name "$nid" 2>/dev/null); then
            return 0
        else
            echo "Failed to inspect existing network"
            return 1
        fi
    fi

    # New network
    network_name="sd-$proj-default"

    available_subnet="$(find_free_network)" || {
        echo "No free subnet available" >&2
        return 1
    }

    # Only stdout (the new network id) is discarded: docker's own error stays
    # on stderr, where it is the whole story when nothing below explains it.
    if _driver network_create "$network_name" "$available_subnet" "$workspace" \
        "$parent" >/dev/null; then
        return 0
    fi

    # Names are unique, so a network of this name stopped the create; report
    # what holds it, or the plain failure.
    _explain_network_create_failure "$network_name" "$workspace"
}

# Report why `docker network create <name>` failed; returns the status the
# caller acts on (1 in every reporting case, 0 only for a concurrent launch).
# The lookup inspects that exact name: `network ls --filter name=` matches on
# part of a name, and filtering to managed networks would hide the very
# networks the launcher did not create. What it turns out to be:
#   - another workspace's: the workspace moved/renamed since (the lookup keyed
#     on the new path and missed it) - warn about exactly that and name the
#     removal that clears it;
#   - no launcher label: some other network took the name;
#   - this workspace's: a concurrent launch created it between lookup and
#     create - report nothing, return 0, the wanted network is there;
#   - no such network: nothing holds the name, only the plain failure prints
#     (docker's own error already showed).
#   _explain_network_create_failure <network-name> <workspace>
function _explain_network_create_failure() {
    local name="$1" workspace="$2"
    local owner

    if ! owner="$(_driver network_workspace "$name" 2>/dev/null)"; then
        echo "Network failed to create with name ($name)" >&2
        return 1
    fi

    if [[ "$owner" == "$workspace" ]]; then
        return 0
    fi

    if [[ -z "$owner" ]]; then
        echo "error: a network named '$name' already exists, but not created by the launcher" >&2
        echo "error: remove it if nothing else needs it: docker network rm $name" >&2
        return 1
    fi

    echo "error: network '$name' already exists for another workspace: $owner" >&2
    echo "error: this workspace is '$workspace', so it moved or was renamed after that network was created" >&2
    echo "error: remove the stale network, then run again: docker network rm $name" >&2
    return 1
}

# Print current git details of the cwd
function _print_git_context() {
    if [[ "$has_git" == false ]]; then
        return
    fi
    if [[ ! -d .git ]]; then
        return
    fi

    printf '\nAdditional project context:\n'
    echo
    echo "The author details for this task:"
    echo "Name: $(git config --global user.name)"
    echo "Email: $(git config --global user.email)"
    echo
    echo "git log --oneline | head -50:"
    echo '```'
    git log --oneline | head -5 || true
    echo '```'
}

# Print the README of the cwd, when one exists
function _print_readme() {
    if [[ ! -f ./README.md ]]; then
        return
    fi
    printf '\nREADME.md (first 100 lines):\n'
    echo '```'
    head -n 100 README.md
    echo '```'
}

# Print the CPU resources granted to the agent, as configured. OPENCODE_CPUS
# (limit) beats OPENCODE_CPUSET (pinning) when both are set.
function _print_cpu_context() {
    if [[ -n "$OPENCODE_CPUS" ]]; then
        if [[ -n "$OPENCODE_CPUSET" ]]; then
            echo "You have access to a CPU limit of $OPENCODE_CPUS (takes precedence over CPUSET pinning: $OPENCODE_CPUSET)."
        else
            echo "You have access to a CPU limit of $OPENCODE_CPUS."
        fi
    elif [[ -n "$OPENCODE_CPUSET" ]]; then
        echo "You have access to the CPUSET: $OPENCODE_CPUSET"
    else
        echo "You have access to all available host CPUs (unrestricted)."
    fi
}

function _assert_file_is_yml() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Error: not a regular file: $file" >&2
        return 1
    fi

    case "${file,,}" in
    *.yml | *.yaml)
        return 0
        ;;
    *)
        echo "Error: Docker Compose file must have a .yml or .yaml extension: $file" >&2
        return 1
        ;;
    esac
}

function _sanitize_name() {
    local name="$1"

    name="${name,,}"               # lowercase
    name="${name//[^a-z0-9_.-]/-}" # invalid chars -> -
    while [[ "$name" == *--* ]]; do
        name="${name//--/-}"
    done
    name="${name#[-._]}"
    name="${name%[-._]}"

    printf '%s' "$name"
}

# FEATURE: only subdirectories of home were intended, but that is no longer
# asserted; other roots require path == root.
function _check_valid_within_root() {
    local ws_out home ws_norm valid_subdir root
    ws_out="$1"
    home="$2"

    # The stripped ws_out is written back through the nameref in param three
    # so approving callers can remember it. The temp is deliberately not named
    # ws_out_normalized: bash resolves namerefs innermost-first, so a
    # same-named local here would swallow the writeback.
    local -n normalized_out="$3"

    # Param four, when set, stores the validated roots; otherwise discarded
    local validated=""
    if [[ -n ${4+x} ]]; then
        local -n validated="$4"
    fi

    ws_norm=$ws_out
    while [[ $ws_norm != "/" && $ws_norm == */ ]]; do
        ws_norm=${ws_norm%/}
    done
    normalized_out=$ws_norm

    valid_subdir=0

    if [[ $home == "/" ]]; then
        # Any non-root absolute path is under "/".
        if [[ $ws_norm != "/" &&
            $ws_norm == /* ]]; then
            valid_subdir=1
        fi
    elif [[ $ws_norm == "$home" || $ws_norm == "$home"/* ]]; then
        # HOME itself and everything below it are valid roots.
        valid_subdir=1
    fi

    # A previously validated root counts as a home: at or below it passes.
    if ((!valid_subdir)) && [[ -n "$validated" ]]; then
        while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            if [[ $ws_norm == "$root" || $ws_norm == "$root"/* ]]; then
                valid_subdir=1
                break
            fi
        done <<<"$validated"
    fi

    if ((!valid_subdir)); then
        return 1
    else
        return 0
    fi
}

tmp_validated=""
# FEATURE: SD_REPO_HOME could allow multiple home directories
function _assert_maybe_check_outside_root() {
    if [[ "${SD_YOLO,,}" == "true" ]]; then
        return
    fi
    # Previously approved dirs become extra home roots: at or below one passes
    # without prompting again (workspace and its worktree parent, e.g.).
    # Trailing slashes removed, "/" preserved.
    local home ws_out ws_out_normalized
    ws_out="$1"
    if [[ "${SD_YOLO_HOME,,}" == "true" ]]; then
        home="$SD_REPO_HOME"
    else
        home="$HOME"
    fi
    while [[ $home != "/" && $home == */ ]]; do
        home=${home%/}
    done

    local answer=""
    if ! _check_valid_within_root "$ws_out" "$home" ws_out_normalized tmp_validated; then
        printf '%s is outside a subdirectory of HOME:\n  %s\n' "$ws_out" "$home"
        read -r -p "Continue anyway? [y/N] " answer </dev/tty || true

        case ${answer,,} in
        y | yes)
            # Remember it as an extra home root
            tmp_validated+="$ws_out_normalized"$'\n'
            ;;
        *)
            printf 'Aborted.\n' >&2
            exit 1
            ;;
        esac
    fi
}

# Print NUL-terminated .git dirs under <ws> for read-only mounting.
# Vendor/build/test-artifact dirs are pruned so throwaway nested repos (e.g.
# node_modules, tests/.tmp sandboxes) are neither mounted nor counted, keeping
# the compose config stable across invocations.
# FEATURE: Read the exclude list from .gitignore?
function _find_workspace_git_dirs() {
    local ws="$1"
    find "$ws" \
        \( -name node_modules -o -name .cargo -o -name target -o \
        -name .tmp -o -name vendor \) -prune -o \
        -type d -name .git -print0
}

# Print the parent repository's git dir when <git_path> is a worktree .git
# file, else nothing. A worktree's .git file starts with "gitdir: <path>",
# pointing into <parent>/.git/worktrees/<name>.
function _git_worktree_parent() {
    local git_path="$1"
    local gitdir parent
    [[ -f "$git_path" ]] || return 0
    gitdir="$(sed -n 's/^gitdir: //p' "$git_path")"
    [[ -n "$gitdir" ]] || return 0
    parent="${gitdir%/worktrees/*}"
    parent="${parent%/.git}"
    [[ -d "$parent" ]] || return 0
    printf '%s' "$parent"
}

# Print the ids of the images and networks of workspace <ws>: those labelled
# with the workspace itself plus those labelled with it as worktree parent
# (its worktrees' resources). Extra arguments are extra docker filters every
# query carries, e.g. the managed label a network must have to be ours.
#
# Docker ANDs --filter clauses, so a resource carrying both labels is only
# found by querying one label at a time; the two queries are unioned. The
# worktree-parent label makes `delete --this` then `delete --all --this`
# complete from a repository: a worktree's image and network are labelled with
# the repository as parent (build arg for the image, network label for the
# network) and, unlike the container's dev.snowdon.opencode.parent label,
# survive the container.
#   _ws_resource_ls <image|network> <workspace> [extra docker filters...]
function _ws_resource_ls() {
    local kind="$1" ws="$2"
    shift 2
    [[ -z "$ws" ]] && return 0

    local -a filters=("$@")
    local -A seen=()
    local id
    local label
    for label in "$LABEL_WORKSPACE_OPENCODE" "$LABEL_WORKSPACE_PARENT_OPENCODE"; do
        while IFS= read -r id; do
            [[ -z "$id" || -n "${seen[$id]:-}" ]] && continue
            seen["$id"]=1
            printf '%s\n' "$id"
        done < <(
            _driver "${kind}_ls" -q "${filters[@]}" \
                --filter "label=$label=$ws"
        )
    done
    return 0
}

# Write a Compose override mounting each entry of the array named by $1
# ("source:/container/path" pairs) read-only onto the opencode service. The
# tmp paths are set so the EXIT trap's _cleanup removes the override.
function _write_volume_overrides() {
    local -n mounts="$1"
    tmp_compose_file="$tmp_compose_dir/docker-compose.git.yml"
    {
        printf '%s\n' 'services:'
        printf '%s\n' '  opencode:'
        printf '%s\n' '    volumes:'
        for mount in "${mounts[@]}"; do
            printf '      - %s:ro\n' "$mount"
        done
    } >"$tmp_compose_file"
}

# Wrap a value in double quotes for the YAML the override writers emit,
# escaping backslashes and quotes so it stays one string: an unquoted
# "src:dst" scalar would end early on ": " and comment on "#". ("$" is not
# escaped: compose has no escape for it - see _write_labels_override.) Callers
# use command substitution, so only the quotes are printed.
#   _yaml_quote <value>
function _yaml_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

# Parse the output flags shared by io and changes into caller variables:
# --output/--output=<path> appends a writable output surface (repeatable,
# anywhere), --allow-empty sets the flag, everything else passes through in
# order. The first leftover argument is the task candidate (opencode run args
# never precede the task).
#
#   _opencode_parse_output_flags <out_outputs> <out_allow_empty> <out_rest> [args...]
#
# Sets (by nameref): out_outputs (the --output paths, in order),
# out_allow_empty (1 with --allow-empty), out_rest (everything else, in order).
function _opencode_parse_output_flags() {
    local -n out_outputs="$1"
    local -n out_allow_empty="$2"
    local -n out_rest="$3"
    shift 3

    out_outputs=()
    out_allow_empty=0
    out_rest=()

    while (($# > 0)); do
        case "$1" in
        --output)
            if (($# < 2)); then
                echo "Error: --output requires a path" >&2
                return 1
            fi
            out_outputs+=("$2")
            shift 2
            ;;
        --output=*)
            out_outputs+=("${1#--output=}")
            shift
            ;;
        --allow-empty)
            out_allow_empty=1
            shift
            ;;
        *)
            out_rest+=("$1")
            shift
            ;;
        esac
    done
}

# Write a Compose override for an io-style run (opencode:io, opencode:changes
# --output): the whole workspace mounts read-only and every output of the
# mounts array read-write, so the declared outputs are the only changeable
# things.
#
# Both entry kinds survive compose's merge rules: volumes are unique by
# container target, so the read-only workspace mount shares docker-compose.yml's
# target and replaces it (this override merges after that file), while each
# output's new target is appended. An output inside the workspace targets its
# natural path below /workspace/project, so its read-write mount shadows the
# read-only workspace mount exactly there - one filesystem tree, writable only
# at the outputs.
#
#   _write_io_override <workspace> <mounts-array-name>
#
# The mounts array alternates host and container path (no delimiter joining: a
# path may contain anything).
function _write_io_override() {
    local ws="$1"
    local -n _io_mounts="$2"
    tmp_io_file="$tmp_compose_dir/docker-compose.io.yml"
    {
        printf '%s\n' 'services:'
        printf '%s\n' '  opencode:'
        printf '%s\n' '    volumes:'
        printf '      - %s\n' "$(_yaml_quote "$ws:$CONTAINER_WORKSPACE_ROOT:ro")"
        local i
        for ((i = 0; i + 1 < ${#_io_mounts[@]}; i += 2)); do
            printf '      - %s\n' "$(_yaml_quote "${_io_mounts[i]}:${_io_mounts[i + 1]}")"
        done
    } >"$tmp_io_file"
}

# Prepare the writable output surfaces of an io-style run into parallel
# caller arrays. Each path is absolutised against the workspace and its parent
# canonicalised; the mode is the filesystem's (-d: directory) or the caller's
# (a trailing '/': a directory not created yet). Missing files are created and
# truncated, missing directories mkdir -p'd; the container target keeps the
# path's natural location inside the read-only workspace mount (see
# _write_io_override).
#
# Validation runs for every path before anything is created or truncated, so a
# rejected set leaves the host untouched: a file's parent must exist, no two
# outputs share a host path or container target, and none sits inside another
# (the inner mount would shadow the outer one's view).
#
#   _io_outputs_prepare <out_hosts> <out_containers> <out_is_dir> [output...]
#
# Sets (by nameref, parallel arrays): out_hosts (canonicalised host paths),
# out_containers (container mount points), out_is_dir (1 for a directory).
function _io_outputs_prepare() {
    local -n _prep_hosts="$1"
    local -n _prep_containers="$2"
    local -n _prep_is_dir="$3"
    shift 3

    _prep_hosts=()
    _prep_containers=()
    _prep_is_dir=()

    local raw host parent isdir

    # Pass one: resolve, detect mode, cross-check; nothing created yet.
    for raw in "$@"; do
        if [[ -z "$raw" ]]; then
            echo "Error: the output path is empty" >&2
            return 1
        fi
        host="$raw"
        case "$host" in
        /*) ;;
        *) host="$PWD/$host" ;;
        esac
        # A trailing slash means "directory, create it"; dropped so the mount
        # records a clean path either way.
        if [[ "$host" != "/" ]]; then
            while [[ "$host" == */ ]]; do
                host="${host%/}"
            done
        fi
        if [[ -d "$host" || "$raw" == */ ]]; then
            isdir=1
        else
            isdir=0
        fi

        # The path goes into a mount and compares against the workspace, so
        # "./plan.md" must not survive as "<ws>/./plan.md". Only the directory
        # is canonicalised (the output may not exist yet); a missing directory
        # is reported below in file mode and created in directory mode.
        parent="$(dirname -- "$host")"
        if [[ -d "$parent" ]]; then
            host="$(realpath -- "$parent")/$(basename -- "$host")"
        fi

        _prep_hosts+=("$host")
        _prep_is_dir+=("$isdir")
    done

    # Container mount point: its natural path inside the workspace, else the
    # same absolute path on both sides.
    local i j
    for ((i = 0; i < ${#_prep_hosts[@]}; i++)); do
        host="${_prep_hosts[i]}"
        case "$host" in
        "$oc_workspace"/*)
            _prep_containers+=("$CONTAINER_WORKSPACE_ROOT/${host#"$oc_workspace"/}")
            ;;
        *)
            _prep_containers+=("$host")
            ;;
        esac
    done

    # Cross-checks: each output needs its own host path and container target,
    # and none may live inside another - the inner mount would shadow the
    # outer one's content of that subtree.
    for ((i = 0; i < ${#_prep_hosts[@]}; i++)); do
        for ((j = i + 1; j < ${#_prep_hosts[@]}; j++)); do
            if [[ "${_prep_hosts[i]}" == "${_prep_hosts[j]}" ]]; then
                echo "Error: duplicate output: ${_prep_hosts[i]}" >&2
                return 1
            fi
            if [[ "${_prep_containers[i]}" == "${_prep_containers[j]}" ]]; then
                echo "Error: two outputs share the container path: ${_prep_containers[i]}" >&2
                return 1
            fi
            if [[ "${_prep_hosts[i]}" == "${_prep_hosts[j]}"/* ]]; then
                echo "Error: output inside another output: ${_prep_hosts[i]} is inside ${_prep_hosts[j]}" >&2
                return 1
            fi
            if [[ "${_prep_hosts[j]}" == "${_prep_hosts[i]}"/* ]]; then
                echo "Error: output inside another output: ${_prep_hosts[j]} is inside ${_prep_hosts[i]}" >&2
                return 1
            fi
        done
    done

    # Pass two: per-path validation that only matters once the set is sound -
    # a file needs its parent to exist, an existing output must be writable.
    for ((i = 0; i < ${#_prep_hosts[@]}; i++)); do
        host="${_prep_hosts[i]}"
        parent="$(dirname -- "$host")"
        if ((_prep_is_dir[i])); then
            if [[ -d "$host" && ! -w "$host" ]]; then
                echo "Error: the output directory is not writable: $host" >&2
                return 1
            fi
        else
            if [[ ! -d "$parent" ]]; then
                echo "Error: the output directory does not exist: $parent" >&2
                return 1
            fi
            if [[ -e "$host" && ! -w "$host" ]]; then
                echo "Error: the output file is not writable: $host" >&2
                return 1
            fi
        fi
    done

    # Pass three: create the outputs - missing directories with mkdir -p,
    # missing files emptied, existing files truncated, so a run's output never
    # mixes with an earlier run's leftovers.
    for ((i = 0; i < ${#_prep_hosts[@]}; i++)); do
        host="${_prep_hosts[i]}"
        if ((_prep_is_dir[i])); then
            if [[ ! -d "$host" ]] && ! mkdir -p -- "$host"; then
                echo "Error: cannot create the output directory: $host" >&2
                return 1
            fi
        else
            if [[ ! -e "$host" ]] && ! : >"$host"; then
                echo "Error: cannot create the output file: $host" >&2
                return 1
            fi
            if ! : >"$host"; then
                echo "Error: cannot truncate the output file: $host" >&2
                return 1
            fi
        fi
    done
}

# Emit the prompt fragment describing an io-style run's writable surfaces: the
# read-only statement, the per-surface list (directories marked, host path
# shown) and the instruction to write nothing anywhere else. Used by io always
# and by changes with declared outputs - one place for the instruction.
#
#   _print_writable_surfaces <out_hosts> <out_containers> <out_is_dir>
function _print_writable_surfaces() {
    local -n _ws_hosts="$1"
    local -n _ws_containers="$2"
    local -n _ws_is_dir="$3"

    local i kind
    echo "The workspace is mounted read-only: nothing under $CONTAINER_WORKSPACE_ROOT can be changed, so this task cannot modify the project."
    echo "Writable outputs (the only exception):"
    for ((i = 0; i < ${#_ws_hosts[@]}; i++)); do
        if ((_ws_is_dir[i])); then
            kind="directory"
        else
            kind="file"
        fi
        echo "- ${_ws_containers[i]} ($kind, kept on the host as ${_ws_hosts[i]})"
    done
    echo "Write your output only to the writable paths listed above and nothing else."
}

# Check the outputs of a finished io-style run: every file and directory must
# be non-empty, so an output truncated before the run and never written fails
# instead of handing an empty result on. One neutral error line per offender;
# skipped entirely with --allow-empty. Returns 1 when any output is empty.
#
#   _io_outputs_check <out_hosts> <out_is_dir> <allow_empty>
function _io_outputs_check() {
    local -n _chk_hosts="$1"
    local -n _chk_is_dir="$2"
    local allow_empty="$3"

    if ((allow_empty)); then
        return 0
    fi

    local i rc=0
    for ((i = 0; i < ${#_chk_hosts[@]}; i++)); do
        if ((_chk_is_dir[i])); then
            if [[ -z "$(ls -A -- "${_chk_hosts[i]}" 2>/dev/null)" ]]; then
                echo "Error: the run wrote no output to: ${_chk_hosts[i]}" >&2
                rc=1
            fi
        elif [[ ! -s "${_chk_hosts[i]}" ]]; then
            echo "Error: the run wrote no output to: ${_chk_hosts[i]}" >&2
            rc=1
        fi
    done
    return "$rc"
}

# Write a Compose override recording the worktree parent path in the labels of
# both resources the workspace owns. The file lives in tmp_compose_dir (cleaned
# up wholesale); tmp_labels_file lets the caller merge it into the args.
#
#   * services.opencode.labels carries dev.snowdon.opencode.parent on the
#     container, what container discovery selects on (`docker ps --filter
#     label=dev.snowdon.opencode.parent=<ws>`: the worktree-child probe, list
#     --parent, delete --other). It must stay: container queries cannot see an
#     image's or network's labels, and docker inherits no labels from a
#     container to its image or network.
#   * networks.extra-network.labels adds dev.snowdon.opencode.workspace_parent
#     to the labels already declared for the network in docker-compose.yml (and
#     compose/net/), so a worktree's network is identifiable from the network
#     side too. Compose merges `labels` key by key, adding to the
#     managed/workspace labels in either network form. The image carries the
#     same label from its own Dockerfile (Dockerfile.example), letting a
#     repository-scoped command reach a worktree's resources after its
#     container is gone (see _ws_resource_ls).
#
#   networks:
#       extra-network:
#           labels:
#               dev.snowdon.opencode.workspace_parent: "<parent_wt>"
function _write_labels_override() {
    local parent_wt="$1"
    parent_wt="${parent_wt%/}"
    tmp_labels_file="$tmp_compose_dir/docker-compose.labels.yml"

    # Both label forms are double quoted, with backslashes and quotes
    # escaped, so any path stays a YAML string: a bare "key=value" or
    # "key: value" scalar would break on ": ", "#" or a leading indicator
    # character. ("$" is not escaped: compose has no escape for it - see the
    # volume mounts of _write_volume_overrides.)
    local parent_quoted="${parent_wt//\\/\\\\}"
    parent_quoted="${parent_quoted//\"/\\\"}"

    {
        printf '%s\n' 'services:'
        printf '%s\n' '  opencode:'
        printf '%s\n' '    labels:'
        printf '      - "%s=%s"\n' "$LABEL_PARENT_OPENCODE" "$parent_quoted"
        printf '%s\n' 'networks:'
        printf '%s\n' '  extra-network:'
        printf '%s\n' '    labels:'
        printf '            %s: "%s"\n' "$LABEL_WORKSPACE_PARENT_OPENCODE" \
            "$parent_quoted"
    } >"$tmp_labels_file"
}

# Resolve the effective workspace for <path> in place, using the same git
# worktree resolution _opencode_args_prepare applies:
#
#   * A worktree (its .git is a file) keeps itself; the parent repo's git dir
#     comes back in has_parent so containers get the parent label.
#   * A parent repo with an in-sync worktree child container resolves to that
#     child (has_parent points back at the parent), so `opencode:up` etc. run
#     in the worktree from the parent directory; the canonical agent worktree
#     is preferred when several children exist. An explicit path is
#     authoritative and keeps the requested parent.
#   * A parent with no worktree children keeps itself.
#
# Sets ws_out and has_parent (namerefs) and updates PROJECT_NAME. Commands
# needing the current workspace without compose args (e.g. delete --all
# --other) use this to preserve the effective workspace, not raw $PWD. Exits
# on the same errors as the prepare path (ambiguous/un-synced children), so
# the resolution is identical wherever it runs.
#
# If the cwd is a worktree, resolve and use its parent .git dir; containers
# get dev.snowdon.opencode.parent=/path/to/parent/repository. Workspace
# container lookup also considers worktrees: `opencode:shell` from a worktree
# opens the worktree's container, not the parent's.
#
# Example:
# git worktree add ../repo-wt wt-branch
# opencode:up /path/to/repo-wt
#
# FEATURE: Support `--worktree <branch>` / `--wt <branch>` to create or reuse
#   a worktree at:
#   $HOME/.local/state/repo/<branch>
#
# With both a child and a parent up, an explicit path wins; without one, the
# canonical agent worktree wins when several children are available.

# Print the id of the canonical agent worktree container among the given ids.
# Canonical = the default agent worktree _get_worktree_info names
# (<project>-dev), what 'create --worktree' without a branch and 'uptree'
# without --branch use; branch worktrees are not canonical. Empty when none of
# the supplied containers represents it.
function _canonical_worktree_child() {
    local parent_workspace="$1"
    shift
    local canonical_name canonical_path rec child_path child
    local -a rec_fields=()
    _get_worktree_info canonical_name canonical_path \
        "$(_sanitize_name "$(basename "$parent_workspace")")"

    while IFS= read -r rec; do
        _rec_fields rec_fields "$rec"
        child="${rec_fields[0]:-}"
        child_path="${rec_fields[2]:-}"
        if [[ "$child_path" == "$canonical_path" ]]; then
            printf '%s\n' "$child"
            return 0
        fi
    done < <(_container_infos "$@")
}

function _resolve_effective_workspace() {
    local -n w="$1"
    local -n hp="$2"
    local path_given="${3:-0}" parent_workspace

    parent_workspace="$(_git_worktree_parent "$w/.git")"

    # A parent git repo
    if [[ -n "$parent_workspace" ]]; then
        hp="$parent_workspace"
        return 0
    fi
    # No git at all
    if [[ "$has_git" == false ]]; then
        return 0
    fi

    # An explicit workspace path is authoritative; do not replace `start
    # /path/to/repository` with one of its running worktree children. The child
    # path case returned above: its .git file marks it as a worktree.
    if [[ "$path_given" == 1 ]]; then
        return 0
    fi

    # Parent: use a worktree child's path as the effective workspace
    local -a children=()
    local children_output
    children_output=$(_select_managed_containers --stopped --parent "$w")
    if [[ -n "$children_output" ]]; then
        mapfile -t children <<<"$children_output"
    fi
    if ((${#children[@]} > 1)); then
        # Prefer the canonical agent worktree among several active children.
        local selected_child
        selected_child="$(_canonical_worktree_child "$w" "${children[@]}")"
        if [[ -z "$selected_child" ]]; then
            # stderr: often called inside $(...) to capture the resolved
            # workspace - stdout would be captured with it and the caller
            # would fail silently.
            echo "Incorrect (${children[*]}) number of children containers for this workspace." >&2
            # One project can run several agent worktrees (create --worktree
            # <branch> names each after its branch), so with none the canonical
            # <project>-dev one there is nothing to pick. Name the candidates:
            # their paths are what must be chosen between, and passing one
            # selects it.
            local amb_rec
            local -a amb_fields=()
            while IFS= read -r amb_rec; do
                _rec_fields amb_fields "$amb_rec"
                if [[ -n "${amb_fields[2]:-}" ]]; then
                    echo "  worktree: ${amb_fields[2]}" >&2
                fi
            done < <(_container_infos "${children[@]}")
            echo "Run the command from the worktree you mean, or pass its path as" >&2
            echo "the workspace." >&2
            exit 1
        fi
        children=("$selected_child")
    elif ((${#children[@]} == 0)); then
        return 0
    fi

    # Look up the container's info
    local child_worktree="${children[0]}" eff_path eff_proj rec
    local -a rec_fields=()
    # Effective worktree path info: _container_info fields are id, status,
    # workspace (eff_path), project (eff_proj), ...
    rec="$(_container_info "$child_worktree")" || {
        echo "Failed to inspect worktree container $child_worktree" >&2
        exit 1
    }
    _rec_fields rec_fields "$rec"
    eff_path="${rec_fields[2]:-}"
    eff_proj="${rec_fields[3]:-}"

    # Assign to globals
    hp="$w"
    w="$eff_path"
    oc_project_name="$eff_proj"
}

# When operating from a parent repository, determine whether a child
# worktree is in sync with the current branch.
#
# In sync when either: its HEAD matches the current HEAD; or its merge-base
# with the current branch is the current HEAD, i.e. the worktree branch
# contains the current branch plus additional commits.
function _aseert_sync_worktree() {
    local parent_workspace="$1"
    local eff_path="$2"

    if ((global_skip_assert_worktree)); then
        # Commands like uptree can use an out-of-sync worktree without harm;
        # let it pass.
        return 0
    fi

    # Nothing to sync when the workspace is not a worktree child.
    if [[ -z "$parent_workspace" || "$has_git" == false ]]; then
        return 0
    fi

    local parent_sha child_sha branch child_branch merge_base is_same_commit \
        is_parent_merge_base
    # Guard every git call so a failure (diverged branch, detached or unborn
    # HEAD) cannot abort the launcher via set -e; the empty result falls
    # through to the "needs syncing" handling below.
    parent_sha="$(git -C "$parent_workspace" rev-parse HEAD 2>/dev/null || true)"
    child_sha="$(git -C "$eff_path" rev-parse HEAD 2>/dev/null || true)"
    branch="$(git -C "$parent_workspace" branch --show-current 2>/dev/null || true)"
    child_branch="$(git -C "$eff_path" branch --show-current 2>/dev/null || true)"
    merge_base="$(git -C "$eff_path" merge-base "$branch" "$child_branch" 2>/dev/null || true)"

    is_same_commit=0
    is_parent_merge_base=0
    if [[ -n "$parent_sha" && -n "$child_sha" && "$parent_sha" == "$child_sha" ]]; then
        is_same_commit=1
    elif [[ -n "$parent_sha" && -n "$merge_base" && "$merge_base" == "$parent_sha" ]]; then
        is_parent_merge_base=1
    fi

    if ((is_same_commit || is_parent_merge_base)); then
        return 0
    fi

    read -r only_in_child only_in_parent < <(
        git -C "$parent_workspace" rev-list --left-right --count "$child_branch"..."$branch"
    )

    local child_is_clean=0 parent_is_clean=0
    if [[ -z "$(git -C "$eff_path" status --porcelain)" ]]; then
        child_is_clean=1
    fi
    if [[ -z "$(git -C "$parent_workspace" status --porcelain)" ]]; then
        parent_is_clean=1
    fi

    if ((only_in_parent > 0)); then
        if ((only_in_child == 0 && child_is_clean == 1)); then
            git -C "$eff_path" merge --ff-only "$branch"
            echo "Fast forwarded $child_branch to match $branch"
            return
        fi

        echo "Commits exist in the branch ($branch) that are not present in $child_branch"
        exit 1
    fi

    echo "Error: Parent branch ($branch) and child workspace ($child_branch) are out of sync"
    exit 1
}

# Every launch validates the storage roots (and, with OPENCODE_CACHE, the
# toolchain cache dirs it is about to mount): a missing one is named and, with
# SD_YOLO=true, created right away without asking; otherwise it is offered on
# a terminal and refused when nobody can answer.
function _assert_maybe_write_config_dirs() {
    local -a dirs=()
    local dir answer=""

    # The data directory is always needed for any project
    dirs+=("$OPENCODE_DATA_ROOT" "$OPENCODE_CONFIG_ROOT" "$OPENCODE_CACHE_ROOT")

    # Ids are matched case-insensitively, like parse_cache and the cache
    # override loop in _opencode_args_prepare ("PYTHON NODE" == "python node").
    # Matching the raw value checked nothing for an upper-case request, so the
    # check passed and docker created the cache dirs itself (as root).
    local cache_lower="${OPENCODE_CACHE:-}"
    cache_lower="${cache_lower,,}"

    # "all" is the full toolchain; parse_cache only rewrites it to the
    # canonical id list when OPENCODE_CACHE also picks the image, so expand it
    # here too: every cache dir the aggregate override mounts gets checked.
    if [[ "$cache_lower" == "all" ]]; then
        cache_lower="go rust python node"
    fi

    [[ "$cache_lower" == *python* ]] && dirs+=(
        "${OPENCODE_PIP_CACHE_DIR:-${HOME}/.cache/pip}"
    )

    [[ "$cache_lower" == *node* ]] && dirs+=(
        "${OPENCODE_NPM_CACHE_DIR:-${HOME}/.npm}"
    )

    [[ "$cache_lower" == *go* ]] && dirs+=(
        "${OPENCODE_GO_BUILD_CACHE_DIR:-${HOME}/.cache/go-build}"
        "${OPENCODE_GO_MOD_CACHE_DIR:-${HOME}/go/pkg/mod}"
    )

    [[ "$cache_lower" == *rust* ]] && dirs+=(
        "${OPENCODE_CARGO_REGISTRY_DIR:-${HOME}/.cargo/registry}"
        "${OPENCODE_CARGO_GIT_DIR:-${HOME}/.cargo/git}"
        "${OPENCODE_SCCACHE_DIR:-${HOME}/.cache/sccache}"
    )

    local -a missing=()

    for dir in "${dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            # Must be a directory.
            if [[ ! -d "$dir" ]]; then
                printf 'Error: "%s" exists but is not a directory.\n' "$dir" >&2
                exit 1
            fi

            # It must be writable.
            if [[ ! -w "$dir" ]]; then
                printf 'Error: "%s" is not writable.\n' "$dir" >&2
                exit 1
            fi
        else
            missing+=("$dir")
        fi
    done

    if ((${#missing[@]})); then
        # Named in both modes: SD_YOLO writes them without asking, but a
        # launch creating unexpected directories still has to say which.
        printf 'The following directories do not exist:\n'
        printf '  %s\n' "${missing[@]}"

        if [[ "${SD_YOLO,,}" != "true" ]]; then
            # Only ask when someone can answer. bash shows a read prompt only
            # on a terminal; with stdin redirected (script, CI, cron) the read
            # returned nothing and fell to the decline branch, reporting "No
            # directories were created." without saying why. Such a run creates
            # nothing either way: name the dirs and stop, so the failure points
            # at the cause, not at a question nobody answered.
            if [[ ! -t 0 ]]; then
                printf 'Not interactive: create them above and re-run.\n'
                exit 1
            fi

            read -r -p "Create these directories? [y/N] " answer

            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                printf 'No directories were created.\n'
                exit 1
            fi
        fi

        # Accepted (or SD_YOLO): create everything that was missing, in one
        # loop.
        # TODO: if the dir is the config root, copy from a template
        for dir in "${missing[@]}"; do
            if ! mkdir -p -- "$dir"; then
                printf 'Error: failed to create "%s".\n' "$dir" >&2
                exit 1
            fi
        done
    fi
}

# Prepares the Docker Compose arguments: project configuration, network
# settings and git directory mounts.
#
# FEATURE: Transient volumes - add OPENCODE_DATA=false disables persisted volume
function _opencode_args_prepare() {
    local ws_out="$1"
    local has_parent="$2"
    local -n args_out="$3"

    # Compose args start from the main compose file, after resolving worktree
    # args
    args_out+=(
        -p "$oc_project_name"
        -f "$SD_OPENCODE/docker-compose.yml"
    )

    # Storage for the merged compose files
    mkdir "$tmp_compose_dir"

    # Volume overrides to mount
    local -a ro_vol_mounts=()

    # Check the host dirs, offering to write what is missing
    _assert_maybe_write_config_dirs
    # The opencode database does not handle concurrent servers on one database
    # (very buggy: it leaks project data and ignores the project-scoped
    # --continue), so pick a data directory per project when none is given.
    # Defaults are scoped per repo, or a user root if provided; names can
    # conflict across sibling or unrelated paths, so keep them unique.
    if [[ -z "${OPENCODE_DATA_DIR:-}" ]]; then
        export OPENCODE_DATA_DIR="$OPENCODE_DATA_ROOT/$oc_project_name"
        # No prompt: with the root already created, answering per project on
        # every scaffold would be noise.
        [[ ! -d "$OPENCODE_DATA_DIR" ]] && mkdir -p "$OPENCODE_DATA_DIR"
    fi
    # Workspace-local config, seeded once per project: the first launch copies
    # $OPENCODE_CONFIG_ROOT/template into the project's directory and says
    # where; later launches use it as it stands - opencode's own once created,
    # so neither wiped nor re-copied (no template propagation; project files
    # survive restarts). Remove the directory to re-seed from the current
    # template.
    if [[ -z "${OPENCODE_CONFIG_DIR:-}" ]]; then
        local tmp_project_config="$OPENCODE_CONFIG_ROOT/projects/$oc_project_name"
        export OPENCODE_CONFIG_DIR="$tmp_project_config"
        if [[ ! -d "$tmp_project_config" ]]; then
            # FEATURE: detect need for update
            echo "Creating project config at: $tmp_project_config"
            mkdir -p -- "$tmp_project_config"
            # No template (or an empty one) leaves the config empty rather
            # than failing: the seed is best-effort.
            if [[ -d "$OPENCODE_CONFIG_ROOT/template" ]]; then
                cp -r "$OPENCODE_CONFIG_ROOT/template/." "$tmp_project_config/"
            fi
        fi
    fi
    # Workspace-local cache
    if [[ -z "${OPENCODE_CACHE_DIR:-}" ]]; then
        export OPENCODE_CACHE_DIR="$OPENCODE_CACHE_ROOT/$oc_project_name"
        [[ ! -d "$OPENCODE_CACHE_DIR" ]] && mkdir -p "$OPENCODE_CACHE_DIR"
    fi

    # FEATURE: if not avaliable and it is not the known prefix, we can could
    # try to get the required information from docker image inspect of images
    # that implement the base feature requirements
    #
    # Tell the agent which toolchain its image ships: copy the component's.
    # the opencode json needs to reference this in the config
    #   "skills": [
    # "/opt/opencode/skills"
    if [[ -n "$IMAGE_COMPONENT" ]]; then
        local skill_name="available-$IMAGE_COMPONENT-tools"
        local skill_suffix="$skill_name"
        local skill_src="$SD_OPENCODE/opencode/skills/$skill_suffix"
        ro_vol_mounts+=("$skill_src:/opt/opencode/skills/$skill_suffix")
    fi

    # Worktree children need labels, merged after the main compose name
    if [[ -n "$has_parent" ]]; then
        # Worktree parent label: on the service, and merged into the network
        # labels of docker-compose.yml, on the network
        _write_labels_override "$has_parent"
        args_out+=(-f "$tmp_labels_file")
    fi

    # v2 needs a password
    if [[ "$IMAGE_VERSION" == v2 ]]; then
        args_out+=(-f "$COMPOSE_ENV_DIR/docker-compose.password.yml")
    fi

    # The api key is an opt-in file secret: kept at
    # ~/.config/opencode-docker/opencode.key (OPENCODE_KEY_FILE overrides),
    # read here only to prove a key is there - missing, unreadable or empty
    # merges nothing. A key found means compose mounts the host file itself at
    # /run/secrets/api_key, where opencode reads it via the
    # `{file:/run/secrets/api_key}` reference in the project's opencode.json
    # (README, "API key secret"); the backend exports nothing. Only the path
    # ever enters an override or the environment, never the value.
    local api_key=""
    if [[ -f "$OPENCODE_KEY_FILE" && -r "$OPENCODE_KEY_FILE" ]]; then
        api_key="$(<"$OPENCODE_KEY_FILE")"
    fi
    if [[ -n "$api_key" ]]; then
        # Cleared at once: the key must never reach an echo or a child
        # process.
        api_key=""
        # Exported for compose's interpolation of the secret's `file:`.
        export OPENCODE_KEY_FILE
        _assert_file_is_yml "$COMPOSE_SECRET_DIR/docker-compose.secret.yml" || exit 1
        args_out+=(-f "$COMPOSE_SECRET_DIR/docker-compose.secret.yml")
        echo "Using api key secret: $OPENCODE_KEY_FILE"
    fi

    # OPENCODE_CACHE=false disables the cache volumes, "all" adds all, "go
    # python" adds both; case-insensitive. parse_cache already rejected
    # unknown ids for every command, so the per-id loop only resolves the
    # override files; its own case is the backstop for a value assigned after
    # the launcher was sourced (repl).
    if [[ -n "${OPENCODE_CACHE:-}" ]]; then
        local cache_lower="${OPENCODE_CACHE,,}"
        if [[ "$cache_lower" == "all" ]]; then
            args_out+=(-f "$COMPOSE_VOL_DIR/docker-compose.cache.yml")
        elif [[ "$cache_lower" != "false" ]]; then
            for id in $cache_lower; do
                case "$id" in
                go | node | python | rust)
                    local file="$COMPOSE_VOL_DIR/docker-compose.$id.yml"
                    _assert_file_is_yml "$file" || exit 1
                    args_out+=(-f "$file")
                    ;;
                *)
                    echo "Error: unknown toolchain cache id: $id (valid ids: all, go, node, python, rust)" >&2
                    exit 1
                    ;;
                esac
            done
        fi
    fi

    # Image layer: build the project image, or mount a prebuilt one
    if [[ -f "$OPENCODE_DOCKERFILE" ]]; then
        # The project's own Dockerfile
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.build.yml")
    elif [[ -f "$ROOT_DOCKERFILE_PATH" ]]; then
        # The repository-wide Dockerfile
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.build.yml")
    else
        # Nothing to build: mount the prebuilt image
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.image.yml")
    fi

    # Network: compose's default, a launcher-managed one (@default), or a
    # named one
    if [[ "${OPENCODE_NETWORK:-}" == "@default" ]]; then
        # Workspace-scoped network
        local proj_name
        _network_builder "$oc_project_name" "$ws_out" "$has_parent" || {
            echo "Failed to create or find network for project: $oc_project_name" >&2
            return 1
        }
        OPENCODE_NETWORK="$network_name"
        export OPENCODE_NETWORK
        args_out+=(-f "$COMPOSE_NET_DIR/docker-compose.network.yml")
        echo "Using network: $OPENCODE_NETWORK"
    elif [[ -n "${OPENCODE_NETWORK:-}" ]]; then
        args_out+=(-f "$COMPOSE_NET_DIR/docker-compose.network.yml")
        echo "Using network: $OPENCODE_NETWORK"
    else
        echo "Using default network"
    fi

    # Merge any user-defined compose files
    if [[ -d "$OPENCODE_COMPOSE" ]]; then
        while IFS= read -r -d '' file; do
            if _assert_file_is_yml "$file"; then
                args_out+=(-f "$file")
            else
                exit 1
            fi
        done < <(find "$OPENCODE_COMPOSE" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
    else
        for file in $OPENCODE_COMPOSE; do
            if _assert_file_is_yml "$file"; then
                args_out+=(-f "$file")
            else
                exit 1
            fi
        done
    fi

    # .git dirs mount read-only by default; SD_READ_ONLY=false opts out and
    # mounts the workspace without the git override file.
    if [[ "${SD_READ_ONLY,,}" != "false" ]]; then
        local git_dir
        while IFS= read -r -d '' git_dir; do
            ro_vol_mounts+=("$git_dir:$CONTAINER_WORKSPACE_ROOT/${git_dir#"$ws_out"/}")
            echo "read-only locking dir: $git_dir"
        done < <(_find_workspace_git_dirs "$ws_out")

        # A worktree's .git is a file pointing into the parent repository.
        # Mount the parent git dir read-only at its own host path so the
        # pointer resolves in-container; protect the pointer too.
        if [[ -n "$has_parent" ]]; then
            _assert_maybe_check_outside_root "$has_parent"
            ro_vol_mounts+=("$has_parent/.git:$has_parent/.git")
            ro_vol_mounts+=("$ws_out/.git:$CONTAINER_WORKSPACE_ROOT/.git")
            echo "read-only locking worktree parent: $has_parent/.git"
        fi
    fi

    # mount the read-only git overrides, when there are any
    if ((${#ro_vol_mounts[@]} > 0)); then
        _write_volume_overrides ro_vol_mounts
        args_out+=(-f "$tmp_compose_file")
    fi

    # Only non-empty values are added; empty ones leave the Compose setting at
    # its default. Each option is its own static override file, merged only
    # when set.
    if [[ -n "$OPENCODE_CPUSET" ]]; then
        local cpu_file="$COMPOSE_SYS_DIR/docker-compose.cpuset.yml"
        _assert_file_is_yml "$cpu_file" || exit 1
        args_out+=(-f "$cpu_file")
        echo "Using CPUSET: $OPENCODE_CPUSET"
    fi
    if [[ -n "$OPENCODE_CPUS" ]]; then
        local cpu_file="$COMPOSE_SYS_DIR/docker-compose.cpus.yml"
        _assert_file_is_yml "$cpu_file" || exit 1
        args_out+=(-f "$cpu_file")
        echo "Using CPUS: $OPENCODE_CPUS"
    fi

    # The backend is published on a host port only for a host-side opencode
    # CLI driving the TUI. Without one the throwaway `tui` service connects
    # over the compose network, so nothing is exposed: one project's backend
    # then stays unreachable from another project's host processes.
    if _opencode_on_host; then
        local port_file="$COMPOSE_SYS_DIR/docker-compose.port.yml"
        _assert_file_is_yml "$port_file" || exit 1
        args_out+=(-f "$port_file")
    fi

}

# Ensure the opencode container exists and is running. Assumes the caller is
# inside _opencode_ctx (cd'd into the workspace, WORKSPACE exported) with
# OPENCODE_ARGS set; shared by start and setup to avoid repeating the
# 'docker compose up' step.
#
# Never recreates a running container (--no-recreate), so inspection commands
# do not disturb an existing session; only start/new pass --recreate.
function _opencode_ensure_up() {
    local recreate=0
    if [[ "${1:-}" == "--recreate" ]]; then
        recreate=1
        shift
    fi

    if ((recreate)); then
        _driver compose "${opencode_compose_args[@]}" up -d opencode
    else
        _driver compose "${opencode_compose_args[@]}" up -d --no-recreate opencode
    fi
}

# Run a one-off task against the opencode service without disturbing a
# pre-existing persistent container.
#
#   * Persistent container running: the task runs inside it via `exec`,
#     untouched afterwards.
#   * Otherwise a fresh one-off via `docker compose run --rm`, which publishes
#     none of the service's ports and is removed when it exits.
#
# `interactive` controls TTY handling: 1 streams output to the terminal
# (changes), 0 is fully non-interactive and capturable (run/setup, the
# changes analysis step).
#
# FEATURE: With a TUI connected to the backend (`opencode --server` on v2) it
# is running, but a one-off may still be best; concurrent runs may be best
# outside the opencode service, since one-offs can claim their own CPU
# allocation.
function _opencode_dispatch() {
    local interactive="$1"
    shift

    local running
    running="$(_driver compose "${opencode_compose_args[@]}" ps -q opencode)"

    if [[ -n "$running" ]]; then
        # Already-running container: without -T output streams to the
        # terminal; with -T the caller captures it.
        if ((interactive)); then
            _driver compose "${opencode_compose_args[@]}" exec -w "$CONTAINER_WORKSPACE_ROOT" opencode "$@"
        else
            _driver compose "${opencode_compose_args[@]}" exec -T -w "$CONTAINER_WORKSPACE_ROOT" opencode "$@"
        fi
    else
        # Throwaway container: runs the task and exits, no ports.
        _driver compose "${opencode_compose_args[@]}" \
            run --rm \
            -w "$CONTAINER_WORKSPACE_ROOT" \
            --entrypoint /bin/sh \
            opencode \
            -c 'exec "$@"' \
            sh \
            "$@"
    fi
}

function _assert_continue_outside_workspace() {
    if [[ -z "${OPENCODE_WORKSPACE:-}" ]]; then
        return 0
    fi
    # Not within this opencode project
    local answer=""
    printf 'Workspace is outside of the environment workspace:\n  %s\n' "$OPENCODE_WORKSPACE"
    printf 'Running this command will run with this workspaces environment\n'
    read -r -p "Continue anyway? [y/N] " answer </dev/tty || true

    case ${answer,,} in
    y | yes) ;;
    *)
        printf 'Aborted.\n' >&2
        exit 1
        ;;
    esac
}

function _check_within_workspace() {
    local starting_ws="$1"
    local eff_ws="$2"
    local has_parent="$3"

    # The starting or effective workspace must be the profile workspace
    if [[ -z ${OPENCODE_WORKSPACE+x} ]]; then
        return 0
    fi

    # e.g. loading a child worktree from the parent
    if [[ "$starting_ws" != "$eff_ws" &&
        ("$OPENCODE_WORKSPACE" == "$starting_ws" ||
        "$OPENCODE_WORKSPACE" == "$eff_ws") ]] \
        ; then # path changed, one equal to OPENCODE_WORKSPACE
        return 0
    fi

    # Going up a worktree, the path is given so starting == effective. A
    # worktree's parent may be OPENCODE_WORKSPACE, but the child worktree
    # itself prompts: one of the two must be a valid root.
    if [[ -n "$has_parent" ]]; then
        local ws_out_normalized=""
        if _check_valid_within_root "$has_parent" "$OPENCODE_WORKSPACE" ws_out_normalized; then
            return 0
        elif _check_valid_within_root "$starting_ws" "$OPENCODE_WORKSPACE" ws_out_normalized; then
            return 0
        else
            return 1
        fi
    else
        # Must be inside an opencode space, e.g. a gist inside a workspace
        local ws_out_normalized=""
        if ! _check_valid_within_root "$starting_ws" "$OPENCODE_WORKSPACE" ws_out_normalized; then
            return 1
        else
            return 0
        fi
    fi
}

# Run a command in the opencode project context. Centralises the shared
# setup: prepares the compose args, cd's into the workspace, exports
# WORKSPACE and exposes the args as OPENCODE_ARGS, then invokes the named
# function with the remaining arguments - command bodies inherit ws/proj,
# OPENCODE_ARGS and $@.
function _opencode_ctx() {
    local fn="$1"
    oc_workspace="$2"
    shift 2

    # Prepare the compose args and OPENCODE_ARGS in the current shell so the
    # dispatched command and its helpers can use them, then run the command in a
    # subshell so its traps and cwd changes do not leak into the launcher.
    local has_parent=""
    local ws_out="$oc_workspace"
    _resolve_effective_workspace ws_out has_parent "${workspace_path_given:-0}"

    if ! _check_within_workspace "$oc_workspace" "$ws_out" "$has_parent"; then
        _assert_continue_outside_workspace "$oc_workspace"
    fi

    if ((!global_skip_assert_worktree)); then
        _aseert_sync_worktree "$has_parent" "$ws_out" "$oc_workspace"
    fi

    local -a args=()
    _opencode_args_prepare "$ws_out" "$has_parent" args || return 1

    oc_workspace="$ws_out"

    opencode_compose_args=("${args[@]}")

    # Configuration display
    echo "Using opencode workspace: $oc_workspace"
    echo "Compose project: $oc_project_name"

    (
        # Traps inside the subshell too
        _cleanup_stack=()
        trap _cleanup_run EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        cd "$oc_workspace" || exit 1
        export WORKSPACE="$oc_workspace"
        # The build arg behind the dev.snowdon.opencode.workspace_parent label
        # (PROJECT_WORKSPACE_PARENT in compose/image/, consumed by the
        # workspace Dockerfile): a worktree's image records its repository, so
        # 'delete --all' on the repository still reaches it after the
        # worktree's container is gone. Empty without a parent.
        export WORKSPACE_PARENT="$has_parent"
        "$fn" "$@"
    )
}

# Resolve the host-side port docker published for the opencode service's
# private port 4096. With a dynamic binding ("0:4096") the host port is chosen
# at container creation, so it is queried back with `docker compose port
# opencode 4096`, not assumed. Output is "0.0.0.0:PORT"; only PORT is emitted.
# Non-zero when the container is not running or the mapping is absent.
function _backend_host_port() {
    local published
    published="$(_driver compose "${opencode_compose_args[@]}" port opencode 4096 2>/dev/null)" || return 1
    published="${published##*:}"
    [[ "$published" =~ ^[0-9]+$ ]] && printf '%s\n' "$published"
}

# The backend's unauthenticated readiness endpoint for the selected version
# (version table at the top of this file), built from backend_origin or the
# OPENCODE_BACKEND_ORIGIN override. backend_origin is already side-correct: a
# host-side TUI reaches the published host port (127.0.0.1:$resolved), the
# in-container TUI the service's private port (opencode:4096). Empty when
# neither is set - the callers' "no backend to probe".
function _backend_health_url() {
    local origin="${backend_origin:-${OPENCODE_BACKEND_ORIGIN:-}}"
    [[ -n "$origin" ]] || return 1
    printf '%s%s\n' "${origin%/}" "$OPENCODE_HEALTH_PATH"
}

function _backend_healthy() {
    local backend_health_url
    backend_health_url="http://127.0.0.1:4096" || return 1
    # In-container tui: no host port published, so the host cannot curl the
    # backend (the service name resolves only on the compose network). Probe
    # from inside the container instead.
    _driver compose "${opencode_compose_args[@]}" exec -T \
        opencode curl -fsS \
        --connect-timeout 0.2 \
        --max-time 0.5 \
        "$backend_health_url" >/dev/null 2>&1
}

# Block until the backend answers its health endpoint, polling inside a single
# waitforserver process instead of one health check (and one `docker compose
# exec`) per attempt. Waits from the same side _backend_healthy probes: a host
# opencode CLI over the published host port, the in-container tui over the
# compose network (which resolves only inside the container). The launcher
# resolves the version's health path and hands waitforserver the full URL, so
# the script stays version-agnostic. Assumes BACKEND_ORIGIN is set; non-zero
# when the backend never comes up.
function _wait_for_backend() {
    local backend_health_url
    backend_health_url="http://127.0.0.1:4096" || return 1
    _driver compose "${opencode_compose_args[@]}" exec -T \
        -w "$CONTAINER_WORKSPACE_ROOT" \
        opencode "$WAIT_FOR_SERVER_EXE" "$backend_health_url"
}

# Print the raw ids of the managed opencode containers selected by the given
# label filters, one per line (nothing when the selection is empty).
#
# `--stopped` adds `-a` so stopped (still existing) containers are found;
# without it only running ones. The optional positional workspace and
# `--parent <ws>` become docker label filters:
#     label=dev.snowdon.opencode.workspace=<ws>   (positional workspace)
#     label=dev.snowdon.opencode.parent=<ws>      (--parent, worktree child)
# Filters are AND-ed, so the two are mutually exclusive selectors: a container
# never carries both labels, so using both returns nothing.
#
# Engine errors are not swallowed: stdout and stderr go to separate temp
# files, so a failing `docker ps` still reports `warning: container discovery
# failed: <stderr>` while yielding whatever ids came through. Both temp files
# are removed on every path.
function _managed_container_ids() {
    local ws_filter="" parent_filter="" stopped=""
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
        --stopped)
            stopped="-a"
            shift
            ;;
        --parent)
            parent_filter="$2"
            shift 2
            ;;
        --parent=*)
            parent_filter="${1#--parent=}"
            shift
            ;;
        *)
            ws_filter="$1"
            shift
            ;;
        esac
    done

    local id ids_file ps_rc ps_err
    ps_err="$(mktemp "${tmp_sd_root_dir}/oc-pserr.XXXXXX")" || return 1

    local -a args=(
        container_ls
        -q
        --filter "label=$LABEL_MANAGED_OPENCODE=true"
    )
    [[ -n $stopped ]] && args+=("$stopped")

    [[ -n $ws_filter ]] &&
        args+=(--filter "label=$LABEL_WORKSPACE_OPENCODE=$ws_filter")

    [[ -n $parent_filter ]] &&
        args+=(--filter "label=$LABEL_PARENT_OPENCODE=$parent_filter")

    local cids
    cids=$(_driver "${args[@]}" 2>"$ps_err")
    ps_rc=$?
    if ((ps_rc != 0)) && [[ -s "$ps_err" ]]; then
        echo "warning: container discovery failed: $(<"$ps_err")" >&2
    else
        printf '%s\n' "$cids"
    fi

    rm -f -- "$ps_err"

    return $ps_rc
}

# The Go template shared by _container_info and _container_infos, printing one
# tab-separated record per container id:
#
#     <id>\t<status>\t<workspace>\t<project>\t<oneoff>\t<tui>\t<parent>\t.
#
# Empty label columns stay blank; the trailing '.' marks the record's end.
# Callers must split a record with _rec_fields: `IFS=$'\t' read` treats a run
# of tabs as one delimiter (tab is IFS whitespace) and shifts every column
# after an empty one. Fields are separated with {{"\t"}} (a Go template
# string literal), not a raw \t: docker inspect does not interpolate \t
# escapes the way docker ps does.
#
# docker inspect is used rather than `docker ps --format` because
# .Config.Labels from inspect is always a map, while `ps --format` .Labels can
# surface as a slice (indexing it by string then fails) depending on the
# docker/compose build.
function _container_info_format() {
    printf '%s' \
        '{{.ID}}{{"\t"}}{{.State.Status}}{{"\t"}}{{index .Config.Labels "'"$LABEL_WORKSPACE_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_CONTAINER_PROJECT_NAME"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_ONE_OFF"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_TUI_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_PARENT_OPENCODE"'"}}{{"\t"}}.'
}

# Print one tab-separated record for the given managed container id (layout:
# _container_info_format). Non-zero, printing nothing, for a stale id.
function _container_info() {
    _driver container_inspect \
        --format "$(_container_info_format)" \
        "$1" 2>/dev/null
}

# Print one record per managed container id from a single `docker inspect`
# call (one formatted line per id) rather than one round-trip each. A
# stale/missing id only writes stderr, dropped here: it contributes no
# record, exactly as _container_info reports nothing for one.
function _container_infos() {
    [[ $# -gt 0 ]] || return 0
    _driver container_inspect \
        --format "$(_container_info_format)" \
        "$@" 2>/dev/null || true
}

# Split one tab-separated inspect record (see _container_info_format) into
# the array named by $1, preserving empty columns.
#
# `IFS=$'\t' read` cannot: tab is IFS whitespace, so a run of tabs collapses
# into one delimiter and every column after an empty label shifts left. A main
# container carries no dev.snowdon.opencode.tui label (only the tui service
# does), so its record has an empty tui column between oneoff and parent: with
# `read` the parent label lands in the tui field and the '.' sentinel in the
# parent field, silently breaking the `--other` exclusion of a worktree's
# containers - they get listed, stopped and deleted as "other" workspaces.
#   _rec_fields <array-name> <record>
function _rec_fields() {
    local -n _recf_out="$1"
    local rest="$2"
    _recf_out=()
    while [[ "$rest" == *$'\t'* ]]; do
        _recf_out+=("${rest%%$'\t'*}")
        rest="${rest#*$'\t'}"
    done
    _recf_out+=("$rest")
}

# Print the ids of the managed opencode containers selected by the flags, one
# per line (nothing when the selection is empty). Shared discovery policy
# behind list/stop/delete (and the worktree-child probe in
# _opencode_args_prepare).
#
# Two steps:
#   1. _managed_container_ids narrows by docker label filters.
#   2. The ids are inspected in a single `docker inspect` call (via
#      _container_infos, one record per line) when a policy needs
#      per-container labels:
#        * unless --all, throwaway `compose run` oneoffs are dropped while the
#          interactive TUI one-off is kept: excluded only when it is a oneoff
#          (com.docker.compose.oneoff, case-insensitive since compose sets
#          "True") that is not the tui service (dev.snowdon.opencode.tui).
#        * --other <ws> drops containers of <ws> (workspace label) and of its
#          worktrees (parent label). Docker filters cannot express
#          `label != x`, hence the inspect.
#
#   Flags:
#     -a, --all       Include oneoff (`compose run`) containers.
#     --stopped       Also include stopped containers (`docker ps -a`); used
#                     by list/delete to see containers that are not running.
#     --parent <ws>   Select containers labelled dev.snowdon.opencode.parent=<ws>
#                     (launched from git worktrees of <ws>).
#     --other <ws>    Exclude containers belonging to <ws> and its worktrees.
#     <workspace>     Positional: select containers labelled
#                     dev.snowdon.opencode.workspace=<ws>.
function _select_managed_containers() {
    local include_oneoff=0 other_ws=""
    local ws_filter="" parent_filter="" stopped=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -a | --all)
            include_oneoff=1
            shift
            ;;
        --stopped)
            stopped="-a"
            shift
            ;;
        --other)
            other_ws="$2"
            shift 2
            ;;
        --other=*)
            other_ws="${1#--other=}"
            shift
            ;;
        --parent)
            parent_filter="$2"
            shift 2
            ;;
        --parent=*)
            parent_filter="${1#--parent=}"
            shift
            ;;
        *)
            ws_filter="$1"
            shift
            ;;
        esac
    done

    local sel=()
    if [[ -n "$stopped" ]]; then sel+=(--stopped); fi
    if [[ -n "$ws_filter" ]]; then sel+=("$ws_filter"); fi
    if [[ -n "$parent_filter" ]]; then sel+=(--parent "$parent_filter"); fi

    # Only a policy needing per-container labels (the oneoff filter or
    # --other) inspects; otherwise the ids pass straight through with no
    # inspect round-trip.
    local output_ids rc
    output_ids=$(_managed_container_ids "${sel[@]}")
    rc=$?
    if ((rc != 0)); then
        printf 'error: _managed_container_ids failed (%d)\n' "$rc" >&2
        return $rc
    fi
    if [[ -z "$output_ids" ]]; then
        return 0
    fi
    local -a ids=()
    local id
    while read -r id; do
        [[ -z "$id" ]] && continue
        if [[ "$include_oneoff" -eq 0 || -n "$other_ws" ]]; then
            ids+=("$id")
        else
            printf '%s\n' "$id"
        fi
    done <<<"$output_ids"
    ((${#ids[@]} == 0)) && return 0

    # Inspect every id in one `docker inspect` call (one record per line), not
    # one round-trip each. Records come back in argument order, so the ids
    # keep the discovery order; a stale id contributes no record and is
    # dropped.
    local output_infos infos_rc
    output_infos=$(_container_infos "${ids[@]}")
    infos_rc=$?
    if ((infos_rc != 0)); then
        printf 'error: _container_infos failed (%d)\n' "$infos_rc" >&2
        return $infos_rc
    fi
    if [[ -z "$output_infos" ]]; then
        return 0
    fi
    local rec ws oneoff istui parent
    local -a rec_fields=()
    while read -r rec; do
        [[ -z "$rec" ]] && continue
        _rec_fields rec_fields "$rec"
        id="${rec_fields[0]:-}"
        ws="${rec_fields[2]:-}"
        oneoff="${rec_fields[4]:-}"
        istui="${rec_fields[5]:-}"
        parent="${rec_fields[6]:-}"
        if [[ "$include_oneoff" -eq 0 ]] &&
            [[ "${oneoff,,}" == "true" ]] && [[ "${istui,,}" != "true" ]]; then
            continue
        fi
        if [[ -n "$other_ws" ]] &&
            [[ "$ws" == "$other_ws" || "$parent" == "$other_ws" ]]; then
            continue
        fi
        printf '%s\n' "$id"
    done <<<"$output_infos"
}

# Resolve the workspace a managed container was created for: its
# dev.snowdon.opencode.workspace label (field 3 of _container_info). Empty
# for a stale id or an absent label.
function _find_workspace() {
    local rec ws
    local -a rec_fields=()
    rec="$(_container_info "$1")" || rec=""
    _rec_fields rec_fields "$rec"
    ws="${rec_fields[2]:-}"
    printf '%s\n' "$ws"
}

# True when the opencode CLI is on the host: its TUI reaches the backend over
# the published host port, which is why the port override is merged (see
# _opencode_args_prepare). False with the one-off `tui` service (no CLI): the
# backend is reached as http://opencode:4096 on the compose network, no host
# port published.
function _opencode_on_host() {
    command which opencode >/dev/null 2>&1
}

function _run_opencode_tui_executable() {
    if _opencode_on_host; then
        echo "Using opencode tui $(command which opencode)"
        if [[ ! -x "$START_TUI_EXE_HOST" ]]; then
            echo "The TUI script for opencode $IMAGE_VERSION is missing: $START_TUI_EXE_HOST" >&2
            return 1
        fi
        # The backend is on a random host port; BACKEND_ORIGIN is the resolved
        # `docker compose port opencode 4096` mapping (or an
        # OPENCODE_BACKEND_ORIGIN override), read from the environment like by
        # the in-container tui service. The script is the version's own:
        # `opencode attach <url>` on v1, `opencode --server <url>` on v2.
        BACKEND_ORIGIN="$backend_origin" "$START_TUI_EXE_HOST" 1 "$@"
    else
        # On the compose network the service is reachable on its private port.
        # The tui entrypoint is `start-tui 0`, so only the user's arguments
        # are appended.
        local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://opencode:4096}"
        _driver compose "${opencode_compose_args[@]}" run \
            --rm --remove-orphans \
            -e BACKEND_ORIGIN="$BACKEND_ORIGIN" \
            tui "$@"
    fi
}

function _cleanup_opencode_backend() {
    _driver compose "${opencode_compose_args[@]}" exec \
        opencode "$END_BACKEND_SERVE_EXE" || true
}

# Tear down an in-flight scaffold run: kill the compose client, force-remove
# the one-off container and delete the temp output file. `docker compose run
# -T` cannot proxy Ctrl+C into the container (no TTY) and opencode run --auto
# ignores SIGINT, so removal must be forced. Runs via the existing
# INT/TERM/EXIT traps' cleanup stack; failures are surfaced, not swallowed.
function _cleanup_scaffold() {
    if [[ -n "$_cleanup_scaffold_pid" ]]; then
        kill -KILL "$_cleanup_scaffold_pid" 2>/dev/null || true
    fi
    if [[ -n "$_cleanup_scaffold_name" ]]; then
        if ! _driver container_rm -f -v "$_cleanup_scaffold_name" >/dev/null 2>&1; then
            # Name may be stale or the engine busy: force-kill, retry, then report.
            _driver container_kill "$_cleanup_scaffold_name" >/dev/null 2>&1 || true
            if ! _driver container_rm -f "$_cleanup_scaffold_name" >/dev/null 2>&1; then
                echo "WARNING: could not remove scaffold container $_cleanup_scaffold_name" >&2
                echo "  run: $DRIVER rm -f $_cleanup_scaffold_name" >&2
                _driver container_ls -a --filter "name=oc-scaffold-" \
                    --format '  {{.ID}}  {{.Names}}  {{.Status}}' >&2 || true
            fi
        fi
    fi
    if [[ -n "$_cleanup_scaffold_output" ]]; then
        rm -f -- "$_cleanup_scaffold_output"
    fi
}

function _cleanup_changes() {
    if [[ -n "$_cleanup_changes_pid" ]]; then
        kill -KILL "$_cleanup_changes_pid" 2>/dev/null || true
    fi
    if [[ -n "$_cleanup_changes_name" ]]; then
        if ! _driver container_rm -f -v "$_cleanup_changes_name" >/dev/null 2>&1; then
            # Name may be stale or the engine busy: force-kill, retry, then report.
            _driver container_kill "$_cleanup_changes_name" >/dev/null 2>&1 || true
            if ! _driver container_rm -f "$_cleanup_changes_name" >/dev/null 2>&1; then
                echo "WARNING: could not remove changes container $_cleanup_changes_name" >&2
                echo "  run: $DRIVER rm -f $_cleanup_changes_name" >&2
                _driver container_ls -a --filter "name=oc-changes-" \
                    --format '  {{.ID}}  {{.Names}}  {{.Status}}' >&2 || true
            fi
        fi
    fi
    if [[ -n "$_cleanup_changes_output" ]]; then
        rm -f -- "$_cleanup_changes_output"
    fi
}

# Tear down an in-flight bg run: kill the compose client, force-remove the
# one-off container and delete the temp output file. Same as
# _cleanup_scaffold, for the 'bg' command's container.
function _cleanup_bg() {
    if [[ -n "$_cleanup_bg_pid" ]]; then
        kill -KILL "$_cleanup_bg_pid" 2>/dev/null || true
    fi
    if [[ -n "$_cleanup_bg_name" ]]; then
        if ! _driver container_rm -f -v "$_cleanup_bg_name" >/dev/null 2>&1; then
            # Name may be stale or the engine busy: force-kill, retry, then report.
            _driver container_kill "$_cleanup_bg_name" >/dev/null 2>&1 || true
            if ! _driver container_rm -f "$_cleanup_bg_name" >/dev/null 2>&1; then
                echo "WARNING: could not remove bg container $_cleanup_bg_name" >&2
                echo "  run: $DRIVER rm -f $_cleanup_bg_name" >&2
                _driver container_ls -a --filter "name=oc-bg-" \
                    --format '  {{.ID}}  {{.Names}}  {{.Status}}' >&2 || true
            fi
        fi
    fi
    if [[ -n "$_cleanup_bg_output" ]]; then
        rm -f -- "$_cleanup_bg_output"
    fi
}

# Tear down an interrupted io run: kill the compose client, force-remove the
# one-off container and delete the streamed-output temp file. Same contract
# as _cleanup_scaffold, but name and pid are cleared as soon as the run
# finished waiting: `run --rm` already removed an exited container, so only a
# run interrupted mid-flight leaves something. The plan file is the command's
# output and is never touched here.
function _cleanup_io() {
    if [[ -n "$_cleanup_io_pid" ]]; then
        kill -KILL "$_cleanup_io_pid" 2>/dev/null || true
    fi
    if [[ -n "$_cleanup_io_name" ]]; then
        if ! _driver container_rm -f -v "$_cleanup_io_name" >/dev/null 2>&1; then
            # Name may be stale or the engine busy: force-kill, retry, then report.
            _driver container_kill "$_cleanup_io_name" >/dev/null 2>&1 || true
            if ! _driver container_rm -f "$_cleanup_io_name" >/dev/null 2>&1; then
                echo "WARNING: could not remove io container $_cleanup_io_name" >&2
                echo "  run: $DRIVER rm -f $_cleanup_io_name" >&2
                _driver container_ls -a --filter "name=oc-io-" \
                    --format '  {{.ID}}  {{.Names}}  {{.Status}}' >&2 || true
            fi
        fi
    fi
    if [[ -n "$_cleanup_io_outfile" ]]; then
        rm -f -- "$_cleanup_io_outfile"
    fi
}

# Start and run opencode in a Docker container, with workspace configuration
# and environment isolation.
# FEATURE: when multiple opencodes are open, closing one will close all the servers
# the tui will error unable to connect to servers
function opencode() {
    # Multiple workspaces run concurrently, each backend on its own random
    # host port: when another managed container already runs for a different
    # workspace, warn (not abort) so the user knows several backends are
    # active.
    local running_id running_ws
    local other_running=0
    local container_id
    while read -r running_id; do
        [[ -z "$running_id" ]] && continue

        # docker inspect, not `ps --format`: .Config.Labels is always a map,
        # whereas `ps --format` .Labels can surface as a slice (indexing it by
        # string then fails), depending on the docker/compose build.
        running_ws="$(_find_workspace "$running_id")"
        if [[ -n "$running_ws" && "$running_ws" != "$oc_workspace" ]]; then
            other_running=1
            break
        fi
    done < <(_select_managed_containers)

    if [[ "$other_running" -eq 1 ]]; then
        echo "NOTICE: pre-existing opencode containers are running for other workspaces" >&2
        echo "  They bind separate random host ports, so sessions can coexist." >&2
        echo "  Run 'opencode:stop' to stop them all." >&2
    fi

    # Start the containers
    _opencode_ensure_up --recreate || {
        echo "Failed to start the opencode container" >&2
        exit 1
    }

    # Ensure cleanup afterwards
    cleanup_add _cleanup_opencode_backend

    # Resolve the backend origin. OPENCODE_BACKEND_ORIGIN always overrides it.
    # Otherwise the backend serves on the container's private port 4096; a
    # host-side opencode CLI finds it on the published random host port
    # ("0:4096" via the port override), resolved back from docker once. The
    # in-container tui exposes no host port: the backend is reached over the
    # compose network.
    if [[ -n "${OPENCODE_BACKEND_ORIGIN:-}" ]]; then
        backend_origin="$OPENCODE_BACKEND_ORIGIN"
    elif _opencode_on_host; then
        local backend_port
        backend_port="$(_backend_host_port)" || {
            echo "Failed to resolve the published backend port" >&2
            echo "Run 'opencode:compose port opencode 4096' to inspect the mapping." >&2
            exit 1
        }
        backend_origin="http://$LOOPBACK:$backend_port"
        echo "Backend: $backend_origin"
    else
        backend_origin="http://opencode:4096"
        echo "Backend: $backend_origin"
    fi

    # Start or reuse the backend in the workspace's container
    if ! _backend_healthy; then
        # Start the backend in the background
        _driver compose "${opencode_compose_args[@]}" exec \
            -d \
            -w "$CONTAINER_WORKSPACE_ROOT" \
            opencode "$START_BACKEND_SERVE_EXE"

        echo "Waiting for the opencode backend to launch"
        if ! _wait_for_backend; then
            echo "OpenCode server failed to start" >&2
            echo "It may be a delayed start" >&2
            exit 1
        fi
    fi

    echo "Backend ready. Attaching..."

    # Start a TUI against the backend and wait
    _run_opencode_tui_executable "$@"

    # Verify container status afterwards
    container_id="$(_driver compose "${opencode_compose_args[@]}" ps -q -a opencode)"
    if [[ -z "$container_id" ]]; then
        echo "The container was removed: $container_id"
        exit 1
    else
        echo "The opencode process ended"
        echo "Cid: $container_id"
    fi
}

# Execute commands in an existing opencode container, without creating a new
# instance.
function opencode:execute() {
    echo "Executing in opencode project: $oc_project_name ($oc_workspace)"

    # The container is not ensured running first: the old ensure_up call
    # stays disabled.
    #_opencode_ensure_up

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "exec"
        exit 1
    fi

    # Interactive exec
    _driver compose "${opencode_compose_args[@]}" exec -it opencode "$@"
}

function opencode:shell() {
    opencode:execute sh "$@"
}

# Run a task (e.g. 'npm install') inside the opencode service: a
# non-interactive variant of opencode:execute for one-off build/setup
# commands. Running persistent container -> the task runs in it (left
# running); otherwise a throwaway `compose run` container runs it and exits,
# publishing no ports.
function opencode:run() {
    echo "Running in opencode project: $oc_project_name ($oc_workspace)"

    if [ "$#" -gt 0 ]; then
        echo "Running command in the container"
        _opencode_dispatch 0 "$@"
    else
        echo "No arguments were provided."
        _opencode_help_cmd "run"
        exit 1
    fi
}

# Run setup commands on an existing persisted opencode instance: the given
# non-interactive commands against the running container, else a throwaway
# `compose run` container, then back to the user shell with any pre-existing
# container still running.
function opencode:setup() {
    echo "Setting up opencode project: $oc_project_name ($oc_workspace)"

    _opencode_ensure_up || {
        echo "Failed to start the opencode container" >&2
        exit 1
    }

    opencode:list "$oc_workspace"

    if [ "$#" -gt 0 ]; then
        echo "Running command in the container"
        # Resources are created in that container
        _opencode_dispatch 0 "$@"
    fi
}

# Create the workspace image definition: an ocdocker folder holding a copy of
# the launcher's Dockerfile.example, plus the exports pointing the compose
# build at it (see 'create --dockerfile' in the help).
function _create_workspace_docker_file() {
    # The workspace this runs in
    local workspace
    workspace="$(_opencode_current_workspace)"

    local ws_docker_folder="$workspace/ocdocker"

    if [[ -e "$ws_docker_folder" ]]; then
        echo "Docker folder already exists" >&2
        return 0
    fi

    mkdir "$ws_docker_folder"

    local dockerfile="$ws_docker_folder/Dockerfile"

    cp "$SD_OPENCODE/Dockerfile.example" "$dockerfile"

    echo "Add the following to your environment:"
    echo "export OPENCODE_DOCKERFILE=\"$dockerfile\""
    echo "export OPENCODE_CONTEXT=\"$workspace\""
}

# Create an agent worktree 'opencode:uptree' starts, i.e. one
# _get_worktree_info names under $SD_AGENT_TREE_ROOT: <project>-dev without a
# branch (uptree's default), or <project>-<branch> for a branch of your own,
# so one project can hold several agent worktrees side by side (start with
# 'uptree --branch <branch>').
#
#   _create_worktree [<branch>]
#
# Created from the current HEAD with 'git worktree add -B <branch>' - the
# command 'uptree' prints when the worktree is missing; -B also moves a branch
# left over from an earlier removed worktree (git refuses when it is checked
# out elsewhere). Host-side only, like --dockerfile: runs git, never docker.
# Idempotent: an existing worktree of this repository is reported and left
# alone, so re-running never resets a branch or discards work.
function _create_worktree() {
    local branch_arg="${1:-}"

    if [[ "$has_git" == false ]]; then
        echo "error: create --worktree requires git in PATH" >&2
        return 1
    fi

    local workspace
    workspace="$(_opencode_current_workspace)" || return 1

    # rev-parse covers both layouts: a .git directory (repository) and a .git
    # file (worktree pointing into the parent).
    if ! git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: create --worktree requires a git repository: $workspace" >&2
        return 1
    fi

    # Agent worktrees hang off the repository, so the name and git commands
    # anchor there (as 'uptree' anchors its lookup in repo_ws): the effective
    # workspace may be a running worktree child or this worktree, itself named
    # <project>-dev, which would leak into the new name
    # (<project>-dev-<branch>), a path 'uptree --branch' never looks up.
    local repo_ws="$workspace"
    if [[ -f "$workspace/.git" ]]; then
        repo_ws="$(_git_worktree_parent "$workspace/.git")"
        if [[ -z "$repo_ws" ]]; then
            repo_ws="$workspace"
        fi
    fi

    # create is dispatched before workspace resolution, so derive the project
    # name here the way main() does: after the repository.
    oc_project_name="$(_sanitize_name "$(basename "$repo_ws")")"

    local wstree_name="" wstree_root=""
    _get_worktree_info wstree_name wstree_root "" "$branch_arg"

    local branch="${branch_arg:-$wstree_name}"

    # The root is not created: SD_AGENT_TREE_ROOT may be shared per-host
    # storage, so its absence is a configuration problem to report.
    if [[ ! -d "$TREE_ROOT" ]]; then
        echo "error: no directory at the worktree root: $TREE_ROOT" >&2
        return 1
    fi

    if [[ -e "$wstree_root" || -L "$wstree_root" ]]; then
        # Report an existing worktree of this repository; never touch a path
        # that is something else - it is not ours to remove.
        if [[ -f "$wstree_root/.git" ]]; then
            local parent_workspace
            parent_workspace="$(_git_worktree_parent "$wstree_root/.git")"
            if [[ "$parent_workspace" == "$repo_ws" ]]; then
                echo "Worktree already exists: $wstree_root"
                # The branch argument is ignored here; name the branch in
                # place to show why.
                local current_branch
                current_branch="$(git -C "$wstree_root" branch --show-current 2>/dev/null || true)"
                if [[ -n "$current_branch" && "$current_branch" != "$branch" ]]; then
                    echo "On branch '$current_branch', not the requested '$branch'"
                fi
                echo "git worktree remove \"$wstree_root\"   # to recreate it"
                return 0
            fi
        fi
        echo "error: path exists and is not a worktree of $repo_ws: $wstree_root" >&2
        return 1
    fi

    if ! git -C "$repo_ws" worktree add -B "$branch" "$wstree_root"; then
        echo "error: could not create the worktree: $wstree_root" >&2
        return 1
    fi

    echo "Created worktree '$branch': $wstree_root"
    echo "Start a container for it with:"
    echo "opencode:uptree \"$wstree_root\""
}

# Create the assets of a workspace on the host: a workspace image definition
# (--dockerfile) and/or the agent worktree (--worktree). Each action has its
# own option, several combine in one invocation, running in the order given.
# No default action: a bare 'create' reports the options instead of guessing.
function opencode:create() {
    if [ "$#" -lt 1 ]; then
        echo "error: create requires an action (--dockerfile, --worktree)" >&2
        _opencode_help_cmd "create" >&2
        exit 2
    fi

    local -a args=("$@")
    local i=0
    while ((i < ${#args[@]})); do
        case "${args[i]}" in
        --dockerfile | --Dockerfile | -df)
            _create_workspace_docker_file || exit 1
            ;;
        --worktree | --wt | -w)
            # Optional branch name follows.
            local branch=""
            if ((i + 1 < ${#args[@]})) && [[ "${args[i + 1]}" != -* ]]; then
                branch="${args[i + 1]}"
                i=$((i + 1))
            fi
            _create_worktree "$branch" || exit 1
            ;;
        *)
            printf 'error: unknown option: %s\n' "${args[i]}" >&2
            _opencode_help_cmd "create" >&2
            exit 2
            ;;
        esac
        i=$((i + 1))
    done
}

# Execute arbitrary Docker Compose commands for the opencode project: direct
# access for advanced container management.
function opencode:compose() {
    echo "Running Docker Compose for project: $oc_project_name ($oc_workspace)"

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "compose"
        exit 1
    fi

    # Straight through to Docker Compose
    _driver compose "${opencode_compose_args[@]}" "$@"
}

# Update the opencode launcher installation. Unlike other commands this is
# not tied to a workspace/compose project: it only refreshes the launcher
# repo and images inside $SD_OPENCODE.
function opencode:update() {
    echo "Updating opencode launcher: $SD_OPENCODE"

    read -r -p "Update will stop and delete all existing containers resources (excluding cache). Are you sure you want to continue? [y/N] " answer || true

    if [[ "${answer:-}" != "y" && "${answer:-}" != "Y" ]]; then
        echo "Update cancelled."
        exit 1
    fi

    echo "Do not start containers while an update is in-progress"

    # No containers during the update; images are rebuilt
    opencode:stop
    opencode:delete --all

    # Refresh the repo holding the launcher, compose files and Dockerfiles.
    git -C "$SD_OPENCODE" pull

    echo "Ok, if you really want to... you could start new containers, but the update has not yet completed."

    # Does not rebuild each workspace image
    (
        cd "$SD_OPENCODE" || exit 1

        trap 'kill 0; exit 130' INT
        trap 'kill 0; exit 143' TERM

        # Every selectable variant on the configured version layer (see
        # IMAGE_VERSION), so switching a workspace between them is a local
        # image lookup, not a pull.
        for variant in empty duck full; do
            docker pull "devsnowdon/opencode-docker:$variant-$IMAGE_VERSION"
        done
    )
}

# Teardown the project for the specified workspace: compose resources
# (containers, networks, volumes) via 'down', then any remaining managed
# containers (e.g. the TUI one-off) scoped to the workspace; the workspace
# configuration is preserved.
function opencode:down() {
    echo "Stopping opencode project: $oc_project_name ($oc_workspace)"

    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    # down only removes the current workspace's project, so "--other"
    # (everything except it) has no coherent meaning here.
    if ((other)); then
        echo "error: --other,-o cannot be combined with down: it only removes the current workspace's project" >&2
        exit 2
    fi
    if ((this)); then
        echo "error: --this,-t cannot be combined with down: it only removes the current workspace's project" >&2
        exit 2
    fi

    # 'compose down' leaves one-off 'compose run' containers (like the TUI):
    # stop the remaining managed ones scoped to this workspace.
    local stop_args=("$oc_workspace")
    ((dry_run)) && stop_args+=(--dry-run)
    opencode:stop "${stop_args[@]}"

    # Stop and remove containers, networks, and volumes
    if ((dry_run)); then
        echo "DRY RUN: docker compose ${opencode_compose_args[*]} down"
    else
        _driver compose "${opencode_compose_args[@]}" down
    fi
}

# Start the opencode container with no process in it: it stays alive in the
# background to attach to later with 'opencode:execute', without the overhead
# of creating it.
function opencode:up() {
    echo "Starting opencode container: $oc_project_name ($oc_workspace)"

    _driver compose "${opencode_compose_args[@]}" up -d opencode "$@"

    opencode:list "$oc_workspace"
}

# Write the name and root of the project's agent worktree through the two
# namerefs: the location 'opencode:uptree' starts a container for and
# 'opencode:create --worktree' creates it at:
#
#   _get_worktree_info <out_name> <out_root> [project_name] [branch]
#
# The suffix keeps it from colliding with the project name: compose project
# names are globally unique by container basename, so a worktree container
# must not be named after the parent repository. No branch -> 'dev' (the
# canonical agent worktree uptree uses by default); a branch -> its sanitized
# name, so a project holds several worktrees (<project>-<branch>) side by
# side. Sanitized because the suffix joins the compose project name, which
# allows only lowercase letters, digits, '-' and '_'.
#
# A branch sanitizing to 'dev' would name the canonical worktree, so 'dev' is
# reserved: such a branch gets no worktree, refused rather than silently
# claiming the canonical slot on create or selecting it on uptree.
function _get_worktree_info() {
    local project_name="${3:-$oc_project_name}"
    if [[ -z "$project_name" ]]; then
        echo "Error: no project name" >&2
        exit 1
    fi
    local suffix="dev"
    local branch="${4:-}"
    if [[ -n "$branch" ]]; then
        suffix="$(_sanitize_name "$branch")"
        # A branch holding no name characters at all (e.g. one made of '/' and
        # '.') would name the worktree '<project>-' and silently collide with
        # whatever the next worktree is called.
        if [[ -z "$suffix" ]]; then
            echo "Error: branch name '$branch' yields no worktree name" >&2
            exit 1
        fi
        # 'dev' is the canonical agent worktree suffix, the one 'create
        # --worktree' without a branch makes and 'uptree' without --branch
        # starts. A branch that sanitizes to it (any case or punctuation, so
        # 'DEV' and 'dev.' too) would take that very slot over, leaving the
        # canonical worktree nowhere to live, so the name is reserved rather
        # than silently confusing the two. A branch that merely ends in it
        # (feature/dev -> feature-dev) is untouched.
        if [[ "$suffix" == "dev" ]]; then
            echo "Error: branch name '$branch' is reserved: $TREE_ROOT/$project_name-dev is the canonical agent worktree, so no branch worktree can be named after it" >&2
            exit 1
        fi
    fi
    local -n tmp_wstree_name="$1"
    local -n tmp_wstree_root="$2"
    tmp_wstree_name="$project_name-$suffix"
    tmp_wstree_root="$TREE_ROOT/$tmp_wstree_name"
}

# Like up, but initialises a child worktree.
#
#   opencode:uptree <workspace> <branch> [compose args...]
#
# <branch> picks which agent worktree of <workspace> to start: empty -> the
# canonical $TREE_ROOT/<project>-dev, a branch -> the one 'create --worktree
# <branch>' made at $TREE_ROOT/<project>-<branch>, so several agent worktrees
# of one project run side by side. It must exist; otherwise the 'git worktree
# add' line to run is printed.
#
# FEATURE: explicitly refer to a worktree here (and for git, as
# `launcher --worktree git`): none found in the docker database or by resolving
# the effective path -> fall back to the default location.
function opencode:uptree() {
    if [[ "$has_git" == false ]]; then
        echo "No git command in path. Git is required work worktrees"
    fi

    local start_ws
    # NOTE: should be a -t, --target /some/path option instead of relying on
    # main()'s path resolve logic
    start_ws="$1"
    shift
    local branch="${1:-}"
    if (($# > 0)); then
        shift
    fi

    # Exactly like an explicit workspace path, an explicit branch is
    # authoritative: with another agent worktree of the same project already
    # running, the request is not redirected to it - the branch is looked up.
    local path_given="${workspace_path_given:-0}"
    if [[ -n "$branch" ]]; then
        path_given=1
    fi

    # if path is a worktree git repo, just up it
    if [[ -z "$branch" && -f "$start_ws/.git" ]]; then
        _opencode_ctx opencode:up "$start_ws" "$@"
        return $?
    fi

    # Agent worktrees all hang off their repository, so from inside one the
    # lookup runs against its parent: sibling names and paths are anchored
    # there, not in the worktree itself.
    local repo_ws="$start_ws"
    if [[ -n "$branch" && -f "$start_ws/.git" ]]; then
        repo_ws="$(_git_worktree_parent "$start_ws/.git")"
        if [[ -z "$repo_ws" ]]; then
            repo_ws="$start_ws"
        fi
    fi

    # create the worktree
    if [[ ! -d "$TREE_ROOT" ]]; then
        echo "No directory at the worktree root: $TREE_ROOT"
        return 1
    fi

    global_skip_assert_worktree=1

    # does it have a worktree exiting non standard worktree
    if [[ -z "$branch" ]]; then
        local ws_out="$start_ws" has_parent=""
        _resolve_effective_workspace ws_out has_parent "$path_given"

        if [[ "$start_ws" != "$ws_out" ]]; then
            # an effective worktree was found; only a parent can hold one,
            # so PROJECT_NAME is set
            _opencode_ctx opencode:up "$ws_out" "$@"
            exit $?
        fi
    fi

    # must differ from the project name: basenames are globally unique
    local wstree_name="" wstree_root=""
    _get_worktree_info wstree_name wstree_root \
        "$(_sanitize_name "$(basename "$repo_ws")")" "$branch"
    oc_project_name="$wstree_name" # set the global

    # The branch the worktree sits on: without one the worktree is named after
    # the branch it carries, so both default to the same name.
    local wt_branch="${branch:-$wstree_name}"

    if [[ -d "$wstree_root" ]]; then
        local git_pointer="$wstree_root/.git"
        if [[ -f "$git_pointer" ]]; then
            local parent_workspace
            parent_workspace="$(_git_worktree_parent "$git_pointer")"
            if [[ "$parent_workspace" != "$repo_ws" ]]; then
                echo "Error: Resolved workspace is not the current workspace"
                return 1
            fi
            # should be cheap because has parent is true, no docker commands?
            _opencode_ctx opencode:up "$wstree_root" "$@"
            exit $?
        else
            echo "Worktree is a directory, but has not been initialised: $wstree_root"
            echo "  git -C \"$repo_ws\" worktree add -B \"$wt_branch\" \"$wstree_root\""
            exit 1
        fi
    else
        echo "Worktree does not exist, needs initialising: $wstree_root"
        echo "  git -C \"$repo_ws\" worktree add -B \"$wt_branch\" \"$wstree_root\""
        echo "  or create it with: opencode:create --worktree $wt_branch"
        exit 1
    fi
}

# Create a new opencode project scaffold with git initialization: set up a new
# project workspace with proper configuration and launch the opencode runner to
# begin development.
#
# E.g. /home/user/repos/gists/one and /home/user/repos/projects/one both
# become "one". A future improvement: a sanitized full relative path for
# uniqueness, keeping Compose naming compatibility (lowercase, hyphens).
#
# FEATURE: custom agent and model configuration for scaffold via environment variables or config files.
function opencode:scaffold() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "scaffold"
        exit 1
    fi

    echo "Running on opencode project: $oc_project_name ($oc_workspace)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within
    # the container.
    local tmp_context
    tmp_context="<task-information>
You are creating the inital project scaffold.
The inital project information is as follows.
$(_print_cpu_context)
$CONTAINER_WORKSPACE_ROOT is the project: $oc_project_name
Working directory: $CONTAINER_WORKSPACE_ROOT
Workspace contents of $CONTAINER_WORKSPACE_ROOT:
\`\`\`
$(ls -la "$oc_workspace")
\`\`\`
$(_print_readme)
$(_print_git_context)
</task-information>

Your task is as follows:

"

    # A background job of the host launcher (the container itself still lives
    # in the docker daemon). Its output is captured to a temp file and streamed
    # to the terminal; on Ctrl+C the existing INT trap -> EXIT -> cleanup_add
    # stack kills the compose client and the container instead of docker's
    # (absent, with -T) signal proxy.
    local cname="oc-scaffold-$$"
    local outfile status=0
    outfile="$(mktemp "${tmp_sd_root_dir}/opencode-scaffold.XXXXXX")" || return 1

    _cleanup_scaffold_name="$cname"
    _cleanup_scaffold_output="$outfile"
    _cleanup_scaffold_pid=""
    cleanup_add _cleanup_scaffold

    # Execute opencode with context information
    {
        printf '%s' "$tmp_context"
        if [[ ! -t 0 ]]; then
            cat
        elif [ "$#" -gt 0 ]; then
            printf '%s' "$1"
        fi
    } | _driver compose "${opencode_compose_args[@]}" \
        run --rm -T --name "$cname" opencode 'exec opencode run "$@"' \
        opencode --auto "$@" >"$outfile" 2>&1 &
    _cleanup_scaffold_pid=$!

    # Stream the captured output to the terminal
    tail -f "$outfile" &
    local _tail_pid=$!
    wait "$_cleanup_scaffold_pid" || status=$?
    kill "$_tail_pid" 2>/dev/null || true

    return "$status"
}

# Run a one-off, non-interactive opencode task against an existing workspace.
# Like scaffold, minus the empty-directory requirement (the workspace usually
# already holds code - the point): task context is worded for an existing
# project, and the result streams via the same background one-off container +
# Ctrl+C-safe teardown.
function opencode:bg() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "bg"
        exit 1
    fi

    echo "Running background task on opencode project: $oc_project_name ($oc_workspace)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within
    # the container.
    local tmp_context
    tmp_context="<task-information>
You are running a task in the existing project.
$(_print_cpu_context)
$CONTAINER_WORKSPACE_ROOT is the project: $oc_project_name
Working directory: $CONTAINER_WORKSPACE_ROOT
Workspace contents of $CONTAINER_WORKSPACE_ROOT:
\`\`\`
$(ls -la "$oc_workspace")
\`\`\`
$(_print_readme)
$(_print_git_context)
</task-information>

Your task is as follows:

"

    # A background job of the host launcher (the container itself still lives
    # in the docker daemon). Its output is captured to a temp file and streamed
    # to the terminal; on Ctrl+C the existing INT trap -> EXIT -> cleanup_add
    # stack kills the compose client and the container instead of docker's
    # (absent, with -T) signal proxy.
    local cname="oc-bg-$$"
    local outfile status=0
    outfile="$(mktemp "${tmp_sd_root_dir}/opencode-bg.XXXXXX")" || return 1

    _cleanup_bg_name="$cname"
    _cleanup_bg_output="$outfile"
    _cleanup_bg_pid=""
    cleanup_add _cleanup_bg

    # Execute opencode with context information
    {
        printf '%s' "$tmp_context"
        if [[ ! -t 0 ]]; then
            cat
        elif [ "$#" -gt 0 ]; then
            printf '%s' "$1"
        fi
    } | _driver compose "${opencode_compose_args[@]}" \
        run --rm -T --name "$cname" opencode 'exec opencode run "$@"' \
        opencode run --auto "$@" >"$outfile" 2>&1 &
    _cleanup_bg_pid=$!

    # Stream the captured output to the terminal
    tail -f "$outfile" &
    local _tail_pid=$!
    wait "$_cleanup_bg_pid" || status=$?
    kill "$_tail_pid" 2>/dev/null || true

    return "$status"
}

# Run a non-interactive `opencode run` in its own throwaway container,
# streaming output to the terminal and waiting for it. The prompt is piped on
# stdin (as bg and scaffold do); remaining arguments are forwarded to `opencode run`.
#
# Unlike _opencode_dispatch this never reuses a running container: mounts are
# fixed when a container is created, so an io-style run's (io, changes
# --output) read-only workspace needs a container of its own. `run --rm` drops
# it when it exits, so name and pid are cleared once the wait returns - they
# only survive while the run is in flight, for _cleanup_io to act on an
# interrupted run.
#
#   _io_oneoff_run <container-name> <stream-file> <prompt> [run args...]
function _io_oneoff_run() {
    local cname="$1" stream="$2" prompt="$3"
    shift 3
    local status=0

    _cleanup_io_name="$cname"
    _cleanup_io_pid=""

    printf '%s' "$prompt" | _driver compose "${opencode_compose_args[@]}" \
        run --rm -T --name "$cname" \
        -w "$CONTAINER_WORKSPACE_ROOT" \
        --entrypoint /bin/sh \
        opencode \
        -c 'exec "$@"' \
        sh \
        opencode run --auto "$@" >"$stream" 2>&1 &
    _cleanup_io_pid=$!

    # Stream the captured output to the terminal
    tail -f "$stream" &
    local _tail_pid=$!
    wait "$_cleanup_io_pid" || status=$?
    kill "$_tail_pid" 2>/dev/null || true

    _cleanup_io_pid=""
    _cleanup_io_name=""

    return "$status"
}

# Run a task against a read-only workspace with N controlled writable outputs.
#
#   opencode:io [--output <path>]... [--allow-empty] [task] [opencode args...]
#
# The whole workspace is mounted read-only and every --output read-write (see
# _write_io_override), so the agent cannot touch the project and writes only
# the declared outputs. A directory output (existing directory, or path ending
# in '/') mounts as a directory, mkdir -p'd when missing; anything else is a
# file, created when missing and truncated before the run, so it holds exactly
# what this run wrote. Relative paths resolve against the workspace.
#
# The task is the first positional argument, or stdin when no task argument is
# given - the documented usage:
#
#     opencode:io --output /tmp/out.md < /tmp/create-task.md
#
# An output that is empty after the run is a failure instead of an empty
# result handed to whatever reads it next; --allow-empty skips that check. io
# is neutral about what the task produces: the plan-then-run flow (plan
# wording in the prompt, the "Run it with: opencode:bg" hand-off) lives in
# 'changes --output', which runs its agent step exactly like this.
#
# The run uses its own throwaway container rather than the running one, since
# mounts cannot be changed once a container exists.
function opencode:io() {
    local task=""
    local -a outputs=() rest=()
    local allow_empty=0

    # --output may appear anywhere and repeats; everything else keeps its
    # order as the task and any extra arguments for `opencode run`.
    if ! _opencode_parse_output_flags outputs allow_empty rest "$@"; then
        _opencode_help_cmd "io"
        return 1
    fi

    if ((${#outputs[@]} == 0)); then
        echo "Error: io requires at least one output (--output <path>)" >&2
        _opencode_help_cmd "io"
        return 1
    fi

    # The task: the first positional argument, or stdin when none is given.
    # Checked before the outputs are touched, so a run without a task creates
    # or truncates nothing.
    if ((${#rest[@]} > 0)) && [[ "${rest[0]}" != -* ]]; then
        task="${rest[0]}"
        rest=("${rest[@]:1}")
    elif [[ ! -t 0 ]]; then
        task="$(cat)"
    fi

    if [[ -z "$task" ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "io"
        return 1
    fi

    # Resolve, validate and prepare the outputs: they are what this run
    # writes, so a rejected set must leave the host untouched and a file must
    # hold exactly what this run wrote.
    local -a out_hosts=() out_containers=() out_is_dir=()
    _io_outputs_prepare out_hosts out_containers out_is_dir "${outputs[@]}" || return 1

    echo "Running task on opencode project: $oc_project_name ($oc_workspace)"
    echo "Read-only workspace mount: $oc_workspace -> $CONTAINER_WORKSPACE_ROOT"
    local i
    for ((i = 0; i < ${#out_hosts[@]}; i++)); do
        echo "Writable output mount: ${out_hosts[i]} -> ${out_containers[i]}"
    done

    local prompt
    prompt="<task-information>
You are running a task in the existing project.
$(_print_cpu_context)
$CONTAINER_WORKSPACE_ROOT is the project: $oc_project_name
Working directory: $CONTAINER_WORKSPACE_ROOT
$(_print_writable_surfaces out_hosts out_containers out_is_dir)
Workspace contents of $CONTAINER_WORKSPACE_ROOT:
\`\`\`
$(ls -la "$oc_workspace")
\`\`\`
$(_print_readme)
$(_print_git_context)
</task-information>

Your task is as follows:

$task"

    local stream
    stream="$(mktemp "${tmp_sd_root_dir}/opencode-io.XXXXXX")" || return 1
    _cleanup_io_outfile="$stream"
    cleanup_add _cleanup_io

    # The workspace as prepared for every command, plus the override that
    # turns its mount read-only and mounts the outputs read-write.
    local -a io_mounts=()
    for ((i = 0; i < ${#out_hosts[@]}; i++)); do
        io_mounts+=("${out_hosts[i]}" "${out_containers[i]}")
    done
    _write_io_override "$oc_workspace" io_mounts
    opencode_compose_args+=(-f "$tmp_io_file")

    local status=0
    _io_oneoff_run "oc-io-$$" "$stream" "$prompt" \
        "${rest[@]+"${rest[@]}"}" || status=$?
    if ((status != 0)); then
        echo "The run failed (status $status)." >&2
        return "$status"
    fi

    # The outputs are the result of this command: a run that left one empty
    # produced nothing there - a failure rather than something to pipe
    # onwards.
    _io_outputs_check out_hosts out_is_dir "$allow_empty" || return 1

    for ((i = 0; i < ${#out_hosts[@]}; i++)); do
        echo "Output written to: ${out_hosts[i]}"
    done
    return 0
}

# Stop existing opencode containers before starting a fresh session.
function opencode:new() {
    opencode:stop

    echo "Starting fresh opencode container for project: $oc_project_name"
    opencode "$@"
}

# Parse the option flags shared by the stop/delete/list/down command family
# into caller-supplied variables. All four flags are recognised everywhere, so
# the commands behave consistently even when they only act on a subset.
#
#   _opencode_parse_flags <out_all> <out_other> <out_quiet> <out_dry_run> <out_args> [args...]
#
# Sets (by nameref):
#   out_all     1 when --all or -a was given, else 0.
#   out_other   1 when --other or -o was given, else 0.
#   out_quiet   1 when --quiet or -q was given, else 0.
#   out_dry_run 1 when --dry-run was given, else 0.
#   out_args    The remaining positional arguments, in their original order.
function _opencode_parse_flags() {
    local -n out_all="$1"
    local -n out_other="$2"
    local -n out_quiet="$3"
    local -n out_dry_run="$4"
    local -n out_this="$5"
    local -n out_args="$6"
    shift 6

    out_all=0
    out_other=0
    out_quiet=0
    out_dry_run=0
    out_this=0
    out_args=()

    local arg
    local parsing_options=1

    for arg in "$@"; do
        if ((parsing_options)); then
            case "$arg" in
            --)
                parsing_options=0
                continue
                ;;

            --all | --resources)
                out_all=1
                ;;

            --other | --others)
                out_other=1
                ;;

            --quiet)
                out_quiet=1
                ;;

            --dry-run)
                out_dry_run=1
                ;;
            --this)
                out_this=1
                ;;
            --*)
                printf 'error: unknown option: %s\n' "$arg" >&2
                return 2
                ;;

            -?*)
                opts=${arg#-}
                for ((i = 0; i < ${#opts}; i++)); do
                    case "${opts:i:1}" in
                    a | r) out_all=1 ;;
                    o) out_other=1 ;;
                    q) out_quiet=1 ;;
                    n) out_dry_run=1 ;;
                    t) out_this=1 ;;
                    *)
                        printf 'error: unknown option: -%s\n' "${opts:i:1}" >&2
                        return 2
                        ;;
                    esac
                done
                ;;
            *)
                out_args+=("$arg")
                ;;
            esac
        else
            out_args+=("$arg")
        fi
    done
}

# Resolve the workspace --other must preserve: the effective workspace for the
# calling context, not the directory the command was invoked from. Inside an
# opencode context/repl WORKSPACE is already resolved; otherwise the invoked
# directory resolves through _opencode_args_prepare's git worktree logic (a
# synced worktree child supersedes its parent), so --other preserves the
# container, image and network of the workspace actually in use.
function _opencode_current_workspace() {
    if [[ -n "${oc_workspace:-}" ]]; then
        printf '%s\n' "$oc_workspace"
        return 0
    fi

    local ws has_parent="" rc
    ws="$(realpath "$PWD")"

    _resolve_effective_workspace ws has_parent
    local rc=$?

    if ((rc != 0)); then
        return $rc
    fi

    printf '%s\n' "$ws"
}

# Stop the existing managed containers. Pass --all to include oneoff
# (throwaway `compose run`) containers. An optional workspace argument scopes
# the stop to containers for it; by default all workspaces are stopped.
function opencode:stop() {
    echo "Stopping existing opencode containers"

    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if ((other && this)); then
        echo "$THIS_OTHER_ERROR" >&2
        exit 1
    fi

    # The first positional argument scopes the stop; empty = all workspaces.
    # A container-id prefix (not an existing directory) is matched against
    # running containers directly.
    local ws_scope=""
    if ((this)); then
        ws_scope="$(_opencode_current_workspace)"
    elif [[ -n "${args[0]:-}" ]]; then
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        else
            local cid="${args[0]}"
            local ids count
            ids="$(_driver container_ls -q --filter id="$cid")"
            count=$(printf '%s\n' "$ids" | grep -c .)
            if [ "$count" -ne 1 ]; then
                echo "Search term did not exist as a path"
                echo "Search found multiple containers with that id prefix"
                exit 1
            fi
            _driver container_stop "$ids"
            return 0
        fi
    fi

    local find_args=()
    [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
    ((all)) && find_args+=(--all)
    ((other)) && find_args+=(--other "$(_opencode_current_workspace)")

    local ws_label
    while read -r id; do
        [[ -z "$id" ]] && continue
        ws_label="$(_find_workspace "$id")"
        if [[ -n "$ws_label" && "$ws_label" != "${oc_workspace:-}" ]]; then
            echo "Stopping managed container $id (workspace: $ws_label)"
        else
            echo "Stopping managed container $id"
        fi
        _driver container_stop "$id" || true
    done < <(_select_managed_containers "${find_args[@]}")
}

# Print the entries of the array named by $1 that are not a whole line of the
# array named by $2, i.e. the first array minus the second:
#   _ws_except <items_array> <exclude_array>
# Used by delete to drop the resources of the workspace --other preserves from
# the ids discovered for removal. An empty exclude array passes everything
# through, and matching is whole-line, so no id is a substring of another. An
# empty selection prints nothing at all.
function _ws_except() {
    local -n items="$1"
    local -n drop="$2"
    # Nothing to print for an empty selection: printf of an empty expansion
    # would still emit a blank line, read back as one empty id.
    if ((${#items[@]} == 0)); then
        return 0
    fi
    local -a patterns=()
    local item
    for item in "${drop[@]+"${drop[@]}"}"; do
        patterns+=(-e "$item")
    done
    if ((${#patterns[@]} == 0)); then
        printf '%s\n' "${items[@]}"
        return 0
    fi
    printf '%s\n' "${items[@]}" | grep -vFx "${patterns[@]}"
}

# Force-remove all managed opencode containers: unlike 'stop' this removes
# them immediately with 'docker rm -f' - for a stuck container or a full clean
# up. Pass --all to include oneoff (throwaway `compose run`) containers, and to
# also remove the workspace images and networks. An optional workspace argument
# scopes the delete; by default all workspaces are removed.
#
# Resources (images, networks) are selected by the workspace they are labelled
# with (see _ws_resource_ls): for a worktree its own path, plus the worktree
# parent they carry. A command scoped to a repository therefore covers that
# repository's worktrees - `delete --this` then `delete --all --this` still
# removes the worktree's image: by then only the container relating the
# worktree to its repository is gone, the image and network still name it.
# `--other` preserves the workspace in use and its worktrees.
#
# FEATURE: cid does not work with multiple arguments
# FEATURE: if --this has multiple child worktrees, it errors with an invalid number of children instead of deleting them (via a cid works)
# FEATURE: if the workspace has a parent (a worktree), warn when its status is not clean?
function opencode:delete() {
    # also for stop, down
    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    local ws_label
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if ((other && this)); then
        echo "$THIS_OTHER_ERROR" >&2
        exit 1
    fi

    #if (( !other && !this && ${#args[@]} == 0 )); then
    #    # implies current workspace, or this workspace
    #    this=1
    #fi

    # --dry-run needs no explicit handling: every destructive primitive below
    # goes through _docker_run_destructive, which sees this function's local
    # dry_run (bash dynamic scoping) and reports instead of acting.

    local find_args=(--stopped)
    ((all)) && find_args+=(--all)

    # --other force-removes everything except the current workspace (and its
    # worktrees); the current workspace's containers, images, and networks are
    # preserved.
    local other_ws=""
    if ((other)); then
        other_ws="$(_opencode_current_workspace)"
        find_args+=(--other "$other_ws")
    fi

    # The first positional argument scopes the delete; empty = all
    # workspaces. A container-id prefix (not an existing directory) is matched
    # against containers directly.
    local ws_scope=""
    local cid_match=0
    if ((this)); then
        ws_scope="$(_opencode_current_workspace)"
    elif [[ -n "${args[0]:-}" ]]; then
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        else
            cid_match=1
        fi
    fi

    function _ws_remove() {
        local -n remove_ids="$1"
        if ((${#remove_ids[@]} < 1)); then
            return 0
        fi
        _driver container_rm -f "${remove_ids[@]}" || {
            echo "Error: failed to remove container(s)"
        }
    }

    if ((cid_match)); then
        # finds any that match
        local cid="${args[0]}"
        local -a ids=()
        local count
        mapfile -t ids < <(_driver container_ls -a -q --filter "id=$cid")
        if [ ${#ids[@]} -ne 1 ]; then
            echo "Search term did not exist as a path"
            echo "Search found multiple containers with that conatiner id prefix"
            exit 1
        fi
        ws_label="$(_find_workspace "${ids[0]}")"
        # set so if --all is given it only acts on this container
        ws_scope="$ws_label"
        _ws_remove ids
    else
        [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
        local -a container_ids=()
        local rc
        mapfile -t container_ids < <(_select_managed_containers "${find_args[@]}" | sort -u)
        _ws_remove container_ids
    fi

    if [ "$all" -eq 1 ]; then
        # A scoped delete covers the resources of the worktrees of the scoped
        # workspace, which name it as their worktree parent, plus its own (see
        # _ws_resource_ls); an unscoped delete already reaches everything,
        # through the bare labels below.
        #
        # When --other is set, preserve the resources of the workspace in use
        # and its worktrees: other_ws is the effective workspace
        # (worktree-resolved via _opencode_current_workspace), collected with
        # the worktrees naming it as their parent, so a worktree is spared even
        # when its container is already deleted and no longer resolves it.
        local -a exclude_iids=() exclude_nids=()
        local -a kept=()
        if ((other)); then
            mapfile -t kept < <(_ws_resource_ls image "$other_ws")
            exclude_iids=("${kept[@]+"${kept[@]}"}")
            mapfile -t kept < <(_ws_resource_ls network "$other_ws" --filter \
                "label=$LABEL_NETWORK_MANAGED=true")
            exclude_nids=("${kept[@]+"${kept[@]}"}")
        fi

        # remove the workspace image, not the base image
        local -a images=() networks=()
        if [[ -n "$ws_scope" ]]; then
            mapfile -t images < <(_ws_resource_ls image "$ws_scope")
            mapfile -t networks < <(_ws_resource_ls network "$ws_scope" --filter \
                "label=$LABEL_NETWORK_MANAGED=true")
        else
            mapfile -t images < <(
                _driver image_ls -q --filter "label=$LABEL_IMAGE_WORKSPACE"
            )
            mapfile -t networks < <(
                _driver network_ls -q --filter "label=$LABEL_NETWORK_MANAGED"
            )
        fi

        # drop the preserved resources of the --other workspace
        mapfile -t images < <(_ws_except images exclude_iids)
        mapfile -t networks < <(_ws_except networks exclude_nids)

        if ((${#images[@]})); then
            _driver image_rm "${images[@]}"
        fi
        if ((${#networks[@]})); then
            _driver network_rm "${networks[@]}"
        fi
    fi
}

# Print the managed opencode containers in a ps-style table. By default oneoff
# (throwaway `compose run`) containers are skipped; pass --all to include them.
# An optional workspace argument scopes the listing to containers labelled for
# that workspace, including those launched from its git worktrees (parent label
# match); stop/delete are NOT parent-scoped, they only act on exact matches.
# Pass --quiet to print only the container ids (one per line), for scripting.
#
# FEATURE: rich list info is too heavy and scales badly - have the running process write a mark under /tmp/sd-opencode so instances are tracked without probing
# FEATURE: list --up - only list the containers that are up
# FEATURE: list --on-off - list only the oneoff containers
function opencode:list() {
    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if ((other && this)); then
        echo "$THIS_OTHER_ERROR" >&2
        exit 1
    fi

    # The first positional argument scopes the listing; empty = all
    # workspaces. Listing is intentionally anchored at the physical current
    # directory: resolving it to one canonical child would make a parent with
    # several worktrees ambiguous and prevent listing the other children.
    local ws_scope=""
    if ((this)); then
        ws_scope="$(realpath "$PWD")"
    elif [[ -n "${args[0]:-}" ]]; then
        # Only resolve existing directories; a bogus path would otherwise abort
        # under `set -e` on realpath implementations that fail on missing paths.
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        fi
    fi

    local other_ws=""
    if ((other)); then
        other_ws="$(realpath "$PWD")"
    fi

    local find_args=(--stopped)
    [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
    ((all)) && find_args+=(--all)
    ((other)) && find_args+=(--other "$other_ws")

    # A workspace scope also lists containers launched from its git
    # worktrees: those carry dev.snowdon.opencode.parent=<ws_scope>, so query
    # that label too and merge. Docker --filter clauses are AND-ed and a
    # container never holds both labels, hence two lookups deduped by sort -u.
    # --other must also exclude such worktree children of the current
    # workspace.
    local parent_args=(--stopped --parent "$ws_scope")
    ((all)) && parent_args+=(--all)
    ((other)) && parent_args+=(--other "$other_ws")

    # Discover the ids first, then inspect them in a single `docker inspect`
    # call (one record per line) instead of one round-trip per container. The
    # ids come out of `sort -u` sorted, but docker inspect preserves no
    # particular output order, so the records are sorted again to keep the
    # listing deterministic. See _container_infos for the rationale.
    local -a ids=()
    local id
    while read -r id; do
        [[ -z "$id" ]] && continue
        ids+=("$id")
    done < <({
        _select_managed_containers "${find_args[@]}"
        [[ -n "$ws_scope" ]] && _select_managed_containers "${parent_args[@]}"
    } | sort -u)

    local -a records=()
    local rec
    while read -r rec; do
        records+=("$rec")
    done < <(_container_infos "${ids[@]}" | sort)

    if ((${#records[@]} == 0)); then
        if ((quiet)); then
            return 0
        fi
        echo "No managed opencode containers${ws_scope:+ for $ws_scope}"
        return 0
    fi

    # quiet mode: the short container id only, one per line (scripting friendly).
    if ((quiet)); then
        local -a fields=()
        for rec in "${records[@]}"; do
            _rec_fields fields "$rec"
            printf '%s\n' "${fields[0]:0:12}"
        done
        return 0
    fi

    # Column header lengths seed the width tracking so the table stays aligned.
    local -a ids=() statuses=() workspaces=() projects=() modes=() fields=()
    local id status ws proj oneoff istui mode
    local dlen=12 slen=6 wlen=9 plen=7 mlen=4
    for rec in "${records[@]}"; do
        _rec_fields fields "$rec"
        id="${fields[0]:0:12}"
        status="${fields[1]:-?}"
        ws="${fields[2]:--}"
        proj="${fields[3]:--}"
        oneoff="${fields[4]:-}"
        istui="${fields[5]:-false}"
        if [[ "${istui,,}" == "true" ]]; then
            mode="tui"
        elif [[ "${oneoff,,}" == "true" ]]; then
            mode="one off"
        else
            # STATUS mirrors the container's own docker State.Status: a
            # running main container reports "running", a stopped one its own
            # state (e.g. "exited"). Whether the opencode backend serves
            # inside it is no longer probed - docker exec per container does
            # not scale. Serving vs idle should come from a marker the running
            # process drops once that exists.
            mode="main"
        fi
        ids+=("$id")
        statuses+=("$status")
        workspaces+=("$ws")
        projects+=("$proj")
        modes+=("$mode")
        ((${#id} > dlen)) && dlen=${#id}
        ((${#status} > slen)) && slen=${#status}
        ((${#ws} > wlen)) && wlen=${#ws}
        ((${#proj} > plen)) && plen=${#proj}
        ((${#mode} > mlen)) && mlen=${#mode}
    done

    printf "%-${dlen}s %-${slen}s %-${wlen}s %-${plen}s %-${mlen}s\n" \
        "CONTAINER ID" "STATUS" "WORKSPACE" "PROJECT" "MODE"
    for ((i = 0; i < ${#ids[@]}; i++)); do
        printf "%-${dlen}s %-${slen}s %-${wlen}s %-${plen}s %-${mlen}s\n" \
            "${ids[i]}" "${statuses[i]}" "${workspaces[i]}" "${projects[i]}" "${modes[i]}"
    done
}

# Analyse the workspace branch changes with a non-interactive opencode run:
# the git changes are gathered inside the container (paths are
# container-relative), then `opencode run --agent plan` analyses the code and
# proposes a plan without making changes; its output streams to the terminal.
#
#   opencode:changes [--output <path>]... [--allow-empty] [task] [opencode args...]
#
# With --output the agent step switches to the io machinery (see opencode:io):
# its own throwaway container with the read-only workspace and declared
# outputs, the post-run checks, and the plan handed over with the "Run it with:
# opencode:bg" hint. The run is a plain `opencode run`, not the plan agent:
# that agent refuses edits outright and would refuse to write the plan file
# itself - here the read-only workspace keeps the project untouched and the
# outputs are the only writable surfaces. Without --output the run reuses the
# running container (read-write, streamed to the terminal).
function opencode:changes() {
    local task=""
    local -a outputs=() rest=()
    local allow_empty=0

    if ! _opencode_parse_output_flags outputs allow_empty rest "$@"; then
        _opencode_help_cmd "changes"
        return 1
    fi

    # The task: the first positional argument, stdin when none is given, or
    # the default plan task. Extracted before anything else touches a
    # container, so a piped task cannot be eaten by the git analysis below.
    if ((${#rest[@]} > 0)) && [[ "${rest[0]}" != -* ]]; then
        task="${rest[0]}"
        rest=("${rest[@]:1}")
    elif [[ ! -t 0 ]]; then
        task="$(cat)"
    fi
    if [[ -z "$task" ]]; then
        task="analyze the branch changes above and produce a detailed plan of action to address them."
    fi

    # Declared writable outputs are prepared before any container work, so a
    # bad path fails before the analysis below has run anything.
    local -a out_hosts=() out_containers=() out_is_dir=()
    if ((${#outputs[@]} > 0)); then
        _io_outputs_prepare out_hosts out_containers out_is_dir "${outputs[@]}" || return 1
    fi

    # TODO: behaviour when the effective workspace is not the cwd: pulling changes into the parent repo and running changes there with a worktree enabled - does it use the worktree?
    echo "Analyzing changes for project: $oc_project_name ($oc_workspace)"

    # Run the git analysis against the existing container when it is running,
    # otherwise a throwaway `compose run` container; either way the returned
    # paths (under /workspace/project) match what opencode sees. Captured for
    # feeding into opencode below. Must happen before the io override joins
    # opencode_compose_args: the analysis composes from that array and must
    # run with the normal read-write mounts (it only reads).
    local changes
    changes="$(_opencode_dispatch 0 "$GIT_CHANGES_EXE")" || {
        echo "Failed to gather changes." >&2
        exit 1
    }

    echo "$changes"
    #if (($(printf '%s\n' "$changes" | wc -l) < 500)); then
    #  echo "$changes"
    #else
    #  printf '%s\n' "$changes" | sed -n '1,500p'
    #  echo "... output truncated ..."
    #fi

    local prompt="<task-information>
Project: $oc_project_name
Working directory: $CONTAINER_WORKSPACE_ROOT
Branch changes:
\`\`\`
$changes
\`\`\`"

    # With outputs declared, the agent is told where it may write - the same
    # fragment io gets, in one place.
    if ((${#outputs[@]} > 0)); then
        prompt+="
$(_print_writable_surfaces out_hosts out_containers out_is_dir)"
    fi
    prompt+="
The environment for this session does not apply to the output in any way. The output applies to the project in the working directory."

    prompt+="
</task-information>

Your task is as follows:

$task
"

    local status=0
    local i
    if ((${#outputs[@]} > 0)); then
        # Output mode: the io machinery - the override joins the compose
        # args last (the read-only workspace mount replaces the normal one),
        # and the agent runs on its own throwaway container, which `run --rm`
        # drops when it exits.
        local -a io_mounts=()
        for ((i = 0; i < ${#out_hosts[@]}; i++)); do
            io_mounts+=("${out_hosts[i]}" "${out_containers[i]}")
        done
        _write_io_override "$oc_workspace" io_mounts
        opencode_compose_args+=(-f "$tmp_io_file")

        local stream
        stream="$(mktemp "${tmp_sd_root_dir}/opencode-changes.XXXXXX")" || return 1
        _cleanup_io_outfile="$stream"
        cleanup_add _cleanup_io

        # A plain `opencode run` on the default agent: the plan agent
        # restricts edit/bash to "ask" and would refuse to write the plan file
        # itself. Here the containment is the mounts - read-only workspace,
        # only the declared outputs writable.
        _io_oneoff_run "oc-changes-$$" "$stream" "$prompt" \
            "${rest[@]+"${rest[@]}"}" || status=$?
    else
        # Without outputs the run is unchanged: a non-interactive opencode
        # session using the built-in plan agent, reusing the running container
        # when present (interactive dispatch), output streaming to the
        # terminal.
        local cname="oc-changes-$$"
        local outfile
        outfile="$(mktemp "${tmp_sd_root_dir}/opencode-changes.XXXXXX")" || return 1

        _cleanup_changes_name="$cname"
        _cleanup_changes_output="$outfile"
        _cleanup_changes_pid=""
        cleanup_add _cleanup_changes

        printf '%s' "$prompt" | _opencode_dispatch 0 \
            opencode run --agent plan --auto "${rest[@]+"${rest[@]}"}" >"$outfile" 2>&1 &
        _cleanup_changes_pid=$!

        # Stream the captured output to the terminal
        tail -f "$outfile" &
        local _tail_pid=$!
        wait "$_cleanup_changes_pid" || status=$?
        kill "$_tail_pid" 2>/dev/null || true
    fi
    if ((status != 0)); then
        return "$status"
    fi

    if ((${#out_hosts[@]} > 0)); then
        _io_outputs_check out_hosts out_is_dir "$allow_empty" || return 1

        for ((i = 0; i < ${#out_hosts[@]}; i++)); do
            echo "Plan written to: ${out_hosts[i]}"
        done
        # The plan file is the task of the next step: bg reads it back from
        # stdin against the normal read-write workspace. The exact hand-off is
        # only spelled out for a single file output; anything more complex is
        # left to the user.
        if ((${#out_hosts[@]} == 1)) && ((out_is_dir[0] == 0)); then
            echo "Run it with: opencode:bg ./ < ${out_hosts[0]}"
        fi
    fi
    return 0
}

function opencode:git() {
    if [[ "$has_git" == false ]]; then
        echo "The git command does not exist"
        return 1
    fi

    local ws
    ws="$(_opencode_current_workspace)"

    if ((!($# > 0))); then
        echo "Git requires args"
        git --help
        return 1
    fi

    git -C "$ws" "$@"
}

_repl_run_path=""

function _cleanup_opencode_repl_run() {
    if [[ -n "$_repl_run_path" && -f "$_repl_run_path" ]]; then
        rm -- "$_repl_run_path"
    fi
}

# Entry point for the bare-name aliases set up inside the interactive
# workspace shell (_opencode_dispatch_shims). Maps a typed command to the
# matching opencode:* function, forwarding any arguments, so calls like
#   run npm install        -> opencode:run npm install
#   exec git log --oneline -> opencode:exec git log --oneline
# work exactly like a normal function invocation.
function _opencode_shim() {
    local cmd="$1"
    shift

    # Bail out rather than let an unset/empty runs dir turn the template
    # below into "/<cmd>.XXXXX" (the filesystem root). Not fatal: this runs
    # behind an alias in the interactive shell, which must survive a bad
    # command.
    if [[ -z "${_oc_repl_parent_dir:-}" ]]; then
        echo "$cmd: the repl runs directory is not set" >&2
        return 1
    fi

    [[ ! -d "$_oc_repl_parent_dir" ]] && mkdir "$_oc_repl_parent_dir"

    # mktemp needs at least six X's in the last component; with the five below
    # busybox mktemp rejects the template outright ("Invalid argument"), so no
    # repl command could record a run at all.
    local run_path_tmp="$_oc_repl_parent_dir/$cmd.XXXXXX"
    _repl_run_path="$(mktemp "$run_path_tmp")"

    (
        # traps inside subshell for proper cleanup and signal handling
        _cleanup_stack=()
        trap _cleanup_run EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cleanup_add _cleanup_opencode_repl_run

        # Run in a subshell so a command's own 'exit' (e.g. opencode's failure
        # paths) cannot terminate the interactive workspace shell itself.
        case "$cmd" in
        # 'start' is served by the main opencode() function, not opencode:start.
        start) opencode "$@" ;;
        *) opencode:"$cmd" "$@" ;;
        esac
    )
}

# Define bare-name aliases (run, exec, up, ...) forwarding to the opencode:*
# functions, now that the workspace shell is a real interactive bash. Only
# names not already on PATH are aliased, so system commands (git, ls) keep
# their meaning; bash builtins (exec, help) are overridden because the
# opencode functions are this shell's point. The aliases keep the old REPL
# behaviour ('run npm install') while still allowing the full non-prefixed
# command line.
function _opencode_dispatch_shims() {
    local cmd kind
    for cmd in \
        start new up setup down delete list execute stop run shell scaffold bg io \
        git changes compose update help; do
        #kind="$(type -t "$cmd" 2>/dev/null || true)"
        #if [[ -z "$kind" || "$kind" == "builtin" ]]; then
        BASH_ALIASES["$cmd"]="_opencode_shim $cmd"
        #fi
    done
}

_oc_repl_acquire() {
    (
        flock -x 200

        # Don't acquire a deleted resource
        if [[ ! -e "$_repl_global_project_dir" ]]; then
            echo "file doesn't exist"
            exit 1
        fi

        # Read into a separately declared variable: 'local count=$(<...)'
        # swallows the read's status, so errexit cannot catch a missing
        # file.ref and the empty value is then counted as zero.
        local count
        count=$(<"$_oc_repl_ref_global")
        echo $((count + 1)) >"$_oc_repl_ref_global"
    ) 200>"$_oc_repl_lock_global"
}

_oc_repl_release() {
    (
        flock -x 200

        # Kept separate from the declaration for the same reason as in
        # _oc_repl_acquire: a failed read must abort rather than decrement an
        # empty value to -1, which never reaches 0, so leaves the global
        # directory behind (and recreates the ref file cleanup removes).
        local count
        count=$(<"$_oc_repl_ref_global")
        count=$((count - 1))
        echo "$count" >"$_oc_repl_ref_global"

        if ((count == 0)); then
            rm -fr -- "$_repl_global_project_dir" "$_oc_repl_ref_global"

            # clean global dir if empty
            rmdir "$_tmp_repl_global_dir" 2>/dev/null
        fi
    ) 200>"$_oc_repl_lock_global"
}

# Remove the interactive workspace shell's rcfile.
function _cleanup_repl() {
    if [[ -n "$_cleanup_repl_rcfile" ]]; then
        rm -f -- "$_cleanup_repl_rcfile"
        _cleanup_repl_rcfile=""
    fi

    _oc_repl_release
}

_oc_repl_prompt() {
    local run_count
    run_count=$(find "$_oc_repl_parent_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)

    PS1='\[\e[38;5;46m\]⌂ '"$oc_project_name"'\[\e[38;5;39m\]   ⚡ \[\e[38;5;214m\]tasks: '"$run_count"'\[\e[0m\]
\[\e[38;5;39m\]❯ \[\e[0m\]'
}

# Launch a real interactive bash shell bound to the workspace. Every opencode
# command is available as the bare name -- with normal argument passing:
#
#   run npm install
#   execute git log --oneline
#   list --all
#
# Be careful mixing these with commands on the shell PATH. The rcfile rebuilds
# the workspace context (WORKSPACE, PROJECT_NAME, OPENCODE_ARGS, cwd) once,
# sources the user's ~/.bashrc for a normal shell environment, and registers
# the bare-name aliases above. A single command still needs no context: compose
# args are prepared here like the other commands, and the rcfile reuses them.
#
# FEATURE: in the repl modify the environment variables instead of sourcing the script (_last_workspace_session=ilwlfnwefn)
# FEATURE: while a repl is open, should the opencode server stay open? At least if started once; closing it on exit
function custom_repl() {
    local ws="$1"
    shift || true

    # Prepare the compose args and OPENCODE_ARGS in the current shell so the
    # dispatched command and its helpers can use them, then run the command in
    # a subshell so its traps and cwd changes do not leak into the launcher.
    local has_parent=""
    local ws_out="$ws"
    _resolve_effective_workspace ws_out has_parent "${workspace_path_given:-0}"

    # first workspace, $second_workspace, $has_parent
    if ! _check_within_workspace "$ws" "$ws_out" "$has_parent"; then
        _assert_continue_outside_workspace "$ws"
    fi

    # main() sets PROJECT_NAME before dispatching, but keep this
    # self-sufficient so direct calls behave like the other commands.
    if [[ -z "$oc_project_name" ]]; then
        oc_project_name="$(basename "$ws")"
    fi

    local -a args=()
    _opencode_args_prepare "$ws_out" "$has_parent" args || return 1

    opencode_compose_args=("${args[@]}")
    ws="$ws_out"

    # Resolve the launcher's own path so the rcfile can 'source' it for the
    # opencode:* definitions; the entry-point guard below stops main() from
    # re-dispatching when that source runs.
    local launcher_path
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        launcher_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    else
        launcher_path="$0"
    fi

    cleanup_add _cleanup_repl

    _cleanup_repl_rcfile="$(mktemp "${tmp_sd_root_dir}/opencode-repl.XXXXXX")" || return 1

    _tmp_repl_global_dir="/tmp/ocsd-info"
    _repl_global_project_dir="$_tmp_repl_global_dir/$oc_project_name"
    _oc_repl_ref_global="$_repl_global_project_dir/file.ref"
    _oc_repl_lock_global="$_repl_global_project_dir/file.lock"

    # The runs directory the interactive shell records live commands in, read
    # by _opencode_shim and _oc_repl_prompt. Assigned here as well as in the
    # rcfile below (the shell cannot inherit this), so it is always a real
    # path: left empty, the shim's mktemp template collapses to
    # "/<cmd>.XXXXX" and lands in the filesystem root.
    _oc_repl_parent_dir="$_repl_global_project_dir/runs"
    [[ ! -d "$_oc_repl_parent_dir" ]] && mkdir -p "$_oc_repl_parent_dir"
    [[ ! -e "$_oc_repl_ref_global" ]] && echo 0 >"$_oc_repl_ref_global"
    _oc_repl_acquire

    # Build the interactive shell's rcfile. Values are embedded with %q so
    # paths/names with spaces survive re-parsing inside the shell.
    {
        printf '%s\n' '# Auto-generated interactive opencode workspace shell. Do not edit.'
        printf 'source %s\n' "$(printf '%q' "$launcher_path")"
        printf '%s\n' 'set +e +u'
        printf '%s\n' 'set +o pipefail'
        # Interactive signal handling: defaults restored so Ctrl+C interrupts
        # the running foreground job instead of exiting the shell.
        printf '%s\n' 'cleanup_add _cleanup'
        printf '%s\n' 'trap _cleanup_run EXIT'
        printf '%s\n' 'trap - INT TERM'
        printf 'oc_workspace=%s\n' "$(printf '%q' "$ws")"
        printf 'WORKSPACE=%s\n' "$(printf '%q' "$ws")"
        # The worktree parent, exported next to WORKSPACE: the env var behind
        # the image's dev.snowdon.opencode.workspace_parent label (the compose
        # build file passes it as the PROJECT_WORKSPACE_PARENT build arg). A
        # build run from this shell without it labels the worktree's image
        # with no parent, so a delete scoped to the repository never reaches
        # the image once the worktree's container is gone.
        printf 'WORKSPACE_PARENT=%s\n' "$(printf '%q' "$has_parent")"
        printf 'oc_project_name=%s\n' "$(printf '%q' "$oc_project_name")"
        printf '_oc_repl_parent_dir=%s\n' "$(printf '%q' "$_oc_repl_parent_dir")"
        printf '%s\n' 'export oc_workspace oc_project_name WORKSPACE WORKSPACE_PARENT'
        printf 'declare -a opencode_compose_args=(\n'
        local arg
        for arg in "${args[@]}"; do
            printf '  %s\n' "$(printf '%q' "$arg")"
        done
        printf '%s\n' ')'
        printf 'cd %s || { echo "workspace removed: %s" >&2; return 1; }\n' \
            "$(printf '%q' "$ws")" "$(printf '%q' "$ws")"
        # Deliberately do NOT re-source ~/.bashrc: the outer shell's
        # environment (PATH, exported variables) is inherited intact, the same
        # one the launcher CLI runs with. Re-sourcing a bashrc that replaces
        # PATH (instead of appending) would drop docker from PATH, and every
        # opencode docker command would then fail.
        printf 'if ! command -v %s >/dev/null 2>&1; then\n' "$(printf '%q' "$DRIVER")"
        printf '  echo "warning: %s not on PATH - opencode docker commands will fail" >&2\n' "$(printf '%q' "$DRIVER")"
        printf '%s\n' 'fi'
        printf '%s\n' '_opencode_dispatch_shims'
        # Single quotes on purpose: this is a line of rcfile source that the
        # child shell expands when it reads the rcfile. Double quotes would
        # run _oc_repl_prompt here, at rcfile-generation time.
        # shellcheck disable=SC2016
        printf '%s\n' 'PROMPT_COMMAND=_oc_repl_prompt'
        printf '%s\n' 'unset -f _opencode_dispatch_shims 2>/dev/null || true'
    } >"$_cleanup_repl_rcfile"

    echo "                               .___                     .___           "
    echo "  ______ ____   ______  _  ____| _/____   ____        __| _/_______  __"
    echo " /  ___//    \ /  _ \ \/ \/ / __ |/  _ \ /    \      / __ |/ __ \  \/ /"
    echo " \___ \|   |  (  <_> )     / /_/ (  <_> )   |  \    / /_/ \  ___/\   / "
    echo "/____  >___|  /\____/ \/\_/\____ |\____/|___|  / /\ \____ |\___  >\_/  "
    echo "     \/     \/                  \/           \/  \/      \/    \/      "
    echo
    echo "Interactive opencode shell for $ws (project: $oc_project_name)"
    echo "  type 'run <cmd>', 'exec <cmd>', 'opencode:list --all', or 'help'"
    echo "  type 'exit' to leave the shell"
    echo "  repl is in development, so be careful. It is just a source of the script."
    echo "  Modifying variables could kill you"

    bash --rcfile "$_cleanup_repl_rcfile" -i
    return $?
}

# Print detailed help for a single command.
# Usage: _opencode_help_cmd <name>
# Falls back to a generic message if no help exists for the command.
function _opencode_help_cmd() {
    local name="$1"
    case "$name" in
    start)
        echo "start [opencode args...]"
        echo "  (Re)create the opencode container and run an interactive opencode session"
        echo "  in the current workspace. The container is recreated to apply the latest"
        echo "  compose configuration, then 'opencode' is launched with any trailing args"
        echo "  passed through to the opencode CLI."
        echo "  Args:"
        echo "    opencode args...   Additional arguments forwarded to the opencode CLI."
        ;;
    new)
        echo "new [opencode args...]"
        echo "  Stop existing opencode containers, then start a fresh container and"
        echo "  opencode session."
        echo "  Args:"
        echo "    opencode args...   Additional arguments forwarded to the opencode CLI."
        ;;
    up)
        echo "up [compose up args...]"
        echo "  Start the opencode container in the background without running any"
        echo "  process inside it. Useful to keep the container alive so it can be"
        echo "  attached to later with 'exec'."
        echo "  Args:"
        echo "    compose up args...   Additional arguments forwarded to 'docker compose up'."
        ;;
    uptree)
        echo "uptree [--branch <branch>] <workspace>"
        echo "  Start a container for an agent worktree, like 'up' does. Without a"
        echo "  branch the worktree is the canonical one, expected at"
        echo "  \$SD_AGENT_TREE_ROOT/<project>-dev (default root:"
        echo "  \$SD_REPO_HOME/agent-trees). With --branch (-b) it is the worktree of"
        echo "  that branch, expected at \$SD_AGENT_TREE_ROOT/<project>-<branch>,"
        echo "  which is what 'create --worktree <branch>' creates: a project can"
        echo "  hold several agent worktrees side by side, each with its own"
        echo "  container. The worktree must already exist: when it does not, the"
        echo "  'git worktree add' line to run is printed instead, or create it"
        echo "  with 'create --worktree'. A branch whose name sanitizes to 'dev'"
        echo "  is refused: that name is reserved for the canonical worktree, so"
        echo "  it would select that one instead of a branch of your own."
        echo "  Args:"
        echo "    --branch, -b <branch>  The agent worktree to start, named after"
        echo "                    this branch (default: the <project>-dev one)."
        echo "    workspace        The repository the worktree belongs to."
        echo "    compose args...  Additional arguments forwarded to 'docker compose up'."
        ;;
    setup)
        echo "setup [command...]"
        echo "  Run setup commands (e.g. 'npm install', 'go build') against the persisted"
        echo "  opencode instance. Uses the running container when present, otherwise the"
        echo "  persisted container is started. Like :up but running a command first."
        echo "  Args:"
        echo "    command...   The setup command (and its args) to run."
        ;;
    down)
        echo "down [workspace]"
        echo "  Remove the project's compose resources (containers, networks, volumes) and"
        echo "  stop any remaining managed containers (e.g. the TUI) for this workspace,"
        echo "  preserving the workspace configuration."
        echo "  Args:"
        echo "    [workspace] Optional path scoping which project is torn down"
        echo "                (defaults to the current directory)."
        echo "  '--other'/-o is not accepted here: down only ever removes the current"
        echo "  workspace's project, so it is refused (exit 2)."
        echo "    --dry-run   Print what would be torn down without doing it."
        ;;
    delete)
        echo "delete [<project>] [--all] [--other]"
        echo "  Force-remove all managed opencode containers across workspaces using"
        echo "  'docker rm -f'. Immediately removes stuck or unwanted containers."
        echo "  If <project> is not specified, all opencode-docker managed containers"
        echo "  will be removed"
        echo "  Args:"
        echo "    --all, -a       Also remove oneoff (throwaway 'compose run') containers,"
        echo "                    and the workspace images and networks. Scoped to a"
        echo "                    workspace, that covers the worktrees it owns as well"
        echo "                    (their images and networks name the worktree's"
        echo "                    repository as their parent), so it works after their"
        echo "                    containers have already been deleted."
        echo "    --other, -o     Force-remove everything except the current workspace"
        echo "                    and its worktrees; their containers, images, and"
        echo "                    networks are preserved."
        echo "    --dry-run, -n   Print what would be removed (containers, images, networks)"
        echo "                    without doing it."
        echo "    [project]       The path to the project to scope the delete to."
        echo "    --this, -t      Scope to the current workspace (worktree resolved)."
        ;;
    ls | list)
        echo "ls|list [directory] [--all] [--other] [--quiet]"
        echo "  List the managed opencode containers in a ps-style table (id, status,"
        echo "  workspace, project, mode), including stopped ones. Mode is one of"
        echo "  'tui', 'one off', or 'main'. By default oneoff (throwaway 'compose"
        echo "  run') containers are skipped."
        echo "  Args:"
        echo "    --all, -a   Also list oneoff (throwaway 'compose run') containers."
        echo "    --other, -o List every managed container except the current workspace's"
        echo "                (and its worktrees)."
        echo "    --quiet, -q Print only the container ids, one per line."
        echo "    [directory] Only list containers for this workspace. Optional."
        ;;
    exec)
        echo "exec [command...]"
        echo "  Run a command interactively inside the already-running opencode container."
        echo "  Args:"
        echo "    command...   The command (and its args) to run inside the container."
        ;;
    stop)
        echo "stop [<project>] [--all] [--other]"
        echo "  Gracefully stop the managed opencode containers across all workspaces,"
        echo "  freeing their ports. 'down' scopes this to the current workspace."
        echo "  If <project> is specified then only act on that project."
        echo "  Args:"
        echo "    --all, -a     Also stop oneoff (throwaway 'compose run') containers."
        echo "    --other, -o   Stop every managed container except the current workspace's"
        echo "                  (and its worktrees)."
        echo "    --dry-run, -n Print what would be stopped without doing it."
        echo "    [project]     The path to the project to scope the stop to."
        ;;
    run)
        echo "run [command...]"
        echo "  Run a one-off, non-interactive task (e.g. 'npm install', 'go build') inside"
        echo "  the opencode service. Uses the running container when present, otherwise a"
        echo "  throwaway 'compose run' container that exits and is removed."
        echo "  Args:"
        echo "    command...   The command (and its args) to run in the service."
        ;;
    shell)
        echo "shell [args...]"
        echo "  Open an interactive shell inside the opencode container. This is a"
        echo "  convenience alias for 'exec sh'. The container must already be running"
        echo "  (start it with 'up', 'setup' or 'start'); it is not created here."
        echo "  Args:"
        echo "    args...   Additional arguments passed to 'sh' inside the container."
        ;;
    repl)
        echo "repl"
        echo "  Launch a real interactive bash shell bound to the workspace. Every opencode"
        echo "  command is available as its bare name (run, exec, list, ...) with normal"
        echo "  argument passing. The rcfile rebuilds the workspace context once, so commands"
        echo "  skip per-invocation compose preparation."
        echo "  Args:"
        echo "    (none)"
        ;;
    git)
        echo "git <git args...>"
        echo "  Run a git command in the workspace directory on the host, not inside"
        echo "  the container."
        echo "  Args:"
        echo "    git args...   Any git subcommand and its arguments."
        ;;
    env)
        echo "env"
        echo "  Print the launcher variables exported in the current environment:"
        echo "  every SD_* and OPENCODE_* variable, one 'NAME=value' per line."
        echo "  No workspace is resolved, no compose arguments are prepared and"
        echo "  nothing is started, so it is safe before a workspace has ever been"
        echo "  launched, and it is the quickest way to check a shell profile or an"
        echo "  oh-my-zsh setup."
        echo "  Only exported variables appear: one set without 'export', or one that"
        echo "  lives solely in a .env file (the launcher does not read those), is"
        echo "  not shown."
        echo "  Args:"
        echo "    ws|workspace  Print the effective workspace path instead of variables."
        echo "  Examples:"
        echo "    launcher env | grep '^SD_'"
        echo "    launcher env | grep '^OPENCODE_CACHE'"
        ;;
    create)
        echo "create (--dockerfile) (--worktree [branch])"
        echo "  Create the assets of a workspace on the host. Each action is"
        echo "  requested by its own option, several can be combined in one"
        echo "  invocation (they run in the order given), and there is no default"
        echo "  action: a bare 'create' reports this help."
        echo "  --dockerfile (--Dockerfile, -df)"
        echo "    Copy the launcher's Dockerfile.example to"
        echo "    <workspace>/ocdocker/Dockerfile and print the"
        echo "    OPENCODE_DOCKERFILE/OPENCODE_CONTEXT exports that point the"
        echo "    compose build at it. Edit the copy, add those exports to your"
        echo "    environment, and the next launch builds the workspace image on"
        echo "    the base image. It is a no-op when ocdocker already exists:"
        echo "    that directory is reported and left untouched, so re-running"
        echo "    never overwrites your Dockerfile."
        echo "  --worktree (--wt, -w) [branch]"
        echo "    Create an agent worktree 'uptree' starts, at"
        echo "    \$SD_AGENT_TREE_ROOT/<project>-dev (default root:"
        echo "    \$SD_REPO_HOME/agent-trees, which has to exist), on 'branch'"
        echo "    (default: <project>-dev). With a branch of your own the worktree"
        echo "    is named after it instead, at"
        echo "    \$SD_AGENT_TREE_ROOT/<project>-<branch>, so one project can hold"
        echo "    several agent worktrees side by side (start one with"
        echo "    'uptree --branch <branch>'). Either way it is created from the"
        echo "    current HEAD, and an existing worktree of this repository is"
        echo "    reported and left alone. The command to start a container for it"
        echo "    is printed. The name 'dev' is reserved for the canonical"
        echo "    worktree, so a branch of that name is refused."
        echo "  Both actions write only, on the host: nothing is started and"
        echo "  docker is never called. <workspace> is the effective workspace, as"
        echo "  for every other command, so from a parent repository with one"
        echo "  synced worktree child it is that child."
        echo "  Args:"
        echo "    --dockerfile, --Dockerfile, -df   Action: scaffold the workspace"
        echo "                                     image definition."
        echo "    --worktree, --wt, -w [branch]    Action: create the agent"
        echo "                                     worktree."
        echo "    [branch]                         The branch for --worktree,"
        echo "                                     which also names the worktree:"
        echo "                                     <project>-dev by default,"
        echo "                                     <project>-<branch> otherwise."
        echo "  Examples:"
        echo "    launcher create --dockerfile"
        echo "    launcher create --worktree"
        echo "    launcher create --worktree feature/my-branch"
        echo "    launcher create --dockerfile --worktree"
        ;;
    scaffold)
        echo "scaffold [--path <name>] [path] (task) [opencode args...]"
        echo "  Create a new project using opencode at the target, which must be an"
        echo "  empty or not-yet-existing directory, then runs an interactive opencode"
        echo "  scaffolding session. With --path the target lives under SD_REPO_HOME"
        echo "  (default: /home/<user>/repos); otherwise the path is resolved as a real"
        echo "  path against the current directory ('./x' and 'x' -> \$PWD/x, '/x' -> /x)."
        echo "  If not given a task argument, it will read the task from stdin."
        echo "  - Unlike start, run, exec commands, a path in some form is required"
        echo "  stdin examples:"
        echo "    echo \"Add a parser for JSON\" | launcher scaffold some-project"
        echo "    echo \"Add a parser for JSON\" | launcher scaffold --path gists/some-project"
        echo "    launcher scaffold some-project < task.txt"
        echo "  Args:"
        echo "    --path <name>       Project name under SD_REPO_HOME. Optional."
        echo "    path                Real path (relative to the cwd) of the new project."
        echo "    task                A description of what opencode should do"
        echo "    opencode args...    Additional arguments forwarded to the opencode CLI."
        ;;
    bg)
        echo "bg [--path <name>] [path] (task) [opencode args...]"
        echo "  Run a one-off, non-interactive opencode task against an existing project."
        echo "  With --path the target lives under SD_REPO_HOME; otherwise the"
        echo "  path is resolved as a real path against the current directory."
        echo "  Output streams to the terminal while the task runs."
        echo "  If not given a task argument, it will read the task from stdin."
        echo "  - Unlike start, run, exec commands, a path in some form is required"
        echo "  - Unlike scaffold the target must already be a directory; it is never"
        echo "      created"
        echo "  stdin examples:"
        echo "    echo \"Add tests for the api\" | launcher bg some-project"
        echo "    echo \"Add tests for the api\" | launcher bg --path gists/some-project"
        echo "    launcher bg ./  < task.txt"
        echo "  task examples:"
        echo "    launcher bg some-project \"some task\""
        echo "  Args:"
        echo "    --path <name>       Project name under SD_REPO_HOME. Optional."
        echo "    path                Real path (relative to the cwd) of the project. Optional."
        echo "    task                A description of what opencode should do"
        echo "    opencode args...    Additional arguments forwarded to the opencode CLI."
        ;;
    io)
        echo "io [--output <path>]... [--allow-empty] [task] [opencode args...]"
        echo "  Run a task against a read-only workspace with one or more writable"
        echo "  output surfaces. The whole workspace is mounted read-only and every"
        echo "  --output is mounted read-write, so the agent cannot touch the project"
        echo "  and can only write to the declared outputs. A directory output is"
        echo "  mounted as a directory, created with mkdir -p when missing; anything"
        echo "  else is a file, created when missing and truncated before the run so"
        echo "  it holds exactly what this run wrote. An output left empty after the"
        echo "  run is reported as a failure unless --allow-empty is given."
        echo "  io is the neutral primitive: for the plan-then-run flow (plan wording,"
        echo "  the 'Run it with' hand-off to 'bg'), use 'changes --output'."
        echo "  The run always uses its own throwaway container: mounts cannot be"
        echo "  changed on a container that already exists."
        echo "  Args:"
        echo "    --output <path>   A writable output surface (required, repeatable)."
        echo "                      An existing directory, or a path ending in '/', is"
        echo "                      mounted as a directory; anything else is a file. A"
        echo "                      relative path resolves against the workspace."
        echo "    --allow-empty     Do not fail when an output is empty after the run."
        echo "    task              The task; read from stdin when not given."
        echo "    opencode args...  Additional arguments forwarded to 'opencode run'."
        echo "  Examples:"
        echo "    launcher io --output /tmp/out.md \"design the parser split\""
        echo "    launcher io --output /tmp/out.md --output /tmp/report/ < task.md"
        ;;
    security)
        echo "security"
        echo "  Analyse the repository for potential security risks such as executable"
        echo "  commands in normal usage (e.g. npm pre-install scripts)."
        echo "  NOTE: This command is not yet implemented."
        echo "  Args:"
        echo "    (none)"
        ;;
    clone)
        echo "clone [args...]"
        echo "  Retrieve a git repository and clone it into a managed location."
        echo "  'clone --check' should run security analysis first."
        echo "  NOTE: This command is not yet implemented."
        echo "  Args:"
        echo "    args...   Repository URL and destination arguments."
        ;;
    changes)
        echo "changes [--output <path>]... [--allow-empty] [task] [opencode args...]"
        echo "  Analyse the workspace branch changes inside the container and run a"
        echo "  non-interactive 'opencode run --agent plan' session that proposes a plan"
        echo "  without modifying the working tree. Output streams to the terminal."
        echo "  With --output the agent step switches to the io machinery (see 'help"
        echo "  io'): its own throwaway container with the workspace mounted read-only"
        echo "  and only the declared outputs writable. The run is a plain 'opencode"
        echo "  run', not the plan agent: that agent refuses edits outright and would"
        echo "  refuse to write the plan file itself - here the read-only workspace is"
        echo "  what keeps the project untouched. An empty output is reported as a"
        echo "  failure unless --allow-empty; the plan is handed over with 'Run it with:"
        echo "  opencode:bg'. Without --output the running container is reused, as before."
        echo "  Args:"
        echo "    --output <path>   A writable output surface (repeatable, file or"
        echo "                      directory); see 'help io'."
        echo "    --allow-empty     Do not fail when an output is empty after the run."
        echo "    task              Override the analysis task prompt. Read from stdin"
        echo "                      when not given; defaults to analysing the branch"
        echo "                      changes above."
        echo "    opencode args...  Additional arguments forwarded to 'opencode run'."
        echo "  Examples:"
        echo "    launcher changes"
        echo "    launcher changes --output /tmp/plan.md"
        ;;
    compose)
        echo "compose [docker compose args...]"
        echo "  Pass arbitrary arguments straight through to Docker Compose for this"
        echo "  project (e.g. 'logs', 'ps', 'config')."
        echo "  Args:"
        echo "    docker compose args...   Any 'docker compose' subcommand and its args."
        ;;
    update)
        echo "update"
        echo "  Refresh the opencode launcher installation. This is destructive: after"
        echo "  confirming, it stops and force-deletes every managed container (caches"
        echo "  are kept), then runs 'git pull' in the repository at SD_OPENCODE and"
        echo "  pulls the ':empty', ':duck' and ':full' base images for the current"
        echo "  version layer. Not tied to a workspace."
        echo "  Args:"
        echo "    (none)"
        ;;
    help)
        echo "help [command]"
        echo "  Show this overview, or detailed help for a single command."
        echo "  Args:"
        echo "    command   Show help for a specific command. Optional."
        ;;
    *)
        echo "No help available for command: $name" >&2
        return 1
        ;;
    esac
}

# Print the full launcher help: an overview of all commands plus a description
# of each command's purpose and arguments.
function opencode:help() {
    echo "opencode launcher - manage the opencode container and sessions"
    echo
    echo "Usage: $0 <command> [workspace] [args...]"
    echo
    echo "Commands:"
    printf '  %-11s %s\n' "start" "Create the container and run an interactive opencode session"
    printf '  %-11s %s\n' "new" "Stop existing containers and start a fresh session"
    printf '  %-11s %s\n' "up" "Start the container in the background without running a process"
    printf '  %-11s %s\n' "uptree" "Start a container for an existing agent worktree"
    printf '  %-11s %s\n' "setup" "Run setup commands against the persisted instance"
    printf '  %-11s %s\n' "down" "Remove the project's containers, networks, volumes, and TUI"
    printf '  %-11s %s\n' "delete" "Force-remove all managed opencode container resources across workspaces (--all for oneoffs, --other to spare the current workspace)"
    printf '  %-11s %s\n' "ls|list" "List managed opencode containers in a ps-style table (--all for oneoffs)"
    printf '  %-11s %s\n' "exec" "Run a command interactively inside the running container"
    printf '  %-11s %s\n' "git" "Run a git command in the workspace on the host"
    printf '  %-11s %s\n' "env" "Print the launcher variables exported in the environment"
    printf '  %-11s %s\n' "create" "Create a workspace asset on the host (--dockerfile, --worktree)"
    printf '  %-11s %s\n' "stop" "Stop the managed opencode containers across all workspaces (--all for oneoffs)"
    printf '  %-11s %s\n' "run" "Run a one-off non-interactive task in the service"
    printf '  %-11s %s\n' "shell" "Open an interactive shell inside the running container"
    printf '  %-11s %s\n' "repl" "Launch an interactive bash shell bound to the workspace with bare-name commands"
    printf '  %-11s %s\n' "scaffold" "Create a new opencode project with a fresh git repo"
    printf '  %-11s %s\n' "bg" "Run a one-off background opencode task on an existing project"
    printf '  %-11s %s\n' "security" "Analyse the repository for potential security risks (not implemented)"
    printf '  %-11s %s\n' "changes" "Analyse the branch changes and propose a plan (--output writes it into a writable file)"
    printf '  %-11s %s\n' "io" "Run a task on a read-only workspace with N writable outputs (--output, repeatable)"
    printf '  %-11s %s\n' "clone" "Clone a git repository into a managed location (not implemented)"
    printf '  %-11s %s\n' "compose" "Pass arguments straight through to Docker Compose"
    printf '  %-11s %s\n' "update" "Stop and delete all managed containers, then refresh the launcher repo and base images"
    printf '  %-11s %s\n' "help" "Show help; 'help <command>' for command details"
    echo
    echo "The workspace defaults to the current directory, and SD_OPENCODE points to"
    echo "the compose directory (default: \$HOME/opencode)."
    echo
    echo "stop, delete, and ls accept --all (-a) to include throwaway one-off"
    echo "'compose run' containers, --other (-o) to act on everything except the"
    echo "current workspace, and --this (-t) to act on the current workspace only."
    echo "delete --all also removes the workspace images and networks, and delete"
    echo "--other also preserves the current workspace's images and networks. A"
    echo "workspace covers its git worktrees, whose images and networks name it"
    echo "as their parent."
    echo
    echo "stop, delete, and down accept --dry-run to print what would be done"
    echo "without touching any container, image, or network."
    echo
    echo "create writes host files only, one action per option: --dockerfile (-df)"
    echo "scaffolds <workspace>/ocdocker/Dockerfile and --worktree (-w) [branch]"
    echo "creates an agent worktree uptree starts, at \$SD_AGENT_TREE_ROOT"
    echo "<project>-dev, or <project>-<branch> for a branch of your own."
    echo
    echo "Launcher behaviour is configured by OPENCODE_* and SD_* environment"
    echo "variables (build context, caches, networks, CPU limits, the"
    echo "OPENCODE_WORKSPACE guard, ...); see the project README for details."
    echo "'env' prints the ones exported in the current environment, which is the"
    echo "quickest way to check a shell profile before launching anything."
    echo
    echo "Run '$0 help <command>'   for details on a specific command."
    echo "Run '$0 <command> --help' for details on a specific command."
    echo "Run '$0 <command> -h'     for details on a specific command."

    if _driver image_inspect "$IMAGE_URL" >/dev/null 2>&1; then
        echo
        local opencode_version
        local devcontainer_version

        opencode_version="$(
            _driver image_inspect "$IMAGE_URL" \
                --format "{{ index .Config.Labels \"$LABEL_DEV_CONTAINER_VERSION\" }}"
        )"

        devcontainer_version="$(
            _driver image_inspect "$IMAGE_URL" \
                --format "{{ index .Config.Labels \"$LABEL_DEV_CONTAINER\" }}"
        )"

        echo "Docker image:       $IMAGE_URL"
        echo "OpenCode version:   ${opencode_version:-unknown}"
        echo "Devcontainer:       ${devcontainer_version:-unknown}"

        # Ask the image itself what OpenCode reports
        #local cli_version
        #cli_version="$(command opencode --version 2>/dev/null)"
        #echo "CLI version:        ${cli_version:-unknown}"
    fi

    echo "Git location:       $SD_OPENCODE"

    if [[ "$has_git" == true ]]; then
        local tags
        tags="$(git -C "$SD_OPENCODE" describe --tags --exact-match 2>/dev/null || echo unknown)"
        local commit
        commit="$(git -C "$SD_OPENCODE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        # Get the current git location from ~/opencode
        echo "Git tag:            $tags"
        echo "Git commit:         $commit"
    fi
}

# Resolve a scaffold/bg target into an absolute workspace path applying the
# command's existence policy:
#
#   scaffold - the target must be empty or not exist; it is created when
#              missing, or an existing empty directory is reused.
#   bg       - the target must be an existing directory; it is never created.
#
#   _resolve_project_path <out_ws> <policy> [<path>]
#
# <path> is a real path resolved against the cwd, never appended to
# $SD_REPO_HOME: './' -> $PWD, './x' -> $PWD/x, 'x' -> $PWD/x, '/x' -> /x.
# --path repo-home targets arrive pre-resolved by the caller as
# "$SD_REPO_HOME/<name>" (absolute) and pass through untouched. An empty
# <path> means $PWD. The resolved path is written back through the <out_ws>
# nameref (named ws_out_ so a same-named caller local cannot swallow it, see
# _check_valid_within_root). Non-zero on the error paths; callers exit 1.
function _resolve_project_path() {
    local -n ws_out_="$1"
    local policy="$2"
    local path="${3:-}"
    local ws=""

    if [[ -z "$path" ]]; then
        ws="$PWD"
    elif [[ "$path" == ./ ]]; then
        ws="$PWD"
    elif [[ "$path" == ./* ]]; then
        ws="$PWD/${path#./}"
    elif [[ "$path" == /* ]]; then
        ws="$path"
    else
        ws="$PWD/$path"
    fi

    if [[ "$policy" == "bg" ]]; then
        if [[ ! -d "$ws" ]]; then
            echo "bg requires an existing directory: $ws" >&2
            return 1
        fi
        echo "Using existing directory: $ws"
        ws_out_="$ws"
        return 0
    fi

    # scaffold: empty-or-create
    if [[ -e "$ws" || -L "$ws" ]]; then
        if [[ ! -d "$ws" ]]; then
            echo "Path already exists but is not a directory: $ws" >&2
            return 1
        fi
        echo "Using existing empty directory: $ws"
    else
        echo "Creating $ws"
        mkdir -p -- "$ws" || return 1
    fi
    ws_out_="$ws"
}

# Main entry point for the opencode launcher script: parse the command-line
# arguments and dispatch to the handler for the specified command.
function main() {
    local cmd="${1:-}"
    shift || true

    # Help doesn't need a workspace: handle it before any project setup.
    case "$cmd" in
    help | -h | --help)
        if [[ "$cmd" == "help" && -n "${1:-}" ]]; then
            _opencode_help_cmd "$1"
        else
            opencode:help
        fi
        return 0
        ;;
    esac

    # if the argument after cmd is --help or -h, redirect to help
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        _opencode_help_cmd "$cmd" || true
        exit 0
    fi

    # update etc does not operate on a workspace path or compose project, it
    # only refreshes the launcher repo and images, so handle it before any
    # workspace resolution.
    case "$cmd" in
    env)
        case "${1:-}" in
        ws | workspace)
            # print the effective workspace, for use in other tools etc
            local tmp_workspace
            if ! tmp_workspace="$(_opencode_current_workspace)"; then
                return 1
            fi
            printf '%s\n' "$tmp_workspace"
            return 0
            ;;
        esac
        # Print what the launcher reads from this shell. Only exported
        # variables show: the launcher assigns its own defaults (SD_OPENCODE
        # and friends) without exporting them. A group with no match at all
        # makes grep exit non-zero, which set -e would turn into a failure.
        env | grep -E "^SD_" || true
        env | grep -E "^OPENCODE_" || true
        return 0
        ;;
    git)
        opencode:git "$@"
        return 0
        ;;
    create)
        opencode:create "$@"
        return 0
        ;;
    update)
        opencode:update "$@"
        return 0
        ;;
    stop)
        opencode:stop "$@"
        return 0
        ;;
    delete)
        opencode:delete "$@"
        return 0
        ;;
    ls | list)
        opencode:list "$@"
        return 0
        ;;
    esac

    # Get the workspace directory from arguments or current directory
    local ws_out
    local workspace_path_given=0

    # uptree selects which agent worktree of the workspace to start with
    # --branch/-b <branch> (see opencode:uptree). The option is taken out of
    # the arguments here, before the path resolution below, so it can be given
    # before or after the workspace path without being read as the path
    # itself, and never reaches 'docker compose up' as one of its arguments.
    local uptree_branch=""
    if [[ "$cmd" == uptree ]]; then
        local -a plain_args=()
        while (($#)); do
            case "$1" in
            -b | --branch)
                if (($# < 2)); then
                    echo "error: $1 requires a branch name" >&2
                    exit 2
                fi
                uptree_branch="$2"
                shift 2
                ;;
            *)
                plain_args+=("$1")
                shift
                ;;
            esac
        done
        set -- "${plain_args[@]}"
    fi

    local path_in="${1:-}"

    case "$cmd" in
    scaffold)
        # Target: a leading --path <name> (a project name under
        # $SD_REPO_HOME), else the leading positional resolved as a real path
        # against the cwd, else the current directory. Remaining positionals
        # are the task and opencode args. scaffold requires the target to be
        # empty or not exist.
        local path_arg=""
        if [[ "${1:-}" == "--path" ]]; then
            [[ $# -ge 2 ]] || {
                echo "error: --path requires a project name" >&2
                exit 1
            }
            path_arg="${SD_REPO_HOME}/${2}"
            shift 2
        fi
        if [[ -z "$path_arg" && $# -ge 1 ]]; then
            path_arg="$1"
            shift
        fi
        [[ -n "$path_arg" ]] && workspace_path_given=1

        if [[ ! -t 0 && -z "$path_arg" ]]; then
            echo "You did not provide a task to scaffold." >&2
            exit 1
        fi
        if [[ -t 0 ]]; then
            if [[ -z "$path_arg" ]]; then
                echo "You did not provide a path to scaffold." >&2
                exit 1
            fi
            if (($# == 0)); then
                echo "You did not provide a task to scaffold." >&2
                exit 1
            fi
        fi

        _resolve_project_path ws_out scaffold "$path_arg" || exit 1
        ;;
    bg)
        # Same target resolution as scaffold: --path <name> under
        # $SD_REPO_HOME, else the leading positional as a real path, else the
        # current directory. Unlike scaffold, bg runs against an existing
        # project: the target must already be a directory, it is never
        # created.
        local path_arg=""
        if [[ "${1:-}" == "--path" ]]; then
            [[ $# -ge 2 ]] || {
                echo "error: --path requires a project prefix" >&2
                exit 1
            }
            path_arg="${SD_REPO_HOME}/${2}"
            shift 2
        fi
        if [[ -z "$path_arg" && $# -ge 1 ]]; then
            path_arg="$1"
            shift
        fi
        [[ -n "$path_arg" ]] && workspace_path_given=1

        if [[ ! -t 0 && -z "$path_arg" ]]; then
            echo "You did not provide a path to bg." >&2
            exit 1
        fi
        if [[ -t 0 ]]; then
            if [[ -z "$path_arg" ]]; then
                echo "You did not provide a path to bg." >&2
                exit 1
            fi
            if (($# == 0)); then
                echo "You did not provide a task to bg." >&2
                exit 1
            fi
        fi

        _resolve_project_path ws_out bg "$path_arg" || exit 1
        ;;
    esac

    # when argument one is a path starting with / or ./ capture it as the
    # ws_out, else we use the cwd.
    if [[ -z ${ws_out+x} ]]; then
        if [[ "$path_in" == ./* || "$path_in" == /* ]] && [[ -d $path_in ]]; then
            ws_out="$(realpath "$path_in")"
            workspace_path_given=1
            shift
        else
            ws_out="$PWD"
        fi
    fi

    # NOTE: if the container is already started, no need to assert. However,
    # checking would cost another docker call.
    #
    # Skip this check when SD_YOLO is set to "true" (case-insensitive).
    # Checks whether the workspace lies outside of a sub directory of $HOME.
    _assert_maybe_check_outside_root "$ws_out"

    # TODO: Project name conflict - derived from basename only, which may cause naming conflicts when different directories share the same final component.
    #
    # Set up compose directory and project name
    oc_project_name="$(_sanitize_name "$(basename "$ws_out")")"
    echo "Starting workspace: $ws_out"
    echo "Starting project: $oc_project_name"

    # Dispatch to the appropriate command handler
    case "$cmd" in
    down)
        global_skip_assert_worktree=1
        _opencode_ctx opencode:down "$ws_out" "$@"
        ;;
    start)
        _opencode_ctx opencode "$ws_out" "$@"
        ;;
    exec)
        global_skip_assert_worktree=1
        _opencode_ctx opencode:execute "$ws_out" "$@"
        ;;
    compose)
        global_skip_assert_worktree=1
        _opencode_ctx opencode:compose "$ws_out" "$@"
        ;;
    shell)
        global_skip_assert_worktree=1
        _opencode_ctx opencode:shell "$ws_out" "$@"
        ;;
    up)
        # Start containers without running processes
        global_skip_assert_worktree=1
        _opencode_ctx opencode:up "$ws_out" "$@"
        ;;
    uptree)
        opencode:uptree "$ws_out" "$uptree_branch" "$@"
        ;;
    scaffold)
        _opencode_ctx opencode:scaffold "$ws_out" "$@"
        ;;
    setup)
        # Run setup commands on an persisted instance
        global_skip_assert_worktree=1
        _opencode_ctx opencode:setup "$ws_out" "$@"
        ;;
    run)
        # Run tasks (e.g. 'npm install' or 'go build') in the opencode container
        _opencode_ctx opencode:run "$ws_out" "$@"
        ;;
    new)
        # Remove existing containers before starting a fresh instance
        global_skip_assert_worktree=1
        _opencode_ctx opencode:new "$ws_out" "$@"
        ;;
    changes)
        # Analyze branch changes for the workspace, optionally into writable outputs
        global_skip_assert_worktree=1
        _opencode_ctx opencode:changes "$ws_out" "$@"
        ;;
    bg)
        # Run a background, non-interactive opencode task against the workspace
        _opencode_ctx opencode:bg "$ws_out" "$@"
        ;;
    io)
        # Run a task on a read-only workspace with writable outputs (--output)
        _opencode_ctx opencode:io "$ws_out" "$@"
        ;;
    security)
        # FEATURE: analyze repository security - read code files for executable commands in normal usage, e.g. npm pre-install scripts or other potential risks
        echo "command not implemented"
        ;;
    clone)
        # FEATURE: retrieve a git repository and clone it into a location; clone --check runs security first, then acts, or checks if it already exists and acts
        echo "command not implemented"
        ;;
    repl)
        custom_repl "$ws_out"
        ;;
    help)
        if [[ -n "${1:-}" ]]; then
            _opencode_help_cmd "$1"
        else
            opencode:help
        fi
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        echo "Run '$0 help' for a list of commands and their usage." >&2
        return 1
        ;;
    esac
}

# Execute main with all provided arguments, but only when the launcher is run
# directly as a script: the interactive workspace shell ('repl') rcfile
# 'source's this file just to reuse the function definitions, where
# dispatching main() again would be wrong.
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
