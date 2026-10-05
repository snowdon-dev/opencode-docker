#!/usr/bin/env bash

# FEATURE: Config cp instructions, and init without active directory variables
# FEATURE: Control `--session` per workspace (blocked on opencode v1)
# FEATURE: Command that mounts the entire dir as readonly, and mounts a single
# file as writeable so you can plan and write to a file. then run on the plan.
# opencode:io --output /tmp/out.md < /tmp/create-task-plan.md
# FEATURE: Allow groups to pass a label and then filter for that label. So
# gists passed --group gists then at delete or stop, we can query for a --group
# gists
# FEATURE: Read launcher environment variables from a environment file that can
# be read even when not inside a OPENCODE_WORKSPACE, such that a zsh profile is
# not required.

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
# The worktree parent of a workspace, on the container (discovered with docker
# ps) and, under the same key, on the image and the network of a worktree (both
# discovered with `docker image ls` / `docker network ls`). The image and network
# labels outlive the container, so they are what relates a worktree's resources
# to its repository once the container is gone (see _ws_resource_ls).
LABEL_PARENT_OPENCODE="dev.snowdon.opencode.parent"
LABEL_WORKSPACE_PARENT_OPENCODE="dev.snowdon.opencode.workspace_parent"

LOOPBACK="127.0.0.1"

COMPOSE_NET_DIR="$SD_OPENCODE/compose/net"
COMPOSE_VOL_DIR="$SD_OPENCODE/compose/vol"
COMPOSE_SYS_DIR="$SD_OPENCODE/compose/sys"
COMPOSE_IMAGE_DIR="$SD_OPENCODE/compose/image"
COMPOSE_ENV_DIR="$SD_OPENCODE/compose/env"

TREE_ROOT="${SD_AGENT_TREE_ROOT:-$SD_REPO_HOME/agent-trees}"

# The root file used as the global root file, if it exists
ROOT_DOCKERFILE_PATH="$SD_OPENCODE/Dockerfile"

DOCKER_ARGS="${DOCKER_ARGS:-}"
SD_YOLO_HOME="${SD_YOLO_HOME:-false}"
SD_YOLO="${SD_YOLO:-false}"

OPENCODE_COMPOSE="${OPENCODE_COMPOSE:-}"
OPENCODE_CPUSET="${OPENCODE_CPUSET:-}"
OPENCODE_CPUS="${OPENCODE_CPUS:-}"

# By default .git directories are mounted read-only to protect them from
# modification inside the container. Set SD_READ_ONLY=false to disable this
# (see _opencode_args_prepare).
SD_READ_ONLY="${SD_READ_ONLY:-true}"
if [[ "$SD_READ_ONLY" != true ]]; then
    global_skip_assert_worktree=1
fi

# Stuff about the container environment

CONTAINER_WORKSPACE_ROOT="/workspace/project"
CONTAINER_USER="${OPENCODE_CONTAINER_USER:-other}"
CONTAINER_HOME="${OPENCODE_CONTAINER_HOME:-/home/${CONTAINER_USER}}"

# Published images are tagged <variant>-<version>: every variant exists once per
# opencode version layer (see opencode/Dockerfile.v1 and the v2 sibling), on top
# of shared toolchain bases. IMAGE_VERSION selects which of those layers the
# launcher pulls, for the workspace image and the throwaway tui service alike.
# It also selects the client configuration file the tui service mounts and the
# host-side start-tui helper, since the CLI surface differs per version (v2
# dropped `opencode attach` for `--server`).

image_url_set=false
[[ -n "${OPENCODE_IMAGE_URL:-}" ]] && image_url_set=true
IMAGE_VERSION="${OPENCODE_IMAGE_VERSION:-}"
IMAGE_COMPONENT=""
IMAGE_URL="${OPENCODE_IMAGE_URL:-devsnowdon/opencode-docker:duck-${IMAGE_VERSION:-v1}}"
OPENCODE_IMAGE_URL_TUI="${OPENCODE_IMAGE_URL_TUI:-devsnowdon/opencode-docker:empty-${IMAGE_VERSION:-v1}}"
export OPENCODE_IMAGE_URL_TUI


function parse_cache() {
    if [[ -n "${OPENCODE_CACHE:-}" ]]; then
        # Validate the request before anything is derived from it, so a typo
        # fails the same way whether or not OPENCODE_CACHE also selects the
        # image variant below. Classifying the request by scanning for known ids
        # instead would silently drop the unknown ones, upgrading a typo to a
        # larger cache set than asked for ("go bogus" -> the full toolchain).
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
            echo "Running container without toolchain cache"
        fi
        if [[ "$image_url_set" == false ]]; then
            # Set the toolchain based on the requested cache
            IMAGE_URL="devsnowdon/opencode-docker:"
            IMAGE_VERSION=v2
            if (( is_full )); then
                IMAGE_COMPONENT="full"
                OPENCODE_IMAGE_URL+="full-$IMAGE_VERSION"
                OPENCODE_CACHE="go rust python node"
            elif (( is_duck )); then
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
    # if it is set, the user has told us, just return
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
                empty|full|duck)
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

    # For custom image URLs not matching known prefixes, don't apply validation
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

# Per-version details of the opencode CLI, both selected from IMAGE_VERSION:
#   OPENCODE_CLIENT_CONFIG  client configuration file inside
#       ~/.config/opencode, mounted read-only into the tui service from the
#       repository copy (docker-compose.yml) so editing it takes effect without
#       an image rebuild. v1 layers a tui.json next to the shared config; v2 has
#       a single global cli.json.
#   OPENCODE_HEALTH_PATH    unauthenticated readiness endpoint the backend
#       health check and wait poll. v1 serves /api/health; v2 serves
#       /global/health. Probing it rather than the origin keeps the check
#       working when the backend runs with OPENCODE_SERVER_PASSWORD set.
# An unknown version keeps the v1 values rather than failing here: the image it
# selects does not exist either, and the launcher reports that itself.
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

# Range for managed docker networks: an explicit CIDR `("172.20.0.0/16")`, or a
# bare prefix whose mask is implied at 8 bits per octet `("172.20" -> /16)`.
NETWORK_RANGE="${OPENCODE_NET_RANGE:-172.20.0.0/16}"
# Mask of each network created inside the range (a /16 range slices into 256 /24s).
NET_SUBNET_MASK="${OPENCODE_NET_SUBNET:-29}"

# Container-side executables, installed in the image at /usr/local/bin (see
# opencode/Dockerfile.v1 and the v2 sibling). start-tui is the only one also run
# on the host, straight from the repository, like waitforserver above: it is
# version-specific, since the CLI entrypoint that connects to the backend moved
# from `opencode attach <url>` (v1) to `opencode --server <url>` (v2).

GIT_CHANGES_EXE="git-changes"
END_BACKEND_SERVE_EXE="end-serve-backend"
START_BACKEND_SERVE_EXE="start-serve-backend"
START_TUI_EXE="start-tui"
START_TUI_EXE_HOST="$SD_OPENCODE/scripts/$IMAGE_VERSION/start-tui.sh"
WAIT_FOR_SERVER_EXE="waitforserver"

# Host-side copy of the backend wait. The image has its own copy at
# /usr/local/bin/waitforserver (see dev/Dockerfile) for the in-container case,
# so the host runs the one in the repository ($SD_OPENCODE).
WAITFORSERVER="$SD_OPENCODE/scripts/waitforserver.sh"

THIS_OTHER_ERROR="Error: Combinding --other,-o and --this,-t is invalid and equivalent no not specifying either."


# Cleanup stuff
#
# Everything the EXIT trap can call is defined here, before the trap is armed
# and before anything that can exit early does: this script is sourced, so an
# exit part-way through it (an unknown cache id, no docker or podman on PATH)
# still runs the handlers registered below. A handler defined further down would
# not exist yet, and the run would end with "_cleanup: command not found" on top
# of the error that stopped it.

# clean up time main files with the docker compose merge
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

_cleanup_repl_rcfile=""

if command -v git > /dev/null 2>&1; then
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

# traps for proper cleanup and signal handling
trap _cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM



# Parsed NETWORK_RANGE: 32-bit network address and prefix length, set by _net_parse.
net_base=""
net_mask=""

# The project name used for the compose project
oc_project_name=""

# The arguemnts used when creating the compose project, creating a merged
# compose file
opencode_compose_args=""

# Resolved backend origin (http://host:port) used for the health check and the
# host-side TUI connection. Set once by opencode() after the container is up; the
# host port is random when docker-compose.yml publishes "0:4096".
backend_origin=""

# DRY_RUN=1 (set by the destructive commands' --dry-run flag) makes stop, delete
# and down report what they would do instead of doing it: the destructive
# driver primitives below print the would-be command and return success without
# touching a container, network, or image. Read-only discovery still runs, so a
# dry run reports the real hosts that would be affected.
dry_run=0

# Set when actions should not assert that the current workspace has a sync
# worktree. For example when operation that release the lock
global_skip_assert_worktree=0

network_name=""

# create global storage for process lifecycle, before it us used
# Create the gloabl storage with process lifecyle, only when used in
# compose related commands
tmp_sd_root_dir="$(mktemp -d)"
tmp_compose_dir="$tmp_sd_root_dir/compose"
tmp_compose_file=""
tmp_labels_file=""


# --- container driver init ---------------------------------------------------
# Container engine driver. Only 'docker' is implemented today; 'podman' is
# reserved for a future driver (the podman_<op> functions are stubs). 'auto'
# prefers docker, falling back to podman when docker is absent.
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

# allow passing arbitrary args to docker
function docker_exec() {
    local -a docker_args=()
    if [[ -n ${DOCKER_ARGS:-} ]]; then
        read -r -a docker_args <<<"$DOCKER_ARGS"
    fi
    docker "${docker_args[@]}" "$@"
}

# Dispatch an operation to the active driver's implementation:
#   _driver <op> [args...]  ->  runs ${DRIVER}_<op> <args...>
# Every operation is implemented as docker_<op> and (for future drivers)
# <driver>_<op>, so adding a driver only means adding those functions.
function _driver() {
    local op="$1"
    shift
    "${DRIVER}_${op}" "$@"
}

# Run a docker command through docker_exec unless DRY_RUN is active, in which
# case print the command and return success without executing it. Wraps only
# the destructive primitives (stop/kill/rm and image/network rm) so --dry-run
# leaves containers, images, and networks untouched while discovery still runs.
function _docker_run_destructive() {
    if ((dry_run)); then
        echo "DRY RUN: docker $*"
        return 0
    fi
    docker_exec "$@"
}

# --- docker driver -------------------------------------------------------
# Wraps docker_exec (which prepends DOCKER_ARGS) for every operation the
# launcher needs. The podman_<op> stubs below mark the future driver's shape.

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
function docker_network_create() {
    local name="$1" subnet="$2" workspace="$3" parent="${4:-}"
    local -a args=(
        network create
        --driver bridge
        --subnet="$subnet"
        --label="$LABEL_NETWORK_MANAGED=true"
        --label="$LABEL_NETWORK_WORKSPACE=$workspace"
    )
    # A network created by the launcher is external to compose, so compose
    # ignores the labels it declares for it: the worktree parent is recorded
    # here instead, matching the label the compose merge puts on a network
    # compose creates itself. Empty for a workspace that is not a worktree.
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
# Parse OPENCODE_NET_RANGE, either an explicit CIDR ("172.20.0.0/16") or a
# bare prefix ("172.20" whose mask is implied at 8 bits per octet), into the
# globals net_base (32-bit network address) and net_mask (prefix length).
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

    # A bare prefix has no "/mask" so infer 8 bits per given octet (172.20 -> /16)
    # capping at /24
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

    # A subnet mask smaller than the range mask allocates a subnet wider than
    # the containing range, which overlaps every slice of it; reject that.
    if ((NET_SUBNET_MASK < net_mask)); then
        echo "error: OPENCODE_NET_SUBNET (/$NET_SUBNET_MASK) must not be smaller than the network range mask (/$net_mask)" >&2
        return 1
    fi

    # Could replace this with a search for the chosen network to avoid
    # loading all networks into memory. For the first N search results, we
    # could inspect each one until we find a match. If no match is found,
    # fall back to loading all networks into memory. This is probably only
    # beneficial for small-to-medium numbers of networks; with a large
    # number, we'd likely need to load them all anyway.
    local -A used_networks
    local -a networks
    mapfile -t networks < <(_driver network_ls -q --filter "label=$LABEL_NETWORK_MANAGED=true")
    if ((${#networks[@]})); then
        while IFS= read -r subnet; do
            [[ -z "$subnet" ]] && continue
            used_networks["$subnet"]=1
        done < <(_driver network_subnets "${networks[@]}")
    fi

    # Slice the range into fixed-size subnets. When subnets are smaller than
    # the range the index selects the slice bits (e.g. a /16 range slices into
    # 256 x /24); an equal mask yields a single subnet (index 0).
    local count
    if ((NET_SUBNET_MASK > net_mask)); then
        ((count = 1 << (NET_SUBNET_MASK - net_mask)))
    else
        count=1
    fi

    # Randomize the search order so concurrent projects are less likely to
    # collide on the same subnet.  count is always a power of 2 (1 << free_bits),
    # so any odd step is coprime to it, guaranteeing every slot is visited exactly
    # once.  Combine two $RANDOM values (each 0-32767) for a wider range.
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

# Create a docker network for use within the compose file.
#
# The optional third argument is the worktree parent of the workspace, recorded
# as a label on the created network (see docker_network_create).
#
# FEATURE: create network as a compose network, not external
function _network_builder() {
    local available_subnet nid
    local proj="$1"
    local workspace="$2"
    local parent="${3:-}"

    # find existing network
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

    # create a new network
    network_name="sd-$proj-default"

    available_subnet="$(find_free_network)" || {
        echo "No free subnet available" >&2
        return 1
    }

    _driver network_create "$network_name" "$available_subnet" "$workspace" \
        "$parent" \
        >/dev/null 2>&1 || {
        # Failure: A project with name ($PROJECT_NAME) already existed and is active?
        echo "Network failed to create with name ($oc_project_name)"
        return 1
    }

    return 0
}

# print a message about the current git details of the cwd
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
    echo "git log --stat | head -50:"
    echo '```'
    git log --stat | cat | head -50 || true
    echo '```'
}

# print details about the readme file is one exists in cwd
function _print_readme() {
    if [[ ! -f ./README.md ]]; then
        return
    fi
    printf '\nREADME.md:\n'
    echo '```'
    cat README.md
    echo '```'
}

# print the CPU resources granted to the agent, reflecting only what is
# configured. OPENCODE_CPUS (a limit) takes precedence over OPENCODE_CPUSET
# (pinning) when both are set.
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



# FEATURE: Only sub directries of home was intended, but now is not
# asserted. As other roots require path == root.
function _check_valid_within_root() {
    local ws_out home ws_norm valid_subdir root
    ws_out="$1"
    home="$2"

    # The trailing-slash-stripped ws_out is written back through the nameref in
    # param three, so callers that approve it can remember the normalized dir.
    # The internal temp is deliberately NOT named ws_out_normalized: bash
    # resolves a nameref innermost-first, so a same-named local here would
    # swallow the writeback before it reaches the caller.
    local -n normalized_out="$3"

    # if param four is set, use it as storage of validation, otherwise discard
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
        # Any non-root absolute path is a subdirectory of "/".
        if [[ $ws_norm != "/" &&
            $ws_norm == /* ]]; then
            valid_subdir=1
        fi
    elif [[ $ws_norm == "$home" || $ws_norm == "$home"/* ]]; then
        # HOME itself and everything below it are valid roots.
        valid_subdir=1
    fi

    # A previously validated dir is also a home: anything at or below it
    # passes without prompting.
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
    # Previously approved dirs become additional home roots: a path at or
    # below one later passes without prompting again. This prevents repeated
    # checks for the same project (e.g. workspace and its worktree parent).
    # Remove trailing slashes, while preserving "/".
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
            # Remember the approved dir as a new home root for later checks.
            tmp_validated+="$ws_out_normalized"$'\n'
            ;;
        *)
            printf 'Aborted.\n' >&2
            exit 1
            ;;
        esac
    fi
}

# Print NUL-terminated every .git directory under <ws>, for read-only mounting.
# Vendor/build/test-artifact directories are pruned so throwaway nested repos
# (e.g. node_modules, tests/.tmp sandboxes) aren't mounted or counted, which
# keeps the compose config stable across command invocations.
# FEATURE: Read the exclude list from .gitignore?
function _find_workspace_git_dirs() {
    local ws="$1"
    find "$ws" \
        \( -name node_modules -o -name .cargo -o -name target -o \
        -name .tmp -o -name vendor \) -prune -o \
        -type d -name .git -print0
}

# Print the parent repository's git dir when <git_path> is a worktree .git file,
# or nothing when it is a regular git dir directory. A worktree's .git is a file
# whose first line is "gitdir: <path>", pointing into <parent>/.git/worktrees/
# <name>
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

# Print the ids of the images and networks belonging to the workspace <ws>: the
# ones labelled with the workspace itself, plus the ones labelled with it as their
# worktree parent - i.e. the resources of its git worktrees. Any extra arguments
# are extra docker filters every query carries, e.g. the managed label a network
# must have to be ours at all.
#
# Docker ANDs its --filter clauses, so a resource carrying both labels can only be
# found by querying one label at a time; the two queries are unioned here. The
# worktree-parent label is what makes `delete --this` followed by
# `delete --all --this` from a repository complete: the worktree's image and
# network are labelled with the repository as their parent (the launcher passes
# the build arg for the image, and labels the network it creates), and unlike the
# container's dev.snowdon.opencode.parent label those survive the container.
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

# Write a Docker Compose override mounting each entry of the array named by $1
# (elements are "source:/container/path" pairs) read-only onto the opencode
# service. tmp_compose_dir/tmp_compose_file are set so the EXIT trap's _cleanup
# removes the override afterwards.
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

# Write a Docker Compose override recording the worktree parent path in the
# labels of both resources the workspace owns. The file lives in the shared
# tmp_compose_dir and cleanup removes the whole dir; tmp_labels_file lets the
# caller merge it into the args.
#
#   * services.opencode.labels carries dev.snowdon.opencode.parent on the container
#     itself, which is what the container discovery selects on (`docker ps
#     --filter label=dev.snowdon.opencode.parent=<ws>` for the worktree-child
#     probe, list --parent and delete --other). It must stay: container queries
#     cannot see an image's or a network's labels, and docker does not inherit
#     labels from a container to its image or network.
#   * networks.extra-network.labels adds dev.snowdon.opencode.workspace_parent to
#     the labels already declared for the network in docker-compose.yml (and in
#     compose/net/docker-compose.network.yml), so the workspace's network is
#     identifiable as a worktree's from the network side too. Compose merges
#     `labels` key by key, so this adds to the managed/workspace labels instead
#     of replacing them, in either form of the network. The image carries the same
#     label from its own Dockerfile (see Dockerfile.example), which is what lets a
#     command scoped to the repository reach a worktree's resources after the
#     worktree's container is gone (see _ws_resource_ls).
#
#   networks:
#       extra-network:
#           labels:
#               dev.snowdon.opencode.workspace_parent: "<parent_wt>"
function _write_labels_override() {
    local parent_wt="$1"
    parent_wt="${parent_wt%/}"
    tmp_labels_file="$tmp_compose_dir/docker-compose.labels.yml"

    # Both label forms are double quoted, with their backslashes and quotes
    # escaped, so any path stays a YAML string: a bare "key=value" or
    # "key: value" scalar would break on a path containing ": ", "#" or a
    # leading indicator character. (A "$" is not escaped: compose has no escape
    # for it, see the volume mounts of _write_volume_overrides.)
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

# Resolve the effective workspace for the given path in place, using the same git
# worktree resolution _opencode_args_prepare applies:
#
#   * A worktree (its .git is a file) keeps the workspace itself; the parent
#     repo's git dir comes back in has_parent so containers get the
#     dev.snowdon.opencode.parent label.
#   * A parent repository with a single in-sync worktree child container resolves
#     to that child (has_parent then points back at the parent git dir), so
#     `opencode:up` etc. run in the worktree from the parent directory.
#   * A parent with no worktree children keeps the workspace itself.
#
# Sets ws_out (nameref) and has_parent (nameref) to the effective values and
# updates PROJECT_NAME. Commands that must know the current workspace without
# preparing compose args (e.g. delete --all --other) use this so they preserve
# the effective workspace rather than the raw $PWD.
#
# Exits on the same errors as the prepare path (multiple/un-synced worktree
# children), so the effective resolution is identical wherever it runs.
#
# If the current directory is a worktree, resolve and use its parent .git directory.
# For worktrees, add the following label:
# dev.snowdon.opencode.parent=/path/to/parent/repository
#
# When locating opencode workspace containers, also consider worktrees.
# If `opencode:shell` is invoked from a project worktree, open the
# corresponding worktree container rather than the parent repository
# container.
#
# Example:
# git worktree add ../repo-wt wt-branch
# opencode:up /path/to/repo-wt
#
# FEATURE: Support `--worktree <branch>` / `--wt <branch>` to create or reuse
#   a worktree at:
#   $HOME/.local/state/repo/<branch>
#
# NOTE: could search only up containers which would enable multiple active
#   worktrees - at least take precedent from up containers However, it would mean
#   that the behaviour is unpredictable
#
# NOTE: When both a child and a parent are up? If `up` is called from the
#   parent, the parent will open the child; if called from the child, it will
#   open the child.
function _resolve_effective_workspace() {
    local -n w="$1"
    local -n hp="$2"

    parent_workspace="$(_git_worktree_parent "$w/.git")"
    
    # TODO: When a path is given for a parent, but a existing child is already
    # up, it does not respect the path

    # If this repo has a parent git repo
    if [[ -n "$parent_workspace" ]]; then
        hp="$parent_workspace"
        return 0
    fi
    # Or there is no git at all
    if [[ "$has_git" == false ]]; then
        return 0
    fi

    # for parent, find worktree child and use its path as effective
    local -a children=()
    local children_output
    children_output=$(_select_managed_containers --stopped --parent "$w")
    if [[ -n "$children_output" ]]; then
        mapfile -t children <<< "$children_output"
    fi
    if ((${#children[@]} > 1)); then
        # TODO: if there are more than one, unless given via the path, we use 
        # the one at the SD_TREE_ROOT, this is the main one, if that does not
        # exist, then err
        echo "Incorrect (${children[*]}) number of children containers for this workspace."
        exit 1
    elif ((${#children[@]} == 0)); then
        return 0
    fi

    # lookup the info from the container
    local child_worktree="${children[0]}" eff_path eff_proj rec
    # this is the effective worktree, get the path info. _container_info
    # fields are id, status, workspace (eff_path), project (eff_proj), ...
    rec="$(_container_info "$child_worktree")" || {
        echo "Failed to inspect worktree container $child_worktree" >&2
        exit 1
    }
    IFS=$'\t' read -r _ _ eff_path eff_proj _ _ _ _ <<<"$rec"

    # assign to globals
    hp="$w"
    w="$eff_path"
    oc_project_name="$eff_proj"
}

# When operating from a parent repository, determine whether a child
# worktree is in sync with the current branch.
#
# A worktree is considered in sync when either:
# - its HEAD matches the current HEAD; or
# - its merge-base with the current branch is the current HEAD,
# indicating that the worktree branch contains the current branch
# plus additional commits.
function _aseert_sync_worktree() {
    local parent_workspace="$1"
    local eff_path="$2"

    if (( global_skip_assert_worktree )); then
        # in commands like upwork tree, they can be used without harming
        # anything. so just let it pass even if the worktree is out of sync
        return 0
    fi

    # Nothing to sync when the workspace is not a worktree child.
    if [[ -z "$parent_workspace" || "$has_git" == false ]] ; then
        return 0
    fi

    local parent_sha child_sha branch child_branch merge_base is_same_commit \
        is_parent_merge_base
    # Guard every git call so a failure (e.g. an unrelated/diverged
    # worktree branch, a detached HEAD, or an unborn branch) cannot abort
    # the launcher via set -e; the empty result falls through to the
    # "needs syncing" handling below.
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

    if (( only_in_parent > 0 )); then
        if (( only_in_child == 0 && child_is_clean == 1 )); then
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

function _assert_maybe_write_config_dirs() {
    local -a dirs=()

    # Ids are matched case-insensitively, like parse_cache and the cache
    # override-file loop in _opencode_args_prepare already do (OPENCODE_CACHE
    # accepts "PYTHON NODE" as readily as "python node"). Matching the raw
    # value instead checked nothing for an upper-case request, so the check
    # passed and docker was left to create the cache dirs itself (as root).
    local cache_lower="${OPENCODE_CACHE:-}"
    cache_lower="${cache_lower,,}"

    # "all" is the full toolchain, and parse_cache only rewrites it to the
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
            # It exists, but must be a directory.
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
        printf 'The following directories do not exist:\n'
        printf '  %s\n' "${missing[@]}"

        # Only ask when there is someone to answer. bash shows a read prompt
        # only on a terminal, so with stdin redirected (a script, CI, a cron
        # job) the read returned nothing and fell through to the decline
        # branch, reporting "No directories were created." without saying why.
        # Nothing is created either way on such a run: name the directories and
        # stop, so the failure points at the cause rather than at a question
        # nobody was there to answer.
        if [[ ! -t 0 ]]; then
            printf 'Not interactive: create them above and re-run.\n'
            exit 1
        fi

        read -r -p "Create these directories? [y/N] " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            for dir in "${missing[@]}"; do
                if ! mkdir -p -- "$dir"; then
                    printf 'Error: failed to create "%s".\n' "$dir" >&2
                    exit 1
                fi
            done
        else
            printf 'No directories were created.\n'
            exit 1
        fi
    fi
}

# Prepares the Docker Compose arguments. This function sets up the project
# configuration including network settings and git directory mounts.
#
# FEATURE: Transient volumes - add OPENCODE_DATA=false disables persisted volume
function _opencode_args_prepare() {
    local ws_out="$1"
    local has_parent="$2"
    local -n args_out="$3"

    # Build Docker Compose arguments starting with the main compose file
    # after resolving any worktree args
    args_out+=(
        -p "$oc_project_name"
        -f "$SD_OPENCODE/docker-compose.yml"
    )

    # volume overrides that will be mounted
    local -a volume_mounts=()

    # Create storage for compose files
    mkdir "$tmp_compose_dir"

    # children worktrees need labels, after the main compose name
    if [[ -n "$has_parent" ]]; then
        # for worktrees, include worktree parent label on the service and, merged
        # into the network labels of docker-compose.yml, on the network
        _write_labels_override "$has_parent"
        args_out+=(-f "$tmp_labels_file")
    fi

    # if the server is v2 we need a password
    if [[ "$IMAGE_VERSION" == v2 ]]; then
        args_out+=(-f "$COMPOSE_ENV_DIR/docker-compose.password.yml")
    fi

    # OPENCODE_CACHE=false disables the cache volumes, "all" adds all
    # "go python" adds go and python. Values are case-insensitive.
    # parse_cache has already rejected unknown ids for every command, so the
    # per-id loop only has to resolve the override files; its own case is the
    # backstop for a value assigned after the launcher was sourced (repl).
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

    # FEATURE: if not avaliable and it is not the known prefix, we can could
    # try to get the required information from docker image inspect of images
    # that implement the base feature requirements
    #
    # lets inject a skill for the tools available in the base
    if [[ -n "$IMAGE_COMPONENT" ]]; then
        local skill_file="available-$IMAGE_COMPONENT-tools.md"
        local skill_path="$SD_OPENCODE/opencode/skills/$skill_file"
        if [[ -f "$skill_path" ]]; then
            volume_mounts+=("$skill_path:$CONTAINER_HOME/.config/opencode/skills/$skill_file")
        fi
    fi

    # Check the directories exist on the host, ask the user if we should write
    # them
    _assert_maybe_write_config_dirs

    # Inject the image information into the compose
    if [[ -f "$OPENCODE_DOCKERFILE" ]]; then
        # if the project has a docker use that
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.build.yml")
    elif [[ -f "$ROOT_DOCKERFILE_PATH" ]]; then
        # else if the root has a dockerfile use that
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.build.yml")
    else
        # else we don't need to build an image, just mount existing
        args_out+=(-f "$COMPOSE_IMAGE_DIR/docker-compose.image.yml")
    fi

    # default to using compose default network but add labels to it, merge config
    # Add network configuration if OPENCODE_NETWORK environment or use custom default
    if [[ "${OPENCODE_NETWORK:-}" == "@default" ]]; then
        # default to using a custom workspace
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

    # mount any user defined compose files and merge them
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

    # By default .git directories are mounted read-only to protect them from
    # modification inside the container. Set SD_READ_ONLY=false to disable this
    # and mount the workspace without the read-only git override file.
    if [[ "${SD_READ_ONLY,,}" != "false" ]]; then
        local git_dir
        while IFS= read -r -d '' git_dir; do
            volume_mounts+=("$git_dir:$CONTAINER_WORKSPACE_ROOT/${git_dir#"$ws_out"/}")
            echo "read-only locking dir: $git_dir"
        done < <(_find_workspace_git_dirs "$ws_out")

        # A worktree's .git is a file whose gitdir pointer lives in the parent
        # repository. Mount the parent git dir read-only at its own host path
        # so the pointer resolves inside the container too. ALso protect the
        # pointer.
        if [[ -n "$has_parent" ]]; then
            _assert_maybe_check_outside_root "$has_parent"
            volume_mounts+=("$has_parent/.git:$has_parent/.git")
            volume_mounts+=("$ws_out/.git:$CONTAINER_WORKSPACE_ROOT/.git")
            echo "read-only locking worktree parent: $has_parent/.git"
        fi
    fi

    # mount the volumes from skills and git overrides
    if ((${#volume_mounts[@]} > 0)); then
        _write_volume_overrides volume_mounts
        args_out+=(-f "$tmp_compose_file")
    fi

    # Only non-empty values are added; empty values leave the corresponding
    # Compose setting at its default. Each option is its own static override
    # file, merged in only when set.
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

    # The backend is only published on a host port when a host-side opencode CLI
    # (used for the TUI) needs to reach it. When opencode is absent the
    # throwaway `tui` service connects over the compose network instead, so no
    # port is exposed on the host: one project's backend then cannot be reached
    # from another project's host processes when several containers run.
    if _opencode_on_host; then
        local port_file="$COMPOSE_SYS_DIR/docker-compose.port.yml"
        _assert_file_is_yml "$port_file" || exit 1
        args_out+=(-f "$port_file")
    fi

}

# Ensure the opencode container exists and is running.
# Assumes the caller is inside _opencode_ctx (cd'd into the workspace, WORKSPACE
# exported) and OPENCODE_ARGS is set. Shared precondition used by start and
# setup to avoid repeating the 'docker compose up' step.
#
# Never recreates an already-running container (--no-recreate), so inspection
# commands don't disturb an existing session. Only the explicit recreate
# commands (start/new) pass --recreate.
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

# Run a one-off task against the opencode service without disturbing any
# pre-existing persistent container.
#
#   * If the project's persistent container is already running, the task runs
#     inside it via `exec` and that container is left running untouched.
#   * Otherwise a fresh one-off container is used via `docker compose run --rm`,
#     which publishes none of the service's ports and is removed automatically
#     when it exits, so no container is left behind.
#
# The `interactive` flag controls TTY handling: pass 1 to stream output to the
# terminal (used by `changes`), or 0 for a fully non-interactive run whose
# output can be captured (used by `run`/`setup` and the changes analysis step).
#
# FEATURE: If there is a TUI connected to the backend (`opencode --server` on
# v2), then it is running, but it may be best to run a one off. If there are
# multiple concurrent runs, it may be best not to run them within the opencode
# service, since the on offs can claim their own CPUS allocation
function _opencode_dispatch() {
    local interactive="$1"
    shift

    local running
    running="$(_driver compose "${opencode_compose_args[@]}" ps -q opencode)"

    if [[ -n "$running" ]]; then
        # Use the already-running container. Without -T (interactive) output streams
        # straight to the terminal; with -T it can be captured by the caller.
        if ((interactive)); then
            _driver compose "${opencode_compose_args[@]}" exec -w "$CONTAINER_WORKSPACE_ROOT" opencode "$@"
        else
            _driver compose "${opencode_compose_args[@]}" exec -T -w "$CONTAINER_WORKSPACE_ROOT" opencode "$@"
        fi
    else
        # No running container: use a throwaway container that runs the task and
        # exits, publishing no ports.
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
    # not within this opencode project
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

    # Assert the starting or effective workspace is the profile workspace
    if [[ -z ${OPENCODE_WORKSPACE+x} ]]; then
        return 0
    fi

    # e.g when loading an child worktree from the parent
    if [[ "$starting_ws" != "$eff_ws" && # effective path has changed
          ( "$OPENCODE_WORKSPACE" == "$starting_ws" || # and one is equal to the ocws
            "$OPENCODE_WORKSPACE" == "$eff_ws" )
       ]]; then
       return 0
    fi

    # When going up on a worktree the starting is the same as the eff, as the
    # path is given. So, if the worktree has a parent, we check the parent
    # ALLOWING OPENCODE_WORKSPACE to be the parent, but we can't on the child
    # worktree without prompt. Check both, one must be a valid root
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
        # Must be in a opencode space that is not the current for example on a
        # gist in a opencode workspace
        local ws_out_normalized=""
        if ! _check_valid_within_root "$starting_ws" "$OPENCODE_WORKSPACE" ws_out_normalized; then
            return 1
        else
            return 0
        fi
    fi
}

# Run a command in the opencode project context.
# Centralises the setup shared by every command: prepares the Docker Compose
# args, cd's into the workspace, exports WORKSPACE, and exposes the compose
# args via the global OPENCODE_ARGS array. It then invokes the named function
# with only the remaining command arguments, so command bodies can use the
# inherited ws/proj, the OPENCODE_ARGS array, and $@ for trailing args.
function _opencode_ctx() {
    local fn="$1"
    oc_workspace="$2"
    shift 2

    # Prepare the compose args and OPENCODE_ARGS in the current shell so the
    # dispatched command and its helpers can use them, then run the command in a
    # subshell so its traps and cwd changes do not leak into the launcher.
    local has_parent=""
    local ws_out="$oc_workspace"
    _resolve_effective_workspace ws_out has_parent

    if ! _check_within_workspace "$oc_workspace" "$ws_out" "$has_parent"; then
        _assert_continue_outside_workspace "$oc_workspace"
    fi

    if (( ! global_skip_assert_worktree )); then
        _aseert_sync_worktree "$has_parent" "$ws_out" "$oc_workspace"
    fi

    local -a args=()
    _opencode_args_prepare "$ws_out" "$has_parent" args || return 1

    oc_workspace="$ws_out"

    opencode_compose_args=("${args[@]}")

    # Display configuration information
    echo "Using opencode workspace: $oc_workspace"
    echo "Compose project: $oc_project_name"

    (
        # traps inside subshell for proper cleanup and signal handling
        _cleanup_stack=()
        trap _cleanup_run EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        cd "$oc_workspace" || exit 1
        export WORKSPACE="$oc_workspace"
        # The image build arg behind the dev.snowdon.opencode.workspace_parent
        # label (PROJECT_WORKSPACE_PARENT in compose/image/docker-compose.build.yml,
        # consumed by the workspace Dockerfile): a worktree's image records its
        # repository, so 'delete --all' on the repository still reaches it after
        # the worktree's container is gone. Empty for a workspace with no parent.
        export WORKSPACE_PARENT="$has_parent"
        "$fn" "$@"
    )
}

# Resolve the host-side port that docker published for the opencode service's
# private port 4096. With a dynamic binding ("0:4096") the host port is chosen
# at container creation, so it must be queried back with
# `docker compose port opencode 4096` rather than assumed. The output is
# "0.0.0.0:PORT"; only the numeric PORT is emitted. Returns non-zero when the
# container is not running or the mapping is absent.
function _backend_host_port() {
    local published
    published="$(_driver compose "${opencode_compose_args[@]}" port opencode 4096 2>/dev/null)" || return 1
    published="${published##*:}"
    [[ "$published" =~ ^[0-9]+$ ]] && printf '%s\n' "$published"
}

# The backend's unauthenticated readiness endpoint for the selected opencode
# version (see the version table at the top of this file), built from the
# resolved backend_origin or the OPENCODE_BACKEND_ORIGIN override. backend_origin
# is already side-correct: a host-side TUI reaches the published host port
# (127.0.0.1:$resolved), while the in-container TUI reaches the service on its
# private port (opencode:4096). Empty when neither is set, which is how the
# callers report "no backend to probe".
function _backend_health_url() {
    local origin="${backend_origin:-${OPENCODE_BACKEND_ORIGIN:-}}"
    [[ -n "$origin" ]] || return 1
    printf '%s%s\n' "${origin%/}" "$OPENCODE_HEALTH_PATH"
}

function _backend_healthy() {
    local backend_health_url
    backend_health_url="http://127.0.0.1:4096" || return 1
    # In-container tui: no host port is published, so the host cannot curl
    # the backend (the compose service name resolves only inside the network).
    # Probe it from within the container instead.
    _driver compose "${opencode_compose_args[@]}" exec -T \
        opencode curl -fsS \
        --connect-timeout 0.2 \
        --max-time 0.5 \
        "$backend_health_url" >/dev/null 2>&1
}

# Block until the backend answers its health endpoint, polling inside a single
# waitforserver process instead of one health check (and so one `docker compose
# exec`) per attempt. Waits from the same side _backend_healthy probes: a host
# opencode CLI reaches the backend over the published host port, while the
# in-container tui reaches it over the compose network, which resolves only
# inside the container. The launcher resolves the version's health path and hands
# waitforserver the complete URL, so the script itself stays version-agnostic.
# Assumes BACKEND_ORIGIN is set. Returns non-zero when the backend never comes up.
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
# `--stopped` adds `-a` so stopped (still existing) containers are found; without
# it only running containers are listed. The optional positional workspace
# argument and `--parent <ws>` turn into docker label filters:
#     label=dev.snowdon.opencode.workspace=<ws>   (positional workspace)
#     label=dev.snowdon.opencode.parent=<ws>      (--parent, worktree child)
# Docker --filter clauses are AND-ed, so a positional workspace and a --parent
# argument are mutually exclusive selectors: using both always returns nothing
# because a container never carries both labels.
#
# Engine errors are not swallowed: stdout and stderr go to separate temp files so
# a failing `docker ps` still reports `warning: container discovery failed:
# <stderr>` while yielding whatever (possibly empty) ids did come through. Both
# temp files are removed on every path.
function _managed_container_ids() {
    local ws_filter="" parent_filter="" stopped=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
# Empty label columns are left blank; the trailing '.' sentinel keeps them from
# being dropped by the `read -a` split used by callers. Fields are separated with
# {{"\t"}} (a Go template string literal), not a raw \t: docker inspect does not
# interpolate \t escapes the way docker ps does.
#
# docker inspect is used rather than `docker ps --format` because .Config.Labels
# from inspect is always a map, while the .Labels from `ps --format` can surface
# as a slice (indexing a slice by string then fails) depending on the
# docker/compose build.
function _container_info_format() {
    printf '%s' \
        '{{.ID}}{{"\t"}}{{.State.Status}}{{"\t"}}{{index .Config.Labels "'"$LABEL_WORKSPACE_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_CONTAINER_PROJECT_NAME"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_ONE_OFF"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_TUI_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_PARENT_OPENCODE"'"}}{{"\t"}}.'
}

# Print one tab-separated record describing the given managed container id (see
# _container_info_format for the layout).
#
# Returns non-zero (printing nothing) for a non-existent/stale id.
function _container_info() {
    _driver container_inspect \
        --format "$(_container_info_format)" \
        "$1" 2>/dev/null
}

# Print one tab-separated record per managed container id, from a single
# `docker inspect` call covering all of them (docker inspect emits one formatted
# line per id) rather than one round-trip per container. A stale/missing id only
# writes an error to stderr, which is dropped here: it contributes no record,
# exactly as _container_info reports nothing for a stale id.
function _container_infos() {
    [[ $# -gt 0 ]] || return 0
    _driver container_inspect \
        --format "$(_container_info_format)" \
        "$@" 2>/dev/null || true
}

# Print the ids of the managed opencode containers selected by the flags, one per
# line (nothing when the selection is empty). This is the shared discovery policy
# behind list/stop/delete (and the worktree-child probe in
# _opencode_args_prepare).
#
# Selection runs in two steps:
#
#   1. _managed_container_ids narrows by docker label filters.
#
#   2. The discovered ids are inspected in a single `docker inspect` call (via
#      _container_infos, one record per line) when a policy needs per-container
#      labels:
#        * unless --all, throwaway `compose run` oneoffs are dropped while the
#          interactive TUI one-off is kept. A container is excluded only when it
#          is a oneoff (label com.docker.compose.oneoff, compared
#          case-insensitively because compose sets "True") that is not the tui
#          service (dev.snowdon.opencode.tui).
#        * --other <ws> drops containers belonging to <ws> (workspace label) and
#          containers launched from its worktrees (parent label). Docker filters
#          cannot express `label != x`, so this also needs the single inspect.
#
#   Flags:
#     -a, --all       Include oneoff (`compose run`) containers (skips the
#                     per-id oneoff filter).
#     --stopped       Also include stopped containers (`docker ps -a`). Used by
#                     list/delete so they can see containers that are not running.
#     --parent <ws>   Select containers labelled dev.snowdon.opencode.parent=<ws>
#                     (containers launched from git worktrees of <ws>).
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

    # Only a policy needing per-container labels (the oneoff filter or --other)
    # requires inspection; otherwise the discovered ids pass straight through
    # with no inspect round-trip at all.
    local output_ids rc
    output_ids=$(_managed_container_ids "${sel[@]}")
    rc=$?
    if (( rc != 0 )); then
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
    done <<< "$output_ids"
    ((${#ids[@]} == 0)) && return 0

    # Inspect every discovered id in a single `docker inspect` call (one record
    # per line) instead of one round-trip per container. Docker inspect emits
    # records in argument order, so the printed ids keep the discovery order. A
    # stale id contributes no record and is dropped.
    local output_infos infos_rc
    output_infos=$(_container_infos "${ids[@]}")
    infos_rc=$?
    if (( infos_rc != 0 )); then
        printf 'error: _container_infos failed (%d)\n' "$infos_rc" >&2
        return $infos_rc
    fi
    if [[ -z "$output_infos" ]]; then
        return 0
    fi
    local rec
    while read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS=$'\t' read -r id _ ws _ oneoff istui parent _ <<<"$rec"
        if [[ "$include_oneoff" -eq 0 ]] &&
            [[ "${oneoff,,}" == "true" ]] && [[ "${istui,,}" != "true" ]]; then
            continue
        fi
        if [[ -n "$other_ws" ]] &&
            [[ "$ws" == "$other_ws" || "$parent" == "$other_ws" ]]; then
            continue
        fi
        printf '%s\n' "$id"
    done <<< "$output_infos"
}

# Resolve the workspace a managed container was created for: read the
# dev.snowdon.opencode.workspace label (field 3 of _container_info). Returns
# empty for a non-existent/stale id or when the label is absent.
function _find_workspace() {
    local rec ws
    rec="$(_container_info "$1")" || rec=""
    IFS=$'\t' read -r _ _ ws _ _ _ _ _ <<<"$rec"
    printf '%s\n' "$ws"
}

# True when the opencode CLI is installed on the host: the TUI connects to the
# backend over the published host port, which is why the port override file is
# merged (see _opencode_args_prepare). False when the one-off `tui` service is
# used instead (opencode absent): the backend is reached over the compose
# network as http://opencode:4096 and no host port is published.
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
        # The backend is published on a random host port; BACKEND_ORIGIN is the
        # resolved `docker compose port opencode 4096` mapping (or a
        # OPENCODE_BACKEND_ORIGIN override). start-tui reads it from the
        # environment, like the in-container tui service does. Which script runs
        # is the version's own: `opencode attach <url>` on v1, `opencode --server
        # <url>` on v2.
        BACKEND_ORIGIN="$backend_origin" "$START_TUI_EXE_HOST" 1 "$@"
    else
        # Inside the compose network the service is reachable on its private port.
        # The tui service's entrypoint is `start-tui 0`, so only the user's own
        # arguments are appended here.
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

# Tear down an in-flight scaffold run: kill the compose client, force-remove the
# one-off container, and delete the temp output file. docker compose run -T
# cannot proxy Ctrl+C into the container (no TTY), and opencode run --auto
# ignores SIGINT, so removal must be a forced one. Runs via the existing
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
# one-off container, and delete the temp output file. Same as the scaffold
# teardown (see _cleanup_scaffold) but for the 'bg' command's container.
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

# Main function to start and run opencode in a Docker container
# This function creates and executes the opencode container with proper
# workspace configuration and environment isolation.
function opencode() {
    # Multiple workspaces run concurrently: each backend is published on its own
    # randomly assigned host port. When another managed opencode container is
    # already running for a different workspace, warn (do not abort) so the user
    # knows several backends are active.
    local running_id running_ws
    local other_running=0
    local container_id
    while read -r running_id; do
        [[ -z "$running_id" ]] && continue

        # Use docker inspect, not docker ps --format: .Config.Labels is always a
        # map, whereas .Labels from 'ps --format' can surface as a slice (indexing
        # a slice by string then fails), depending on the docker/compose build.
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

    # start the containers
    _opencode_ensure_up --recreate || {
        echo "Failed to start the opencode container" >&2
        exit 1
    }

    # ensure cleanup afterwards
    cleanup_add _cleanup_opencode_backend

    # Resolve the backend origin. OPENCODE_BACKEND_ORIGIN always overrides the
    # whole origin. Otherwise the backend is served on the container's private
    # port 4096; when a host-side opencode CLI connects, the port is published
    # on a random host port ("0:4096" via the port override) which is resolved
    # back from docker once. When opencode is absent (in-container tui) no host
    # port is exposed: the backend is reached over the compose network.
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

    # start or resuse and existing container for the workspace
    if ! _backend_healthy; then
        # Start the handler in the background
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

    # start a TUI against the backend and wait
    _run_opencode_tui_executable "$@"

    # Verify container status after execution
    container_id="$(_driver compose "${opencode_compose_args[@]}" ps -q -a opencode)"
    if [[ -z "$container_id" ]]; then
        echo "The container was removed: $container_id"
        exit 1
    else
        echo "The opencode process ended"
        echo "Cid: $container_id"
    fi
}

# Execute commands in an existing opencode container
# This function runs interactive commands within a running container
# without creating a new container instance.
function opencode:execute() {
    echo "Executing in opencode project: $oc_project_name ($oc_workspace)"

    # Ensure the container is running before executing commands
    #_opencode_ensure_up

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "exec"
        exit 1
    fi

    # Execute command interactively in the running container
    _driver compose "${opencode_compose_args[@]}" exec -it opencode "$@"
}

function opencode:shell() {
    opencode:execute sh "$@"
}

# Run a task (e.g. 'npm install' or 'go build') inside the opencode service.
# This is a non-interactive variant of opencode:execute, useful for one-off
# build/setup commands. If the project's persistent container is already
# running the task runs inside it (leaving it running); otherwise a throwaway
# `compose run` container runs the task and exits, publishing no ports.
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

# Run setup commands on an existing persisted opencode instance.
# This runs the given non-interactive commands (e.g. 'npm install' or
# 'go build') against the existing container when it is running, otherwise a
# throwaway `compose run` container, then returns to the user shell while
# leaving any pre-existing container running for later work.
function opencode:setup() {
    echo "Setting up opencode project: $oc_project_name ($oc_workspace)"

    _opencode_ensure_up || {
        echo "Failed to start the opencode container" >&2
        exit 1
    }

    opencode:list "$oc_workspace"

    if [ "$#" -gt 0 ]; then
        echo "Running command in the container"
        # and create the resources in that container
        _opencode_dispatch 0 "$@"
    fi
}

# Create the workspace image definition: an ocdocker folder holding a copy of
# the launcher's Dockerfile.example, plus the exports that point the compose
# build at it (see 'create --dockerfile' in the help).
function _create_workspace_docker_file() {
    # create a docker compose in the repo
    local workspace
    workspace="$(_opencode_current_workspace)"

    local ws_docker_folder="$workspace/ocdocker"

    if [[ -e "$ws_docker_folder" ]]; then
        echo "Docker folder already exists" >&2
        return 0
    fi

    mkdir "$ws_docker_folder"

    local dockerfile="$ws_docker_folder/Dockerfile.example"

    cp "$SD_OPENCODE/Dockerfile.example" "$dockerfile"

    echo "Add the following to your environment:"
    echo "export OPENCODE_DOCKERFILE=\"$dockerfile\""
    echo "export OPENCODE_CONTEXT=\"$workspace\""
}

# Create the agent worktree 'opencode:uptree' expects, i.e. the one
# _get_worktree_info names at $SD_AGENT_TREE_ROOT/<project>-dev.
#
#   _create_worktree [<branch>]
#
# The worktree is created from the current HEAD of the workspace with
# 'git worktree add -B <branch>', the same command 'uptree' prints when the
# worktree is missing; -B also moves a branch of that name that is left over
# from an earlier, already removed worktree (git refuses when it is checked out
# in another worktree). Like the --dockerfile action this is host side only: it
# runs git in the workspace and never calls docker. It is idempotent: an
# existing worktree of this repository is reported and left alone, so re-running
# never resets a branch or discards work in the worktree.
function _create_worktree() {
    local branch_arg="${1:-}"

    if [[ "$has_git" == false ]]; then
        echo "error: create --worktree requires git in PATH" >&2
        return 1
    fi

    local workspace
    workspace="$(_opencode_current_workspace)" || return 1

    # rev-parse covers both layouts: a repository (a .git directory) and a
    # worktree (a .git file pointing into the parent repository).
    if ! git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: create --worktree requires a git repository: $workspace" >&2
        return 1
    fi

    # create is dispatched before the workspace is resolved, so the project name
    # is derived here the way main() derives it.
    if [[ -z "$oc_project_name" ]]; then
        oc_project_name="$(_sanitize_name "$(basename "$workspace")")"
    fi

    local wstree_name="" wstree_root=""
    _get_worktree_info wstree_name wstree_root

    local branch="${branch_arg:-$wstree_name}"

    # The root is not created here: SD_AGENT_TREE_ROOT may be shared storage that
    # is mounted per host, so its absence is a configuration problem to report.
    if [[ ! -d "$TREE_ROOT" ]]; then
        echo "error: no directory at the worktree root: $TREE_ROOT" >&2
        return 1
    fi

    if [[ -e "$wstree_root" || -L "$wstree_root" ]]; then
        # Report an existing worktree of this repository, but never touch a path
        # that is something else: it is not ours to remove.
        if [[ -f "$wstree_root/.git" ]]; then
            local parent_workspace
            parent_workspace="$(_git_worktree_parent "$wstree_root/.git")"
            if [[ "$parent_workspace" == "$workspace" ]]; then
                echo "Worktree already exists: $wstree_root"
                # The branch argument is ignored here: name the branch in place so
                # it is clear why.
                local current_branch
                current_branch="$(git -C "$wstree_root" branch --show-current 2>/dev/null || true)"
                if [[ -n "$current_branch" && "$current_branch" != "$branch" ]]; then
                    echo "On branch '$current_branch', not the requested '$branch'"
                fi
                echo "git worktree remove \"$wstree_root\"   # to recreate it"
                return 0
            fi
        fi
        echo "error: path exists and is not a worktree of $workspace: $wstree_root" >&2
        return 1
    fi

    if ! git -C "$workspace" worktree add -B "$branch" "$wstree_root"; then
        echo "error: could not create the worktree: $wstree_root" >&2
        return 1
    fi

    echo "Created worktree '$branch': $wstree_root"
    echo "Start a container for it with:"
    echo "opencode:uptree \"$workspace\""
}

# Create the assets of a workspace on the host: a workspace image definition
# (--dockerfile) and/or the agent worktree (--worktree). Every action is
# requested by its own option, several can be combined in one invocation, and
# they run in the order given. There is no default action, so a bare 'create'
# reports the options rather than guessing.
function opencode:create() {
    if [ "$#" -lt 1 ]; then
        echo "error: create requires an action (--dockerfile, --worktree)" >&2
        _opencode_help_cmd "create" >&2
        exit 2
    fi

    local -a args=("$@")
    local i=0
    while (( i < ${#args[@]} )); do
        case "${args[i]}" in
        --dockerfile | --Dockerfile | -df)
            _create_workspace_docker_file || exit 1
            ;;
        --worktree | --wt | -w)
            # An optional branch name follows the action option.
            local branch=""
            if (( i + 1 < ${#args[@]} )) && [[ "${args[i + 1]}" != -* ]]; then
                branch="${args[i + 1]}"
                i=$(( i + 1 ))
            fi
            _create_worktree "$branch" || exit 1
            ;;
        *)
            printf 'error: unknown option: %s\n' "${args[i]}" >&2
            _opencode_help_cmd "create" >&2
            exit 2
            ;;
        esac
        i=$(( i + 1 ))
    done
}

# Execute arbitrary Docker Compose commands for the opencode project
# This function provides direct access to Docker Compose functionality
# for advanced container management operations.
function opencode:compose() {
    echo "Running Docker Compose for project: $oc_project_name ($oc_workspace)"

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "compose"
        exit 1
    fi

    # Pass all arguments directly to Docker Compose
    _driver compose "${opencode_compose_args[@]}" "$@"
}

# Update the opencode launcher installation.
# Unlike the other commands this is not tied to a workspace or compose project:
# it only refreshes the launcher repo and images inside $SD_OPENCODE.
function opencode:update() {
    echo "Updating opencode launcher: $SD_OPENCODE"

    read -r -p "Update will stop and delete all existing containers resources (excluding cache). Are you sure you want to continue? [y/N] " answer || true

    if [[ "${answer:-}" != "y" && "${answer:-}" != "Y" ]]; then
        echo "Update cancelled."
        exit 1
    fi

    echo "Do not start containers while an update is in-progress"

    # containers must not be started in while update happens, images must be rebuilt
    opencode:stop
    opencode:delete --all

    # Refresh the repository holding the launcher, compose file, and Dockerfile.
    git -C "$SD_OPENCODE" pull

    echo "Ok, if you really want to... you could start new containers, but the update has not yet completed."

    # this does not rebuild each workspace image
    (
        cd "$SD_OPENCODE" || exit 1

        trap 'kill 0; exit 130' INT
        trap 'kill 0; exit 143' TERM

        # Every variant the launcher can select, on the configured version layer
        # (see IMAGE_VERSION), so switching a workspace between them is a local
        # image lookup rather than a pull.
        for variant in empty duck full; do
            docker pull "devsnowdon/opencode-docker:$variant-$IMAGE_VERSION"
        done
    )
}

# Teardown the opencode project for the specified workspace.
# Removes the compose resources (containers, networks, volumes) with 'down',
# then stops any remaining managed containers (e.g. the TUI one-off) scoped to
# the workspace, while preserving the workspace configuration.
function opencode:down() {
    echo "Stopping opencode project: $oc_project_name ($oc_workspace)"

    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    # down can only remove the current workspace's project, so "--other" (act on
    # everything except the current workspace) has no coherent meaning here.
    if ((other)); then
        echo "error: --other,-o cannot be combined with down: it only removes the current workspace's project" >&2
        exit 2
    fi
    if ((this)); then
        echo "error: --this,-t cannot be combined with down: it only removes the current workspace's project" >&2
        exit 2
    fi

    # docker compose down does not remove one-off containers created via
    # 'compose run' (like the TUI). Stop any remaining managed containers
    # scoped to this workspace.
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

# Start the opencode container without running any processes in it.
# This is useful to keep the container alive in the background so it can be
# attached to later with 'opencode:execute' without the overhead of creating it.
function opencode:up() {
    echo "Starting opencode container: $oc_project_name ($oc_workspace)"

    _driver compose "${opencode_compose_args[@]}" up -d opencode "$@"

    opencode:list "$oc_workspace"
}

# Write the name and the path of the project's agent worktree through the two
# nameref parameters, i.e. the location 'opencode:uptree' starts a container for
# and 'opencode:create --worktree' creates it at:
#
#   _get_worktree_info <out_name> <out_root>
#
# The name carries a -dev suffix so it cannot collide with the project name: the
# compose project name is globally unique by container basename, so a container
# for the worktree must not be named after the parent repository.
function _get_worktree_info() {
    if [[ -z "$oc_project_name" ]]; then
        echo "Error: no project name" >&2
        exit 1
    fi
    local -n tmp_wstree_name="$1"
    local -n tmp_wstree_root="$2"
    tmp_wstree_name="$oc_project_name-dev"
    tmp_wstree_root="$TREE_ROOT/$tmp_wstree_name"
}

# Uptree command is like the up command, however uptree implies we are
# initialising a child worktree.
#
# FEATURE: This command explicitly refers to a worktree, such that we can infer
# that if a worktree is not found (one is not in the docker container
# database), then we should try using the default location. The same can be
# said for the git command, only that currently it does not explicialy refer to
# a worktree. So would it need a `launcher --worktree git. Then if resove
# effective path does not return a worktree, we can infer that the worktree is
# the default loaction. 
function opencode:uptree() {
    if [[ "$has_git" == false ]]; then
        echo "No git command in path. Git is required work worktrees"
    fi

    local start_ws
    # NOTE: should be an option -t, --target E.g. --target /some/path/to/repo
    # instead of relying on the strange main() path resolve logic
    start_ws="$1"
    shift

    # if path is a worktree git repo, just up it
    if [[ -f "$start_ws/.git" ]]; then
        _opencode_ctx opencode:up "$start_ws" "$@"
        return $?
    fi

    # create the worktree
    if [[ ! -d "$TREE_ROOT" ]]; then
        echo "No directory at the worktree root: $TREE_ROOT"
        return 1
    fi

    # does it have a worktree exiting non standard worktree
    local ws_out="$start_ws" has_parent=""
    _resolve_effective_workspace ws_out has_parent

    global_skip_assert_worktree=1

    if [[ "$start_ws" != "$ws_out" ]]; then
        # an effective worktree was found, PROJECT_NAME should be set
        # as to find a eff_wt it must be a parent
        _opencode_ctx opencode:up "$ws_out" "$@"
        exit $?
    fi

    # must be different from the project name, due to the globally unique
    # basename constraint
    local wstree_name="" wstree_root=""
    _get_worktree_info wstree_name wstree_root
    oc_project_name="$wstree_name" # set the global

    if [[ -d "$wstree_root" ]]; then
        local git_pointer="$wstree_root/.git"
        if [[ -f "$git_pointer" ]]; then
            local parent_workspace
            parent_workspace="$(_git_worktree_parent "$git_pointer")"
            if [[ "$parent_workspace" != "$start_ws" ]]; then
                echo "Error: Resolved workspace is not the current workspace"
                return 1
            fi
            # should be cheap because has parent is true, no docker commands?
            _opencode_ctx opencode:up "$wstree_root" "$@"
            exit $?
        else
            echo "Worktree is a directory, but has not been initialised"
            exit 1
        fi
    else
        echo "Worktree is not a directory, needs initialising"
        exit 1
    fi
}

# Create a new opencode project scaffold with git initialization
# This function sets up a new project workspace with proper configuration
# and launches the opencode runner to begin development.
#
# For example: /home/user/repos/gists/one and /home/user/repos/projects/one
# both become project name "one". A future improvement should use a sanitized
# version of the full relative path to ensure uniqueness while maintaining
# Docker Compose naming compatibility (lowercase, hyphens only).
#
# FEATURE: Implement custom agent and model configuration
# Allow users to specify custom agent definitions and model settings
# for scaffold operations via environment variables or configuration files.
function opencode:scaffold() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "scaffold"
        exit 1
    fi

    echo "Running on opencode project: $oc_project_name ($oc_workspace)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within the
    # container.
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

    # The one-off container runs as a background job of the host launcher (the
    # container itself still lives in the docker daemon). Its output is captured
    # to a temp file so it can be streamed to the terminal, and on Ctrl+C the
    # existing INT trap -> EXIT -> cleanup_add stack kills the compose client and
    # the container instead of docker's (absent, with -T) signal proxy.
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
# Like scaffold, but without the empty-directory requirement: the workspace may
# already contain code (that is usually the point). The task-information context
# is worded for an existing project, and the result streams to the terminal via
# the same background one-off container + Ctrl+C-safe teardown as scaffold.
function opencode:bg() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "bg"
        exit 1
    fi

    echo "Running background task on opencode project: $oc_project_name ($oc_workspace)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within the
    # container.
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

    # The one-off container runs as a background job of the host launcher (the
    # container itself still lives in the docker daemon). Its output is captured
    # to a temp file so it can be streamed to the terminal, and on Ctrl+C the
    # existing INT trap -> EXIT -> cleanup_add stack kills the compose client and
    # the container instead of docker's (absent, with -T) signal proxy.
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

# Stop existing opencode containers before starting a fresh session.
function opencode:new() {
    opencode:stop

    echo "Starting fresh opencode container for project: $oc_project_name"
    opencode "$@"
}

# Parse the option flags shared by the stop/delete/list/down command family
# into caller-supplied variables. All four flags are recognised everywhere so
# the commands behave consistently even if they only act on a subset of them.
#
#   _opencode_parse_flags <out_all> <out_other> <out_quiet> <out_dry_run> <out_args> [args...]
#
# Sets (by nameref):
#   out_all     1 when --all or -a was given, else 0.
#   out_other   1 when --other or -o was given, else 0.
#   out_quiet   1 when --quiet or -q was given, else 0.
#   out_dry_run 1 when --dry-run was given, else 0.
#   out_args    The remaining positional arguments, in their original order.
#
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
        if (( parsing_options )); then
            case "$arg" in
                --)
                    parsing_options=0
                    continue
                    ;;

                --all|--resources)
                    out_all=1
                    ;;

                --other|--others)
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
                            a|r) out_all=1        ;;
                            o)   out_other=1      ;;
                            q)   out_quiet=1      ;;
                            n)   out_dry_run=1    ;;
                            t)   out_this=1       ;;
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
# calling context, not the directory the command was invoked from. When running
# inside an opencode context/repl, WORKSPACE is already the resolved workspace;
# otherwise the directory this command was invoked from is resolved through the
# same git worktree logic as _opencode_args_prepare (a synced worktree child
# supersedes its parent), so --other preserves the container, image and network
# of the workspace the user is actually working in.
function _opencode_current_workspace() {
    if [[ -n "${oc_workspace:-}" ]]; then
        printf '%s\n' "$oc_workspace"
        return 0
    fi

    local ws has_parent="" rc
    ws="$(realpath "$PWD")"

    _resolve_effective_workspace ws has_parent
    local rc=$?

    if (( rc != 0 )); then
        return $rc
    fi

    printf '%s\n' "$ws"
}

# Stops the existing managed containers
# Pass --all to include oneoff (throwaway `compose run`) containers.
# An optional workspace argument scopes the stop to containers for that
# workspace; by default all workspaces are stopped.
function opencode:stop() {
    echo "Stopping existing opencode containers"

    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if (( other && this )); then
        echo "$THIS_OTHER_ERROR" >&2
        exit 1
    fi

    # First positional argument is the workspace to scope to; empty = all
    # workspaces. A container-id prefix (not an existing directory) is matched
    # against running containers directly.
    local ws_scope=""
    if (( this )); then
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
# through, and matching is whole-line, so no id is a substring of another.
# An empty selection prints nothing at all.
function _ws_except() {
    local -n items="$1"
    local -n drop="$2"
    # Nothing to print for an empty selection: printf of an empty expansion would
    # still emit a blank line, which the caller would read back as one empty id.
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

# Force-remove all managed opencode containers.
# Unlike 'stop' which gracefully stops containers, this immediately removes
# them using 'docker rm -f', which is useful when a container is stuck or
# when you need to fully clean up.
# Pass --all to include oneoff (throwaway `compose run`) containers, and to also
# remove the workspace images and networks.
# An optional workspace argument scopes the delete to containers for that
# workspace; by default all workspaces are removed.
#
# Resources (images, networks) are selected by the workspace they are labelled
# with (see _ws_resource_ls), which for a worktree is the worktree's own path,
# plus the worktree parent they carry: a command scoped to a repository therefore
# covers that repository's worktrees, so `delete --this` followed by
# `delete --all --this` from a repository still removes the worktree's image -
# by then the container that related the worktree to its repository is gone, but
# the image and the network still name it. `--other` preserves the same, the
# workspace in use and its worktrees.
#
# NOTE: delete [cid] then delete --all [cid] does not work
#
# FEATURE: If the workspace has a parent, its a worktree, status is not
# clean, warn?
function opencode:delete() {
    # also for stop, down
    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    local ws_label
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if (( other && this )); then
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

    # First positional argument is the workspace to scope to; empty = all
    # workspaces. A container-id prefix (not an existing directory) is matched
    # against containers directly.
    local ws_scope=""
    local cid_match=0
    if (( this )); then
        ws_scope="$(_opencode_current_workspace)"
    elif [[ -n "${args[0]:-}" ]]; then
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        else
            cid_match=1
        fi
    fi

    function _ws_remove() {
        local -n ids="$1"
        if (( ${#ids[@]} < 1 )); then
            return 0
        fi
        _driver container_rm -f "${ids[@]}"|| {
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
        # set for if --all is given it only acts on this container
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
        # A scoped delete covers the resources of the worktrees of the workspace
        # it is scoped to, which name it as their worktree parent, plus its own
        # resources (see _ws_resource_ls). An unscoped delete already reaches
        # everything, through the bare labels below.
        #
        # Preserve the resources of the workspace in use and its worktrees when
        # --other is set: other_ws is the effective workspace (worktree-resolved
        # via _opencode_current_workspace), collected with the worktrees naming
        # it as their parent, so a worktree is spared even when its container has
        # already been deleted and no longer resolves it.
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
# that workspace, including containers launched from its git worktrees (parent
# label match). stop/delete are NOT parent-scoped; they only act on an exact
# workspace match. Pass --quiet to print only the container ids (one per line),
# handy for scripting stop/delete.
#
# NOTE: Rich list info - Too heavy of an operation, scales bad, need a better
# way: have the running process write a mark under /tmp/sd-opencode so running
# instances can be tracked without probing.
function opencode:list() {
    local all=0 other=0 quiet=0 dry_run=0 this=0
    local args=()
    _opencode_parse_flags all other quiet dry_run this args "$@"

    if (( other && this )); then
        echo "$THIS_OTHER_ERROR" >&2
        exit 1
    fi

    # First positional argument is the workspace to scope to; empty = all
    # workspaces.
    local ws_scope=""
    if (( this )); then
        ws_scope="$(_opencode_current_workspace)"
    elif [[ -n "${args[0]:-}" ]]; then
        # Only resolve existing directories; a bogus path would otherwise abort
        # under `set -e` on realpath implementations that fail on missing paths.
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        fi
    fi

    local other_ws=""
    if (( other )); then
        other_ws="$(_opencode_current_workspace)"
    fi

    local find_args=(--stopped)
    [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
    ((all)) && find_args+=(--all)
    ((other)) && find_args+=(--other "$other_ws")

    # A workspace scope also lists containers launched from its git worktrees:
    # those carry dev.snowdon.opencode.parent=<ws_scope>, so query that label
    # too and merge. Docker --filter clauses are AND-ed and a container never
    # holds both labels, hence two separate lookups deduped by sort -u. --other
    # must also exclude such worktree children of the current workspace.
    local parent_args=(--stopped --parent "$ws_scope")
    ((all)) && parent_args+=(--all)
    ((other)) && parent_args+=(--other "$other_ws")

    # Discover the ids first, then inspect them all in a single `docker
    # inspect` call (one record per line) instead of one round-trip per
    # container. The ids come out of `sort -u` sorted; docker inspect preserves
    # no particular output order, so the records are sorted again to keep the
    # listing deterministic. See _container_infos for the docker inspect
    # rationale.
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
            IFS=$'\t' read -r -a fields <<<"$rec"
            printf '%s\n' "${fields[0]:0:12}"
        done
        return 0
    fi

    # Column header lengths seed the width tracking so the table stays aligned.
    local -a ids=() statuses=() workspaces=() projects=() modes=() fields=()
    local id status ws proj oneoff istui mode
    local dlen=12 slen=6 wlen=9 plen=7 mlen=4
    for rec in "${records[@]}"; do
        fields=()
        IFS=$'\t' read -r -a fields <<<"$rec"
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
            # STATUS mirrors the container's own docker State.Status: a running
            # main container reports "running", a stopped one its own state
            # (e.g. "exited"). Whether the opencode backend is actually serving
            # inside it is no longer probed — docker exec per container does
            # not scale. Distinguishing serving vs idle should come from a
            # marker the running process drops once that exists.
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

# Analyze the workspace branch changes with a non-interactive opencode run.
# Gathers the git changes inside the container (so paths are
# container-relative), then runs `opencode run --agent plan` so it analyses the
# code and proposes a plan without making any changes. Output streams to the
# user's terminal.
function opencode:changes() {
    # TODO: When effective workspace is not the cwd, this might not behave as
    # expected. For example, I might pull the changes into the parent repo, and
    # run changes on that. While having a worktree enabled. But in that case
    # does it use the worktree
    echo "Analyzing changes for project: $oc_project_name ($oc_workspace)"

    # Run the git analysis against the existing container when it is running,
    # otherwise a throwaway `compose run` container; either way the returned
    # paths (under /workspace/project) match what opencode sees. Capture the
    # output for feeding into opencode below.
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

    # Default task: analyse and propose a plan. Overridable by the user.
    local task="${1:-analyze the branch changes above and produce a detailed plan of action to address them.}"
    shift || true

    local prompt="<task-information>
Project: $oc_project_name
Working directory: $CONTAINER_WORKSPACE_ROOT
Branch changes:
\`\`\`
$changes
\`\`\`
</task-information>

Your task is as follows:

$task

"

    # background this and capture
    local cname="oc-changes-$$"
    local outfile status=0
    outfile="$(mktemp "${tmp_sd_root_dir}/opencode-changes.XXXXXX")" || return 1

    _cleanup_changes_name="$cname"
    _cleanup_changes_output="$outfile"
    _cleanup_changes_pid=""
    cleanup_add _cleanup_changes

    # Run a non-interactive opencode session using the built-in plan agent. The
    # plan agent restricts edit/bash to "ask", so it analyses the code and
    # proposes a plan without modifying the working tree. Output streams to the
    # terminal (interactive dispatch), reusing the running container when
    # present.
    printf '%s' "$prompt" | _opencode_dispatch 0 \
        opencode run --agent plan --auto "$@" >"$outfile" 2>&1 &
    _cleanup_changes_pid=$!

    ## Stream the captured output to the terminal
    tail -f "$outfile" &
    local _tail_pid=$!
    wait "$_cleanup_changes_pid" || status=$?
    kill "$_tail_pid" 2>/dev/null || true
    return "$status"
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
    if [[ -n "$_repl_run_path" &&  -f "$_repl_run_path" ]]; then
        rm -- "$_repl_run_path"
    fi
}


# Entry point for the bare-name aliases set up inside the interactive workspace
# shell (_opencode_dispatch_shims). Maps a typed command to the matching
# opencode:* function, forwarding any arguments, so calls like
#   run npm install        -> opencode:run npm install
#   exec git log --oneline -> opencode:exec git log --oneline
# work exactly like a normal function invocation.
function _opencode_shim() {
    local cmd="$1"
    shift

    # Bail out rather than let an unset/empty runs dir turn the template below
    # into "/<cmd>.XXXXX" (the filesystem root). Not fatal: this runs behind an
    # alias in the interactive shell, which has to survive a bad command.
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

# Define bare-name aliases (run, exec, up, ...) that forward to the opencode:*
# functions, now that the workspace shell is a real interactive bash. Only
# names that are not already on PATH are aliased so system commands (git, ls)
# keep their meaning; bash builtins (exec, help) are overridden because the
# opencode functions are the point of this shell. The aliases make the shell
# behave like the old REPL ('run npm install') while still allowing the full
# non-prefixed command line.
function _opencode_dispatch_shims() {
    local cmd kind
    for cmd in \
        start new up setup down delete list execute stop run shell scaffold bg git \
        changes compose update help; do
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

        # Read into a separately declared variable: 'local count=$(<...)' swallows
        # the read's status, so errexit cannot catch a missing file.ref and the
        # empty value is then counted as zero.
        local count
        count=$(<"$_oc_repl_ref_global")
        echo $((count + 1)) > "$_oc_repl_ref_global"
    ) 200>"$_oc_repl_lock_global"
}

_oc_repl_release() {
    (
        flock -x 200

        # Kept separate from the declaration for the same reason as in
        # _oc_repl_acquire: a failed read must abort rather than decrement an
        # empty value to -1, which never reaches 0 and so leaves the global
        # directory behind (and recreates the ref file the cleanup removes).
        local count
        count=$(<"$_oc_repl_ref_global")
        count=$((count - 1))
        echo "$count" > "$_oc_repl_ref_global"

        if (( count == 0 )) ; then
            rm -fr -- "$_repl_global_project_dir" "$_oc_repl_ref_global"

            # clean global dir if its empt
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

function _oc_repl_prompt() {
    local run_count
    run_count=$(find "$_oc_repl_parent_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)

    printf '%s' \
        '\[\e[38;5;46m\]⌂ '"$oc_project_name"'\[\e[38;5;39m\]   ⚡ \[\e[38;5;214m\]tasks: '"$run_count"'\[\e[0m\]\n\[\e[38;5;39m\]❯ \[\e[0m\]'
}

# Launch a real interactive bash shell bound to the workspaceEvery opencode
# command is available as the bare name -- with normal argument passing:
#
#   run npm install
#   execute git log --oneline
#   list --all
#
# Be careful to mix the commands with commands on the shell PATH. The shell's
# rcfile rebuilds the workspace context (WORKSPACE, PROJECT_NAME,
# OPENCODE_ARGS, cwd) once, sources the user's ~/.bashrc for a normal shell
# environment, and registers the bare-name aliases above. A single command
# still needs no context: compose args are prepared here exactly like the other
# commands, and the rcfile reuses them instead of recomputing per command.
#
# FEATURE: repl, instead of doing the source, we can instead modify the
# environment variables because we are sourcing the script. In the repl
# _last_workspace_session=ilwlfnwefn
# FEATURE: while a repl is open, should the opencode server stay open? At least
# if started once. Closing the server on exit
function custom_repl() {
    local ws="$1"
    shift || true

    # Prepare the compose args and OPENCODE_ARGS in the current shell so the
    # dispatched command and its helpers can use them, then run the command in a
    # subshell so its traps and cwd changes do not leak into the launcher.
    local has_parent=""
    local ws_out="$ws"
    _resolve_effective_workspace ws_out has_parent

    # first workspace, $second_workspace, $has_parent
    if ! _check_within_workspace "$ws" "$ws_out" "$has_parent"; then
        _assert_continue_outside_workspace "$ws"
    fi

    # main() sets PROJECT_NAME before dispatching, but keep this self-sufficient
    # so direct calls behave the same as the other commands.
    if [[ -z "$oc_project_name" ]]; then
        oc_project_name="$(basename "$ws")"
    fi


    local -a args=()
    _opencode_args_prepare "$ws_out" "$has_parent" args || return 1

    opencode_compose_args=("${args[@]}")
    ws="$ws_out"

    # Resolve the launcher's own path so the rcfile can 'source' it for the
    # opencode:* definitions. The entry-point guard at the bottom stops main()
    # from re-dispatching when that source runs.
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

    # The runs directory the interactive shell records live commands in, read by
    # _opencode_shim and _oc_repl_prompt. Assigned here as well as in the rcfile
    # below (the shell is a separate process and cannot inherit this), so it is
    # always a real path: left empty, the shim's mktemp template collapses to
    # "/<cmd>.XXXXX" and lands in the filesystem root.
    _oc_repl_parent_dir="$_repl_global_project_dir/runs"
    [[ ! -d "$_oc_repl_parent_dir" ]] && mkdir -p "$_oc_repl_parent_dir"
    [[ ! -e "$_oc_repl_ref_global" ]] && echo 0 > "$_oc_repl_ref_global"
    _oc_repl_acquire

    # Build the interactive shell's rcfile. Contrived values are embedded with
    # %q so paths/names with spaces survive re-parsing inside the shell.
    {
        printf '%s\n' '# Auto-generated interactive opencode workspace shell. Do not edit.'
        printf 'source %s\n' "$(printf '%q' "$launcher_path")"
        printf '%s\n' 'set +e +u'
        printf '%s\n' 'set +o pipefail'
        # Interactive signal handling: restore defaults so Ctrl+C interrupts the
        # running foreground job instead of exiting the shell.
        printf '%s\n' 'cleanup_add _cleanup'
        printf '%s\n' 'trap _cleanup_run EXIT'
        printf '%s\n' 'trap - INT TERM'
        printf 'oc_workspace=%s\n' "$(printf '%q' "$ws")"
        printf 'WORKSPACE=%s\n' "$(printf '%q' "$ws")"
        printf 'oc_project_name=%s\n' "$(printf '%q' "$oc_project_name")"
        printf '_oc_repl_parent_dir=%s\n' "$(printf '%q' "$_oc_repl_parent_dir")"
        printf '%s\n' 'export oc_workspace oc_project_name WORKSPACE'
        printf 'declare -a opencode_compose_args=(\n'
        local arg
        for arg in "${args[@]}"; do
            printf '  %s\n' "$(printf '%q' "$arg")"
        done
        printf '%s\n' ')'
        printf 'cd %s || { echo "workspace removed: %s" >&2; return 1; }\n' \
            "$(printf '%q' "$ws")" "$(printf '%q' "$ws")"
        # Deliberately do NOT re-source ~/.bashrc: the outer shell's environment
        # (PATH, exported variables) is inherited intact, which is the same
        # environment the launcher CLI runs with. Re-sourcing a bashrc that
        # replaces PATH (instead of appending) would drop docker from PATH, and
        # every opencode docker command would then fail.
        printf 'if ! command -v %s >/dev/null 2>&1; then\n' "$(printf '%q' "$DRIVER")"
        printf '  echo "warning: %s not on PATH - opencode docker commands will fail" >&2\n' "$(printf '%q' "$DRIVER")"
        printf '%s\n' 'fi'
        printf '%s\n' '_opencode_dispatch_shims'
        # Single quotes on purpose: this is a line of rcfile source that the
        # child shell expands when it reads the rcfile. Double quotes would run
        # _oc_repl_prompt here, at rcfile-generation time.
        # shellcheck disable=SC2016
        printf '%s\n' 'PS1=$(_oc_repl_prompt)'
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
        echo "uptree <workspace>"
        echo "  Start a container for an agent worktree, like 'up' does. The worktree is"
        echo "  expected at \$SD_AGENT_TREE_ROOT/<project>-dev (default root:"
        echo "  \$SD_REPO_HOME/agent-trees) and must already exist: when it does not, the"
        echo "  'git worktree add' line to run is printed instead, or create it with"
        echo "  'create --worktree'."
        echo "  Args:"
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
        echo "    (none)"
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
        echo "    <workspace>/ocdocker/Dockerfile.example and print the"
        echo "    OPENCODE_DOCKERFILE/OPENCODE_CONTEXT exports that point the"
        echo "    compose build at it. Edit the copy, add those exports to your"
        echo "    environment, and the next launch builds the workspace image on"
        echo "    the base image. It is a no-op when ocdocker already exists:"
        echo "    that directory is reported and left untouched, so re-running"
        echo "    never overwrites your Dockerfile."
        echo "  --worktree (--wt, -w) [branch]"
        echo "    Create the agent worktree 'uptree' expects, at"
        echo "    \$SD_AGENT_TREE_ROOT/<project>-dev (default root:"
        echo "    \$SD_REPO_HOME/agent-trees, which has to exist), on 'branch'"
        echo "    (default: <project>-dev). It is created from the current HEAD,"
        echo "    and an existing worktree of this repository is reported and left"
        echo "    alone. The command to start a container for it is printed."
        echo "  Both actions write only, on the host: nothing is started and"
        echo "  docker is never called. <workspace> is the effective workspace, as"
        echo "  for every other command, so from a parent repository with one"
        echo "  synced worktree child it is that child."
        echo "  Args:"
        echo "    --dockerfile, --Dockerfile, -df   Action: scaffold the workspace"
        echo "                                     image definition."
        echo "    --worktree, --wt, -w [branch]    Action: create the agent"
        echo "                                     worktree."
        echo "    [branch]                         The branch for --worktree."
        echo "                                     Optional, defaults to"
        echo "                                     <project>-dev."
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
        echo "changes [task...]"
        echo "  Analyse the workspace branch changes inside the container and run a"
        echo "  non-interactive 'opencode run --agent plan' session that proposes a plan"
        echo "  without modifying the working tree. Output streams to the terminal."
        echo "  Args:"
        echo "    task...   Override the analysis task prompt. Optional."
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
    printf '  %-11s %s\n' "changes" "Analyse the branch changes and propose a plan"
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
    echo "scaffolds <workspace>/ocdocker/Dockerfile.example and --worktree (-w)"
    echo "[branch] creates the agent worktree uptree expects."
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
# "$SD_REPO_HOME/<name>" (absolute) and pass through untouched. An empty <path>
# means $PWD. The resolved path is written back through the <out_ws> nameref
# (named ws_out_ so a same-named caller local cannot swallow it, see
# _check_valid_within_root). Returns non-zero on the error paths; callers exit 1.
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

# Main entry point for the opencode launcher script
# This function parses command-line arguments and dispatches to the
# appropriate handler function based on the specified command.
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

    # if arguemnt after cmd is --help or -h, redirect to help
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        _opencode_help_cmd "$cmd" || true
        exit 0
    fi

    # update etc does not operate on a workspace path or compose project: it
    # only refreshes the launcher repo and images, so handle it before any
    # workspace resolution.
    case "$cmd" in
    env)
        # Print what the launcher will read from this shell. Only exported
        # variables show: the launcher assigns its own defaults (SD_OPENCODE and
        # friends) without exporting them. A group with no match at all makes
        # grep exit non-zero, which set -e would turn into a launcher failure.
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

    local path_in="${1:-}"

    case "$cmd" in
    scaffold)
        # Target: a leading --path <name> (a project name under $SD_REPO_HOME),
        # else the leading positional resolved as a real path against the cwd,
        # else the current directory. Remaining positionals are the task and
        # opencode args. scaffold requires the target to be empty or not exist.
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
        # Same target resolution as scaffold: --path <name> under $SD_REPO_HOME,
        # else the leading positional as a real path, else the current directory.
        # Unlike scaffold, bg runs against an existing project: the target must
        # already be a directory, it is never created.
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

    # when argument one is a path starting with / or ./ capture it as the ws_out,
    # else we use the cwd.
    if [[ -z ${ws_out+x} ]]; then
        if [[ "$path_in" == ./* || "$path_in" == /* ]] && [[ -d $path_in ]]; then
            ws_out="$(realpath "$path_in")"
            shift
        else
            ws_out="$PWD"
        fi
    fi

    # NOTE: if the container is already started, no need to assert. However, I
    # don't want to call docker again to check
    #
    # Skip this check when SD_YOLO is set to "true" (case-insensitive).
    # Check if the workspace lies outside of a sub directory of $HOME.
    _assert_maybe_check_outside_root "$ws_out"

    # TODO: Project name conflict - is derived from basename only, which may cause naming
    # conflicts when different directories share the same final component.
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
        opencode:uptree "$ws_out" "$@"
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
        # Analyze branch changes for the workspace
        global_skip_assert_worktree=1
        _opencode_ctx opencode:changes "$ws_out" "$@"
        ;;
    bg)
        # Run a background, non-interactive opencode task against the workspace
        _opencode_ctx opencode:bg "$ws_out" "$@"
        ;;
    security)
        # FEATURE: Implement command to analyze repository security Should read code
        # files and check for executable commands in normal usage For example,
        # checking for npm pre-install scripts or other potential risks
        echo "command not implemented"
        ;;
    clone)
        # FEATURE: Implement commadn to retrieve a git repository and clone it into a
        # location clone --check runs security, then perform come action or check
        # if it already exists and preform some action
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


# Execute the main function with all provided arguments. Only when the launcher
# is run directly as a script: the interactive workspace shell ('repl')
# rcfile 'source's this file just to reuse the function definitions, so
# dispatching main() again there would be wrong.
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
