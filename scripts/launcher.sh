#!/usr/bin/env bash
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
LABEL_PARENT_OPENCODE="dev.snowdon.opencode.parent"

LOOPBACK="127.0.0.1"

COMPOSE_NET_DIR="$SD_OPENCODE/compose/net"
COMPOSE_VOL_DIR="$SD_OPENCODE/compose/vol"
COMPOSE_SYS_DIR="$SD_OPENCODE/compose/sys"

DOCKER_ARGS="${DOCKER_ARGS:-}"
SD_YOLO_HOME="${SD_YOLO_HOME:-false}"
SD_YOLO="${SD_YOLO:-false}"

# DRY_RUN=1 (set by the destructive commands' --dry-run flag) makes stop, delete
# and down report what they would do instead of doing it: the destructive
# driver primitives below print the would-be command and return success without
# touching a container, network, or image. Read-only discovery still runs, so a
# dry run reports the real hosts that would be affected.
DRY_RUN=0

OPENCODE_COMPOSE="${OPENCODE_COMPOSE:-}"
OPENCODE_CPUSET="${OPENCODE_CPUSET:-}"
OPENCODE_CPUS="${OPENCODE_CPUS:-}"

# By default .git directories are mounted read-only to protect them from
# modification inside the container. Set SD_READ_ONLY=false to disable this
# (see _opencode_args_prepare).
SD_READ_ONLY="${SD_READ_ONLY:-true}"

IMAGE_URL="${OPENCODE_IMAGE_URL:-devsnowdon/opencode-docker:latest}"

if [[ -f "${OPENCODE_DOCKERFILE:-}" ]] && [[ -z "${OPENCODE_CONTEXT:-}" ]]; then
    OPENCODE_CONTEXT="$(dirname "$OPENCODE_DOCKERFILE")"
    OPENCODE_DOCKERFILE="$(basename "$OPENCODE_DOCKERFILE")"
    export OPENCODE_CONTEXT OPENCODE_DOCKERFILE
fi
OPENCODE_DOCKERFILE="${OPENCODE_DOCKERFILE:-Dockerfile}"
OPENCODE_CONTEXT="${OPENCODE_CONTEXT:-.}"

# Range for managed docker networks: an explicit CIDR `("172.20.0.0/16")`, or a
# bare prefix whose mask is implied at 8 bits per octet `("172.20" -> /16)`.
NETWORK_RANGE="${OPENCODE_NET_RANGE:-172.20.0.0/16}"
# Mask of each network created inside the range (a /16 range slices into 256 /24s).
NET_SUBNET_MASK="${OPENCODE_NET_SUBNET:-29}"

# Parsed NETWORK_RANGE: 32-bit network address and prefix length, set by _net_parse.
net_base=""
net_mask=""

PROJECT_NAME=""
OPENCODE_ARGS=""

# Resolved backend origin (http://host:port) used for the health check and the
# host-side TUI attach. Set once by opencode() after the container is up; the
# host port is random when docker-compose.yml publishes "0:4096".
BACKEND_ORIGIN=""

tmp_compose_dir=""
tmp_compose_file=""
tmp_labels_file=""

network_name=""

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

# traps for proper cleanup and signal handling
trap _cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
docker_exec() {
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
_driver() {
    local op="$1"
    shift
    "${DRIVER}_${op}" "$@"
}

# Run a docker command through docker_exec unless DRY_RUN is active, in which
# case print the command and return success without executing it. Wraps only
# the destructive primitives (stop/kill/rm and image/network rm) so --dry-run
# leaves containers, images, and networks untouched while discovery still runs.
_docker_run_destructive() {
    if ((DRY_RUN)); then
        echo "DRY RUN: docker $*"
        return 0
    fi
    docker_exec "$@"
}

# --- docker driver -------------------------------------------------------
# Wraps docker_exec (which prepends DOCKER_ARGS) for every operation the
# launcher needs. The podman_<op> stubs below mark the future driver's shape.

docker_info() { docker_exec info; }
docker_compose() {
    local -a compose_args=()
    if [[ -n ${COMPOSE_ARGS:-} ]]; then
        read -r -a compose_args <<<"$COMPOSE_ARGS"
    fi
    docker_exec compose "${compose_args[@]}" "$@"
}
docker_network_ls() { docker_exec network ls "$@"; }
docker_network_subnets() {
    docker_exec network inspect "$@" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
}
docker_network_name() { docker_exec network inspect "$1" --format '{{.Name}}'; }
docker_network_create() {
    local name="$1" subnet="$2" workspace="$3"
    docker_exec network create \
        --driver bridge \
        --subnet="$subnet" \
        --label="$LABEL_NETWORK_MANAGED=true" \
        --label="$LABEL_NETWORK_WORKSPACE=$workspace" \
        "$name"
}
docker_network_rm() { _docker_run_destructive network rm "$@"; }
docker_container_ls() { docker_exec ps "$@"; }
docker_container_inspect() { docker_exec inspect "$@"; }
docker_container_rm() { _docker_run_destructive rm "$@"; }
docker_container_kill() { _docker_run_destructive kill "$@"; }
docker_container_stop() { _docker_run_destructive stop "$@"; }
docker_container_exec() { docker_exec exec "$@"; }
docker_image_ls() { docker_exec image ls "$@"; }
docker_image_rm() { _docker_run_destructive image rm "$@"; }
docker_image_inspect() { docker_exec image inspect "$@"; }

# --- podman driver (stubs: not implemented yet) --------------------------
_podman_stub() {
    echo "error: podman driver: '$1' not implemented yet" >&2
    return 1
}
podman_info() { _podman_stub info; }
podman_compose() { _podman_stub compose; }
podman_network_ls() { _podman_stub network_ls; }
podman_network_subnets() { _podman_stub network_subnets; }
podman_network_name() { _podman_stub network_name; }
podman_network_create() { _podman_stub network_create; }
podman_network_rm() { _podman_stub network_rm; }
podman_container_ls() { _podman_stub container_ls; }
podman_container_inspect() { _podman_stub container_inspect; }
podman_container_rm() { _podman_stub container_rm; }
podman_container_kill() { _podman_stub container_kill; }
podman_container_stop() { _podman_stub container_stop; }
podman_container_exec() { _podman_stub container_exec; }
podman_image_ls() { _podman_stub image_ls; }
podman_image_rm() { _podman_stub image_rm; }
podman_image_inspect() { _podman_stub image_inspect; }

# --- app code ----------------------------------------------------------------
# Parse OPENCODE_NET_RANGE, either an explicit CIDR ("172.20.0.0/16") or a
# bare prefix ("172.20" whose mask is implied at 8 bits per octet), into the
# globals net_base (32-bit network address) and net_mask (prefix length).
_net_parse() {
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

int_to_ip4() {
    local v="$(($1 & 0xFFFFFFFF))"
    printf '%d.%d.%d.%d' \
        $(((v >> 24) & 255)) \
        $(((v >> 16) & 255)) \
        $(((v >> 8) & 255)) \
        $((v & 255))
}

find_free_network() {
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

_network_builder() {
    local available_subnet nid
    local proj="$1"
    local workspace="$2"

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

    # FEATURE: create network as a compose network, not external
    _driver network_create "$network_name" "$available_subnet" "$workspace" \
        >/dev/null 2>&1 || {
        # Failure: A project with name ($PROJECT_NAME) already existed and is active?
        echo "Network failed to create with name ($PROJECT_NAME)"
        return 1
    }

    return 0
}

# clean up time main files with the docker compose merge
_cleanup() {
    if [[ -n "$tmp_compose_dir" && -d "$tmp_compose_dir" ]]; then
        rm -rf -- "$tmp_compose_dir"
    fi
}

# print a message about the current git details of the cwd
_print_git_context() {
    if ! command -v git &>/dev/null; then
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
_print_readme() {
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
_print_cpu_context() {
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

_assert_file_is_yml() {
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

_sanitize_name() {
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

_check_valid_within_root() {
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
    elif [[ $ws_norm == "$home"/* ]]; then
        # The "$home/*" pattern excludes "$home" itself.
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
_assert_maybe_check_outside_root() {
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
        # FEATURE: Allow multiple home directories
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
# TODO: Read the exclude list from .gitignore?
_find_workspace_git_dirs() {
    local ws="$1"
    find "$ws" \
        \( -name node_modules -o -name .cargo -o -name target -o \
        -name .tmp -o -name vendor \) -prune -o \
        -type d -name .git -print0
}

# Print the parent repository's git dir when <git_path> is a worktree .git file,
# or nothing when it is a regular git dir directory. A worktree's .git is a file
# whose first line is "gitdir: <path>", pointing into <parent>/.git/worktrees/
# <name>; stripping the worktrees/<name> suffix yields the parent's git dir.
_git_worktree_parent() {
    local git_path="$1"
    local gitdir parent
    [[ -f "$git_path" ]] || return 0
    gitdir="$(sed -n 's/^gitdir: //p' "$git_path")"
    [[ -n "$gitdir" ]] || return 0
    parent="${gitdir%/worktrees/*}"
    [[ -d "$parent" ]] || return 0
    printf '%s' "$parent"
}

# Write a Docker Compose override mounting each entry of the array named by $1
# (elements are "source:/container/path" pairs) read-only onto the opencode
# service. tmp_compose_dir/tmp_compose_file are set so the EXIT trap's _cleanup
# removes the override afterwards.
_write_git_override() {
    local -n mounts="$1"
    if [[ -z "$tmp_compose_dir" ]]; then
        tmp_compose_dir="$(mktemp -d)"
    fi
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

# Write a Docker Compose override labeling the opencode service with the worktree
# parent path. The file lives in the shared tmp_compose_dir and cleanup removes
# the whole dir; tmp_labels_file lets the caller merge it into the args.
_write_labels_override() {
    local parent_wt="$1"
    parent_wt="${parent_wt%/}"
    if [[ -z "$tmp_compose_dir" ]]; then
        tmp_compose_dir="$(mktemp -d)"
    fi
    tmp_labels_file="$tmp_compose_dir/docker-compose.labels.yml"
    {
        printf '%s\n' 'services:'
        printf '%s\n' '  opencode:'
        printf '%s\n' '    labels:'
        printf '      - %s=%s\n' "$LABEL_PARENT_OPENCODE" "$parent_wt"
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
# a worktree at:
# $HOME/.local/state/repo/<branch>
# NOTE: could search only up containers which would enable multiple active
# worktrees - at least take precedent from up containers However, it would mean
# that the behaviour is unpredictable
# NOTE: When both a child and a parent are up? If `up` is called from the
# parent, the parent will open the child; if called from the child, it will
# open the child.
_resolve_effective_workspace() {
    local -n w="$1"
    local -n hp="$2"

    local parent_workspace
    hp="$(_git_worktree_parent "$w/.git")"
    hp="${hp%/.git}"
    
    # TODO: When a path parent is given for a parent, but a existing child
    #   is already up, it does not respect the path

    if [[ -z "$hp" ]] && command -v git >/dev/null 2>&1; then
        # for parent, find worktree child and use its path as effective
        local -a children
        mapfile -t children < <(_select_managed_containers --stopped --parent "$w")
        if ((${#children[@]} > 1)); then
            echo "Incorrect (${children[*]}) number of children containers for this workspace."
            exit 1
        elif ((${#children[@]} > 0)); then
            local child_worktree="${children[0]}" eff_path eff_proj rec
            # this is the effective worktree, get the path info. _container_info
            # fields are id, status, workspace (eff_path), project (eff_proj), ...
            rec="$(_container_info "$child_worktree")" || {
                echo "Failed to inspect worktree container $child_worktree" >&2
                exit 1
            }
            IFS=$'\t' read -r _ _ eff_path eff_proj _ _ _ _ <<<"$rec"

            parent_workspace="$w"
    
            # assign to globals
            w="$eff_path"
            PROJECT_NAME="$eff_proj"
            hp="$parent_workspace"
        fi
    fi
}

# When operating from a parent repository, determine whether a child
# worktree is in sync with the current branch.
#
# A worktree is considered in sync when either:
# - its HEAD matches the current HEAD; or
# - its merge-base with the current branch is the current HEAD,
# indicating that the worktree branch contains the current branch
# plus additional commits.
#
_aseert_sync_worktree() {
    local parent_workspace="$1"
    local eff_path="$2"

    # Nothing to sync when the workspace is not a worktree child.
    if [[ -z "$parent_workspace" ]]; then
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

    is_clean=0
    if [[ -z "$(git -C "$eff_path" status --porcelain)" ]]; then
        is_clean=1
    fi

    # TODO and if parent is clean?
    if ((is_same_commit || is_parent_merge_base)); then
        return 0
    elif ((is_clean)); then
        # all changes must be commited, there is no child containers,
        # we can do what we want
        # but the branch is different, needs syncing - so what to do
        #echo "Reseting worktree branch to parent branch: $branch"

        # TODO: if parent is ahead, git -C "$eff_path" rebase $parent_branch

        #git -C "$eff_path" reset --hard "$branch"
        #git -C "$eff_path" clean -df
        #w="$eff_path"
        #PROJECT_NAME="$eff_proj"
        echo "Invalid worktree branch - needs syncing"
        exit 1
    else
        echo "The workspace already has changes that are not related to the current branch: $branch"
        exit 1
        # it has a mergebase that is not the head of parent either another
        # random branch, or something that was branches from a previous head
        # state - requires syncing
    fi
}

# Prepares the Docker Compose arguments. This function sets up the project
# configuration including network settings and git directory mounts.
_opencode_args_prepare() {
    local ws_out="$1"
    local has_parent="$2"
    local -n args_out="$3"

    local compose_dir="${SD_OPENCODE:-$HOME/opencode}"

    # Build Docker Compose arguments starting with the main compose file
    # after resolving any worktree args
    args_out+=(
        -p "$PROJECT_NAME"
        -f "$compose_dir/docker-compose.yml"
    )

    # children worktrees need labels, after the main compose name
    if [[ -n "$has_parent" ]]; then
        # for worktrees, include worktree parent label
        _write_labels_override "$has_parent"
        args_out+=(-f "$tmp_labels_file")
    fi

    # NOTE: Transient volumes - add OPENCODE_DATA=false disables persisted volume

    # OPENCODE_CACHE=false disables the cache volumes, "all" adds all
    # "go python" adds go and python. Values are case-insensitive.
    if [[ -n "${OPENCODE_CACHE:-}" ]]; then
        if [[ "${OPENCODE_CACHE,,}" == "all" ]]; then
            args_out+=(-f "$COMPOSE_VOL_DIR/docker-compose.cache.yml")
        elif [[ "${OPENCODE_CACHE,,}" == "false" ]]; then
            echo "Running container without toolchain cache"
        else
            for id in ${OPENCODE_CACHE,,}; do
                case "$id" in
                go | node | python | rust)
                    # TODO: Should alter the image URL if it is not set, if go
                    # or rust, use full, python or node use duck
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

    # default to using compose default network but add labels to it, merge config
    # Add network configuration if OPENCODE_NETWORK environment or use custom default
    if [[ "${OPENCODE_NETWORK:-}" == "@default" ]]; then
        # default to using a custom workspace
        local proj_name
        _network_builder "$PROJECT_NAME" "$ws_out" || {
            echo "Failed to create or find network for project: $PROJECT_NAME" >&2
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
    for file in $OPENCODE_COMPOSE; do
        if _assert_file_is_yml "$file"; then
            args_out+=(-f "$file")
        else
            exit 1
        fi
    done

    # By default .git directories are mounted read-only to protect them from
    # modification inside the container. Set SD_READ_ONLY=false to disable this
    # and mount the workspace without the read-only git override file.
    if [[ "${SD_READ_ONLY,,}" != "false" ]]; then
        # NOTE: all .git directories found within the workspace are mounted
        # read-only, plus the parent git dir when the workspace is a worktree. A
        # future improvement should consider whether to traverse up to the git root
        # directory or leave directories as-is for security isolation.
        local -a git_mounts=()
        local git_dir
        while IFS= read -r -d '' git_dir; do
            git_mounts+=("$git_dir:/workspace/${git_dir#"$ws_out"/}")
            echo "read-only locking dir: $git_dir"
        done < <(_find_workspace_git_dirs "$ws_out")

        # A worktree's .git is a file whose gitdir pointer lives in the parent
        # repository. Mount the parent git dir read-only at its own host path so
        # the pointer resolves inside the container too.
        if [[ -n "$has_parent" ]]; then
            _assert_maybe_check_outside_root "$has_parent"
            git_mounts+=("$has_parent/.git:$has_parent/.git")
            echo "read-only locking worktree parent: $has_parent/.git"
        fi

        if ((${#git_mounts[@]} > 0)); then
            _write_git_override git_mounts
            args_out+=(-f "$tmp_compose_file")
        fi
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
    # (used for the TUI attach) needs to reach it. When opencode is absent the
    # throwaway `tui` service attaches over the compose network instead, so no
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
_opencode_ensure_up() {
    local recreate=0
    if [[ "${1:-}" == "--recreate" ]]; then
        recreate=1
        shift
    fi

    if ((recreate)); then
        _driver compose "${OPENCODE_ARGS[@]}" up -d opencode
    else
        _driver compose "${OPENCODE_ARGS[@]}" up -d --no-recreate opencode
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
_opencode_dispatch() {
    local interactive="$1"
    shift

    local running
    running="$(_driver compose "${OPENCODE_ARGS[@]}" ps -q opencode)"
    # TODO: If there is a process opencode attach, then its running, but it may
    # be best to run a one off

    if [[ -n "$running" ]]; then
        # Use the already-running container. Without -T (interactive) output streams
        # straight to the terminal; with -T it can be captured by the caller.
        if ((interactive)); then
            _driver compose "${OPENCODE_ARGS[@]}" exec -w /workspace opencode "$@"
        else
            _driver compose "${OPENCODE_ARGS[@]}" exec -T -w /workspace opencode "$@"
        fi
    else
        # No running container: use a throwaway container that runs the task and
        # exits, publishing no ports.
        _driver compose "${OPENCODE_ARGS[@]}" \
            run --rm \
            -w /workspace \
            --entrypoint /bin/sh \
            opencode \
            -c 'exec "$@"' \
            sh \
            "$@"
    fi
}

_assert_continue_outside_workspace() {
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

_check_within_workspace() {
    local ws_out="$1"
    # Assert the effective workspace is the profile workspace
    if [[ -n ${OPENCODE_WORKSPACE+x} ]] && [[ "$OPENCODE_WORKSPACE" != "$ws_out" ]]; then
        # running in a opencode space that is not the current
        local ws_out_normalized=""
        if ! _check_valid_within_root "$ws_out" "$OPENCODE_WORKSPACE" ws_out_normalized; then
            return 1
        fi
    fi
    return 0
}

# Run a command in the opencode project context.
# Centralises the setup shared by every command: prepares the Docker Compose
# args, cd's into the workspace, exports WORKSPACE, and exposes the compose
# args via the global OPENCODE_ARGS array. It then invokes the named function
# with only the remaining command arguments, so command bodies can use the
# inherited ws/proj, the OPENCODE_ARGS array, and $@ for trailing args.
_opencode_ctx() {
    local fn="$1"
    WORKSPACE="$2"
    shift 2

    if ! _check_within_workspace "$WORKSPACE"; then
        _assert_continue_outside_workspace "$WORKSPACE"
    fi

    # Prepare the compose args and OPENCODE_ARGS in the current shell so the
    # dispatched command and its helpers can use them, then run the command in a
    # subshell so its traps and cwd changes do not leak into the launcher.
    local -a args=()

    local has_parent
    _resolve_effective_workspace ws_out has_parent
    _aseert_sync_worktree "$has_parent" "$ws_out"
    _opencode_args_prepare "$ws_out" "$has_parent" args || return 1

    WORKSPACE="$ws_out"

    cleanup_add _cleanup

    OPENCODE_ARGS=("${args[@]}")

    # Display configuration information
    echo "Using opencode workspace: $WORKSPACE"
    echo "Compose project: $PROJECT_NAME"

    (
        # traps inside subshell for proper cleanup and signal handling
        trap _cleanup_run EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        cd "$WORKSPACE" || exit 1
        export WORKSPACE
        "$fn" "$@"
    )
}

# Resolve the host-side port that docker published for the opencode service's
# private port 4096. With a dynamic binding ("0:4096") the host port is chosen
# at container creation, so it must be queried back with
# `docker compose port opencode 4096` rather than assumed. The output is
# "0.0.0.0:PORT"; only the numeric PORT is emitted. Returns non-zero when the
# container is not running or the mapping is absent.
_backend_host_port() {
    local published
    published="$(_driver compose "${OPENCODE_ARGS[@]}" port opencode 4096 2>/dev/null)" || return 1
    published="${published##*:}"
    [[ "$published" =~ ^[0-9]+$ ]] && printf '%s\n' "$published"
}

_backend_healthy() {
    local BACKEND_HEALTH_URL="${BACKEND_ORIGIN:-${OPENCODE_BACKEND_ORIGIN:-}}"
    [[ -n "$BACKEND_HEALTH_URL" ]] || return 1
    if _opencode_on_host; then
        curl -fsS \
            --connect-timeout 0.2 \
            --max-time 0.5 \
            "$BACKEND_HEALTH_URL" >/dev/null 2>&1
    else
        # In-container tui: no host port is published, so the host cannot curl
        # the backend (the compose service name resolves only inside the network).
        # Probe it from within the container instead.
        _driver compose "${OPENCODE_ARGS[@]}" exec -T \
            opencode curl -fsS \
            --connect-timeout 0.2 \
            --max-time 0.5 \
            "$BACKEND_HEALTH_URL" >/dev/null 2>&1
    fi
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
_managed_container_ids() {
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
    ps_err="$(mktemp "${TMPDIR:-/tmp}/oc-pserr.XXXXXX")" || return 1
    ids_file="$(mktemp "${TMPDIR:-/tmp}/oc-ps.XXXXXX")" || {
        rm -f -- "$ps_err"
        return 1
    }
    _driver container_ls -q $stopped \
        --filter "label=$LABEL_MANAGED_OPENCODE=true" \
        ${ws_filter:+--filter "label=$LABEL_WORKSPACE_OPENCODE=$ws_filter"} \
        ${parent_filter:+--filter "label=$LABEL_PARENT_OPENCODE=$parent_filter"} \
        >"$ids_file" 2>"$ps_err"
    ps_rc=$?
    if ((ps_rc != 0)) && [[ -s "$ps_err" ]]; then
        echo "warning: container discovery failed: $(<"$ps_err")" >&2
    fi
    rm -f -- "$ps_err"

    while read -r id; do
        printf '%s\n' "$id"
    done <"$ids_file"
    rm -f -- "$ids_file"
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
_container_info_format() {
    printf '%s' \
        '{{.ID}}{{"\t"}}{{.State.Status}}{{"\t"}}{{index .Config.Labels "'"$LABEL_WORKSPACE_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_CONTAINER_PROJECT_NAME"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_ONE_OFF"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_TUI_OPENCODE"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_PARENT_OPENCODE"'"}}{{"\t"}}.'
}

# Print one tab-separated record describing the given managed container id (see
# _container_info_format for the layout).
#
# Returns non-zero (printing nothing) for a non-existent/stale id.
_container_info() {
    _driver container_inspect \
        --format "$(_container_info_format)" \
        "$1" 2>/dev/null
}

# Print one tab-separated record per managed container id, from a single
# `docker inspect` call covering all of them (docker inspect emits one formatted
# line per id) rather than one round-trip per container. A stale/missing id only
# writes an error to stderr, which is dropped here: it contributes no record,
# exactly as _container_info reports nothing for a stale id.
_container_infos() {
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
_select_managed_containers() {
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
    local -a ids=()
    local id
    while read -r id; do
        [[ -z "$id" ]] && continue
        if [[ "$include_oneoff" -eq 0 || -n "$other_ws" ]]; then
            ids+=("$id")
        else
            printf '%s\n' "$id"
        fi
    done < <(_managed_container_ids "${sel[@]}")
    ((${#ids[@]} == 0)) && return 0

    # Inspect every discovered id in a single `docker inspect` call (one record
    # per line) instead of one round-trip per container. Docker inspect emits
    # records in argument order, so the printed ids keep the discovery order. A
    # stale id contributes no record and is dropped.
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
    done < <(_container_infos "${ids[@]}")
}

# Resolve the workspace a managed container was created for: read the
# dev.snowdon.opencode.workspace label (field 3 of _container_info). Returns
# empty for a non-existent/stale id or when the label is absent.
_find_workspace() {
    local rec ws
    rec="$(_container_info "$1")" || rec=""
    IFS=$'\t' read -r _ _ ws _ _ _ _ _ <<<"$rec"
    printf '%s\n' "$ws"
}

# True when the opencode CLI is installed on the host: the TUI attaches to the
# backend over the published host port, which is why the port override file is
# merged (see _opencode_args_prepare). False when the one-off `tui` service is
# used instead (opencode absent): the backend is reached over the compose
# network as http://opencode:4096 and no host port is published.
_opencode_on_host() {
    command which opencode >/dev/null 2>&1
}

_run_opencode_executable() {
    if _opencode_on_host; then
        echo "Using opencode tui $(command which opencode)"
        # The backend is published on a random host port; BACKEND_ORIGIN is the
        # resolved `docker compose port opencode 4096` mapping (or a
        # OPENCODE_BACKEND_ORIGIN override).
        command opencode attach "$BACKEND_ORIGIN" "$@"
    else
        # Inside the compose network the service is reachable on its private port.
        local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://opencode:4096}"
        _driver compose "${OPENCODE_ARGS[@]}" run \
            --rm --remove-orphans \
            tui \
            attach "$BACKEND_ORIGIN" \
            "$@"
    fi
}

_cleanup_opencode_backend() {
    _driver compose "${OPENCODE_ARGS[@]}" exec \
        opencode pkill -f 'opencode serve' || true
}

# Tear down an in-flight scaffold run: kill the compose client, force-remove the
# one-off container, and delete the temp output file. docker compose run -T
# cannot proxy Ctrl+C into the container (no TTY), and opencode run --auto
# ignores SIGINT, so removal must be a forced one. Runs via the existing
# INT/TERM/EXIT traps' cleanup stack; failures are surfaced, not swallowed.
_cleanup_scaffold() {
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

_cleanup_changes() {
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
_cleanup_bg() {
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

# Remove the interactive workspace shell's rcfile.
_cleanup_repl() {
    if [[ -n "$_cleanup_repl_rcfile" ]]; then
        rm -f -- "$_cleanup_repl_rcfile"
        _cleanup_repl_rcfile=""
    fi
}

# Main function to start and run opencode in a Docker container
# This function creates and executes the opencode container with proper
# workspace configuration and environment isolation.
opencode() {
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
        if [[ -n "$running_ws" && "$running_ws" != "$WORKSPACE" ]]; then
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
    # port 4096; when a host-side opencode CLI attaches, the port is published
    # on a random host port ("0:4096" via the port override) which is resolved
    # back from docker once. When opencode is absent (in-container tui) no host
    # port is exposed: the backend is reached over the compose network.
    if [[ -n "${OPENCODE_BACKEND_ORIGIN:-}" ]]; then
        BACKEND_ORIGIN="$OPENCODE_BACKEND_ORIGIN"
    elif _opencode_on_host; then
        local backend_port
        backend_port="$(_backend_host_port)" || {
            echo "Failed to resolve the published backend port" >&2
            echo "Run 'opencode:compose port opencode 4096' to inspect the mapping." >&2
            exit 1
        }
        BACKEND_ORIGIN="http://$LOOPBACK:$backend_port"
        echo "Backend: $BACKEND_ORIGIN"
    else
        BACKEND_ORIGIN="http://opencode:4096"
        echo "Backend: $BACKEND_ORIGIN"
    fi

    # start or resuse and existing container for the workspace
    if ! _backend_healthy; then
        # Start the handler in the background
        _driver compose "${OPENCODE_ARGS[@]}" exec \
            -d \
            -w /workspace \
            opencode opencode serve \
            --hostname 0.0.0.0 --port 4096

        echo "Waiting for the opencode backend to launch"
        # 40 secs
        for i in {1..200}; do
            if _backend_healthy; then
                break
            fi

            if [ "$i" -eq 200 ]; then
                printf '\nOpenCode server failed to start\n'
                echo 'It may be a delayed start'
                exit 1
            fi

            if ((i % 3 == 0)); then
                printf '.'
            fi

            sleep 0.2
        done
        printf "\n"
    fi

    echo "Backend ready. Attaching..."

    # attach a TUI and wait
    _run_opencode_executable "$@"

    # Verify container status after execution
    container_id="$(_driver compose "${OPENCODE_ARGS[@]}" ps -q -a opencode)"
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
opencode:execute() {
    echo "Executing in opencode project: $PROJECT_NAME ($WORKSPACE)"

    # Ensure the container is running before executing commands
    #_opencode_ensure_up

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "exec"
        exit 1
    fi

    # Execute command interactively in the running container
    _driver compose "${OPENCODE_ARGS[@]}" exec -it opencode "$@"
}

opencode:shell() {
    opencode:execute sh "$@"
}

# Run a task (e.g. 'npm install' or 'go build') inside the opencode service.
# This is a non-interactive variant of opencode:execute, useful for one-off
# build/setup commands. If the project's persistent container is already
# running the task runs inside it (leaving it running); otherwise a throwaway
# `compose run` container runs the task and exits, publishing no ports.
opencode:run() {
    echo "Running in opencode project: $PROJECT_NAME ($WORKSPACE)"

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
opencode:setup() {
    echo "Setting up opencode project: $PROJECT_NAME ($WORKSPACE)"

    _opencode_ensure_up || {
        echo "Failed to start the opencode container" >&2
        exit 1
    }

    opencode:list "$WORKSPACE"

    if [ "$#" -gt 0 ]; then
        echo "Running command in the container"
        # and create the resources in that container
        _opencode_dispatch 0 "$@"
    fi
}

# Execute arbitrary Docker Compose commands for the opencode project
# This function provides direct access to Docker Compose functionality
# for advanced container management operations.
opencode:compose() {
    echo "Running Docker Compose for project: $PROJECT_NAME ($WORKSPACE)"

    if [ "$#" == 0 ]; then
        echo "No arguments were provided."
        _opencode_help_cmd "compose"
        exit 1
    fi

    # Pass all arguments directly to Docker Compose
    _driver compose "${OPENCODE_ARGS[@]}" "$@"
}

# Update the opencode launcher installation.
# Unlike the other commands this is not tied to a workspace or compose project:
# it only refreshes the launcher repo and images inside $SD_OPENCODE.
opencode:update() {
    echo "Updating opencode launcher: $SD_OPENCODE"

    read -r -p "Update will stop and delete all existing containers resources (excluding cache). Are you sure you want to continue? [y/N] " answer || true

    if [[ "${answer:-}" != "y" && "${answer:-}" != "Y" ]]; then
        echo "Update cancelled."
        exit 1
    fi

    echo "Do not start containers while an update is in-progress"

    # containers must not be started in while update happens, images must be rebuilt
    opencode:stop
    # TODO: Image delete and rebuild only if container has an update
    opencode:delete --all

    # Refresh the repository holding the launcher, compose file, and Dockerfile.
    git -C "$SD_OPENCODE" pull

    echo "Ok, if you really want to... you could start new containers, but the update has not yet completed."

    # this does not rebuild each workspace image
    (
        cd "$SD_OPENCODE" || exit 1

        trap 'kill 0; exit 130' INT
        trap 'kill 0; exit 143' TERM

        # Pull the 'tui' service image (the only service with an explicit image:).
        _driver compose pull

        # Build the 'opencode' image, refreshing the base FROM image first.
        _driver compose build --pull
    )
}

# Teardown the opencode project for the specified workspace.
# Removes the compose resources (containers, networks, volumes) with 'down',
# then stops any remaining managed containers (e.g. the TUI one-off) scoped to
# the workspace, while preserving the workspace configuration.
opencode:down() {
    echo "Stopping opencode project: $PROJECT_NAME ($WORKSPACE)"

    local all=0 other=0 quiet=0 dry_run=0
    local args=()
    _opencode_parse_flags all other quiet dry_run args "$@"
    DRY_RUN=$dry_run

    # down can only remove the current workspace's project, so "--other" (act on
    # everything except the current workspace) has no coherent meaning here.
    if ((other)); then
        echo "error: --other cannot be combined with down: it only removes the current workspace's project" >&2
        exit 2
    fi

    # docker compose down does not remove one-off containers created via
    # 'compose run' (like the TUI). Stop any remaining managed containers
    # scoped to this workspace.
    local stop_args=("$WORKSPACE")
    ((DRY_RUN)) && stop_args+=(--dry-run)
    opencode:stop "${stop_args[@]}"

    # Stop and remove containers, networks, and volumes
    if ((DRY_RUN)); then
        echo "DRY RUN: docker compose ${OPENCODE_ARGS[*]} down"
    else
        _driver compose "${OPENCODE_ARGS[@]}" down
    fi
}

# Start the opencode container without running any processes in it.
# This is useful to keep the container alive in the background so it can be
# attached to later with 'opencode:execute' without the overhead of creating it.
opencode:up() {
    echo "Starting opencode container: $PROJECT_NAME ($WORKSPACE)"

    _driver compose "${OPENCODE_ARGS[@]}" up -d opencode "$@"

    opencode:list "$WORKSPACE"
}

# Create a new opencode project scaffold with git initialization
# This function sets up a new project workspace with proper configuration
# and launches the opencode runner to begin development.
#
# For example: /home/user/repos/gists/one and /home/user/repos/projects/one
# both become project name "one". A future improvement should use a sanitized
# version of the full relative path to ensure uniqueness while maintaining
# Docker Compose naming compatibility (lowercase, hyphens only).
opencode:scaffold() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "scaffold"
        exit 1
    fi

    echo "Running on opencode project: $PROJECT_NAME ($WORKSPACE)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within the
    # container.
    local tmp_context
    tmp_context="<task-information>
You are creating the inital project scaffold.
The inital project information is as follows.
$(_print_cpu_context)
/workspace is the project: $PROJECT_NAME 
Working directory: /workspace
Workspace contents of /workspace:
\`\`\`
$(ls -la "$WORKSPACE")
\`\`\`
$(_print_readme)
$(_print_git_context)
</task-information>

Your task is as follows:

"

    # FEATURE: Implement custom agent and model configuration
    # Allow users to specify custom agent definitions and model settings
    # for scaffold operations via environment variables or configuration files.

    # The one-off container runs as a background job of the host launcher (the
    # container itself still lives in the docker daemon). Its output is captured
    # to a temp file so it can be streamed to the terminal, and on Ctrl+C the
    # existing INT trap -> EXIT -> cleanup_add stack kills the compose client and
    # the container instead of docker's (absent, with -T) signal proxy.
    local cname="oc-scaffold-$$"
    local outfile status=0
    outfile="$(mktemp "${TMPDIR:-/tmp}/opencode-scaffold.XXXXXX")" || return 1

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
    } | _driver compose "${OPENCODE_ARGS[@]}" \
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
opencode:bg() {
    if (($# < 1)) && [[ -t 0 ]]; then
        echo "Error: no task provided" >&2
        _opencode_help_cmd "bg"
        exit 1
    fi

    echo "Running background task on opencode project: $PROJECT_NAME ($WORKSPACE)"

    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within the
    # container.
    local tmp_context
    tmp_context="<task-information>
You are running a task in the existing project.
$(_print_cpu_context)
/workspace is the project: $PROJECT_NAME
Working directory: /workspace
Workspace contents of /workspace:
\`\`\`
$(ls -la "$WORKSPACE")
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
    outfile="$(mktemp "${TMPDIR:-/tmp}/opencode-bg.XXXXXX")" || return 1

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
    } | _driver compose "${OPENCODE_ARGS[@]}" \
        run --rm -T --name "$cname" opencode 'exec opencode run "$@"' \
        opencode --auto "$@" >"$outfile" 2>&1 &
    _cleanup_bg_pid=$!

    # Stream the captured output to the terminal
    tail -f "$outfile" &
    local _tail_pid=$!
    wait "$_cleanup_bg_pid" || status=$?
    kill "$_tail_pid" 2>/dev/null || true

    return "$status"
}

# Stop existing opencode containers before starting a fresh session.
opencode:new() {
    opencode:stop

    echo "Starting fresh opencode container for project: $PROJECT_NAME"
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
_opencode_parse_flags() {
    local -n out_all="$1"
    local -n out_other="$2"
    local -n out_quiet="$3"
    local -n out_dry_run="$4"
    local -n out_args="$5"
    shift 5

    out_all=0
    out_other=0
    out_quiet=0
    out_dry_run=0
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

                --all|-a)
                    out_all=1
                    ;;

                --other|-o|--others)
                    out_other=1
                    ;;

                --quiet|-q)
                    out_quiet=1
                    ;;

                --dry-run)
                    out_dry_run=1
                    ;;

                --*)
                    printf 'error: unknown option: %s\n' "$arg" >&2
                    return 2
                    ;;

                -*)
                    printf 'error: unknown option: %s\n' "$arg" >&2
                    return 2
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
_opencode_current_workspace() {
    if [[ -n "${WORKSPACE:-}" ]]; then
        printf '%s\n' "$WORKSPACE"
        return 0
    fi

    local ws has_parent=""
    ws="$(realpath "$PWD")"
    _resolve_effective_workspace ws has_parent
    printf '%s\n' "$ws"
}

# Stops the existing managed containers
# Pass --all to include oneoff (throwaway `compose run`) containers.
# An optional workspace argument scopes the stop to containers for that
# workspace; by default all workspaces are stopped.
opencode:stop() {
    echo "Stopping existing opencode containers"

    local all=0 other=0 quiet=0 dry_run=0
    local args=()
    _opencode_parse_flags all other quiet dry_run args "$@"
    DRY_RUN=$dry_run

    # First positional argument is the workspace to scope to; empty = all
    # workspaces. A container-id prefix (not an existing directory) is matched
    # against running containers directly.
    local ws_scope=""
    if [[ -n "${args[0]:-}" ]]; then
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        else
            local cid="${args[0]}"
            local ids count
            ids="$(_driver container_ls -q --filter id="$cid")"
            count=$(printf '%s\n' "$ids" | grep -c .)
            if [ "$count" -ne 1 ]; then
                echo "Search term did not exist as a path"
                echo "Search found multiple containers with that conatiner id prefix"
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
        if [[ -n "$ws_label" && "$ws_label" != "${WORKSPACE:-}" ]]; then
            echo "Stopping managed container $id (workspace: $ws_label)"
        else
            echo "Stopping managed container $id"
        fi
        _driver container_stop "$id" || true
    done < <(_select_managed_containers "${find_args[@]}")
}

# Force-remove all managed opencode containers.
# Unlike 'stop' which gracefully stops containers, this immediately removes
# them using 'docker rm -f', which is useful when a container is stuck or
# when you need to fully clean up.
# Pass --all to include oneoff (throwaway `compose run`) containers.
# An optional workspace argument scopes the delete to containers for that
# workspace; by default all workspaces are removed.
# NOTE: delete [cid] then delete --all [cid] does not work
opencode:delete() {
    # also for stop, down
    local all=0 other=0 quiet=0 dry_run=0
    local args=()
    local ws_label
    _opencode_parse_flags all other quiet dry_run args "$@"
    DRY_RUN=$dry_run

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
    if [[ -n "${args[0]:-}" ]]; then
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        else
            cid_match=1
        fi
    fi

    function _ws_remove() {
        local id="$1"
        local ws_label="$2"
        if [[ -n "$ws_label" && "$ws_label" != "${WORKSPACE:-}" ]]; then
            echo "Force-removing managed container $id (workspace: $ws_label)"
        else
            echo "Force-removing managed container $id"
        fi
        _driver container_rm -f "$id" || {
            echo "failed to remove container ($id)"
        }
    }

    if ((cid_match)); then
        # finds any that match
        local cid="${args[0]}"
        local ids count
        ids="$(_driver container_ls -a -q --filter id="$cid")"
        count=$(printf '%s\n' "$ids" | grep -c .)
        if [ "$count" -ne 1 ]; then
            echo "Search term did not exist as a path"
            echo "Search found multiple containers with that conatiner id prefix"
            exit 1
        fi
        ws_label="$(_find_workspace "$ids")"
        _ws_remove "$ids" "$ws_label"
        
        # set for if --all is given it only acts on this container
        ws_scope="$ws_label"
    else
        [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
        local id
        while read -r id; do
            [[ -z "$id" ]] && continue
            ws_label="$(_find_workspace "$id")"
            _ws_remove "$id" "$ws_label"
        done < <(_select_managed_containers "${find_args[@]}" | sort -u)
    fi

    if [ "$all" -eq 1 ]; then
        # Exclude WORKSPACE managed contianer if --other is set; other_ws is the
        # effective workspace (worktree-resolved via _opencode_current_workspace),
        # so the images/networks of the workspace actually in use are preserved.
        local exclude_iid="" exclude_nid=""
        if ((other)); then
            local -a exclude
            # search images
            mapfile -t exclude < <(
                _driver image_ls -q --filter "label=$LABEL_IMAGE_WORKSPACE=$other_ws"
            )
            if ((${#exclude[@]} > 1)); then
                echo "Invalid number of images with the workspace ($other_ws)."
                echo "Aborting, due to invalid state..."
                exit 1
            elif ((${#exclude[@]} > 0)); then
                exclude_iid="${exclude[0]}"
            fi

            # search networks
            mapfile -t exclude < <(
                _driver network_ls -q --filter label=$LABEL_NETWORK_WORKSPACE="$other_ws"
            )
            if ((${#exclude[@]} > 1)); then
                echo "Invalid number of containers with the workspace ($other_ws)."
                echo "Aborting, due to invalid state..."
                exit 1
            elif ((${#exclude[@]} > 0)); then
                exclude_nid="${exclude[0]}"
            fi
        fi

        # remove the workspace image, not the base image
        local filter_images=(
            --filter "label=$LABEL_IMAGE_WORKSPACE"
        )
        # if a workspace search exists, only for that workspace
        if [[ -n "$ws_scope" ]]; then
            filter_images+=(--filter "label=$LABEL_IMAGE_WORKSPACE=$ws_scope")
        fi

        local -a images
        mapfile -t images < <(
            _driver image_ls -q "${filter_images[@]}" | grep -vFx "$exclude_iid"
        )
        if ((${#images[@]})); then
            _driver image_rm "${images[@]}"
        fi

        # remove the networks
        local filters_network=()
        filters_network=(
            --filter "label=$LABEL_NETWORK_MANAGED"
        )
        # if a workspace exist, only for that workspace
        if [[ -n "$ws_scope" ]]; then
            filters_network+=(--filter "label=$LABEL_NETWORK_WORKSPACE=$ws_scope")
        fi
        local -a networks
        mapfile -t networks < <(
            _driver network_ls -q "${filters_network[@]}" | grep -vFx "$exclude_nid"
        )

        if ((${#networks[@]})); then
            _driver network_rm "${networks[@]}"
        fi
    fi
}

# Print the managed opencode containers in a ps-style table.
# By default oneoff (throwaway `compose run`) containers are skipped; pass
# --all to include them. An optional workspace argument scopes the listing to
# containers labelled for that workspace, including containers launched from
# its git worktrees (parent label match). stop/delete are NOT parent-scoped;
# they only act on an exact workspace match. Pass --quiet to print only the
# container ids (one per line), handy for scripting stop/delete.
opencode:list() {
    local all=0 other=0 quiet=0 dry_run=0
    local args=()
    _opencode_parse_flags all other quiet dry_run args "$@"

    # First positional argument is the workspace to scope to; empty = all
    # workspaces.
    local ws_scope=""
    if [[ -n "${args[0]:-}" ]]; then
        # Only resolve existing directories; a bogus path would otherwise abort
        # under `set -e` on realpath implementations that fail on missing paths.
        if [[ -d "${args[0]}" ]]; then
            ws_scope="$(realpath "${args[0]}")"
        fi
    fi

    local find_args=(--stopped)
    [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
    ((all)) && find_args+=(--all)
    ((other)) && find_args+=(--other "$(_opencode_current_workspace)")

    # A workspace scope also lists containers launched from its git worktrees:
    # those carry dev.snowdon.opencode.parent=<ws_scope>, so query that label too
    # and merge. Docker --filter clauses are AND-ed and a container never holds
    # both labels, hence two separate lookups deduped by sort -u. --other must
    # also exclude such worktree children of the current workspace.
    local parent_args=(--stopped --parent "$ws_scope")
    ((all)) && parent_args+=(--all)
    ((other)) && parent_args+=(--other "$(_opencode_current_workspace)")

    # Discover the ids first, then inspect them all in a single `docker inspect`
    # call (one record per line) instead of one round-trip per container. The
    # ids come out of `sort -u` sorted; docker inspect preserves no particular
    # output order, so the records are sorted again to keep the listing
    # deterministic. See _container_infos for the docker inspect rationale.
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
            # inside it is no longer probed — docker exec per container does not
            # scale. Distinguishing serving vs idle should come from a marker
            # the running process drops once that exists.
            # NOTE: Rich list info - Too heavy of an operation, scales bad,
            # need a better way: have the running process write a mark under
            # /tmp/sd-opencode so running instances can be tracked without
            # probing.
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
# Gathers the git changes inside the container (so paths are container-relative),
# then runs `opencode run --agent plan` so it analyses the code and proposes a
# plan without making any changes. Output streams to the user's terminal.
opencode:changes() {
    # TODO: When effective workspace is not the cwd, this might not behave as
    # expected.
    echo "Analyzing changes for project: $PROJECT_NAME ($WORKSPACE)"

    # Run the git analysis against the existing container when it is running,
    # otherwise a throwaway `compose run` container; either way the returned
    # paths (under /workspace) match what opencode sees. Capture the output for
    # feeding into opencode below.
    local changes
    # TODO: Explain the refs used in the diff (from upstream to HEAD etc)
    # shellcheck disable=SC2016
    changes="$(_opencode_dispatch 0 \
        sh -c '
        upstream=$(git rev-parse --abbrev-ref @{upstream} 2>/dev/null || true)
        echo "Branch: $(git branch --show-current 2>/dev/null || echo detached)"

        if [ -n "$upstream" ]; then
            # Count added lines across the complete change set
            added=$(git diff "$upstream"...HEAD --numstat | awk "{sum += \$1} END {print sum+0}")
            working_added=$(git diff --numstat | awk "{sum += \$1} END {print sum+0}")
            staged_added=$(git diff --cached --numstat | awk "{sum += \$1} END {print sum+0}")

            total_added=$((added + working_added + staged_added))
            if [ "$total_added" -gt 500 ]; then
                git diff --stat "$upstream"...HEAD
                git diff --stat --cached
                git diff --stat
            else
                # Show all changes: committed + staged + unstaged
                git diff "$upstream"...HEAD
                git diff --cached
                git diff
            fi
        else
            added=$(git diff --numstat | awk "{sum += \$1} END {print sum+0}")
            staged_added=$(git diff --cached --numstat | awk "{sum += \$1} END {print sum+0}")

            total_added=$((added + staged_added))
            if [ "$total_added" -gt 500 ]; then
                git diff --stat --cached
                git diff --stat
            else
                git diff --cached
                git diff
            fi
        fi

        echo "Untracked files:"
        git ls-files --others --exclude-standard
    ')" || {
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
Project: $PROJECT_NAME
Working directory: /workspace
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
    outfile="$(mktemp "${TMPDIR:-/tmp}/opencode-changes.XXXXXX")" || return 1

    _cleanup_changes_name="$cname"
    _cleanup_changes_output="$outfile"
    _cleanup_changes_pid=""
    cleanup_add _cleanup_changes

    # Run a non-interactive opencode session using the built-in plan agent. The
    # plan agent restricts edit/bash to "ask", so it analyses the code and
    # proposes a plan without modifying the working tree. Output streams to the
    # terminal (interactive dispatch), reusing the running container when present.
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

opencode:git() {
    local ws
    ws="$(_opencode_current_workspace)"

    if ((!($# > 0))); then
        echo "Git requires args"
        git --help
    fi

    git -C "$ws" "$@"
}

# Entry point for the bare-name aliases set up inside the interactive workspace
# shell (_opencode_dispatch_shims). Maps a typed command to the matching
# opencode:* function, forwarding any arguments, so calls like
#   run npm install        -> opencode:run npm install
#   exec git log --oneline -> opencode:exec git log --oneline
# work exactly like a normal function invocation.
_opencode_shim() {
    local cmd="$1"
    shift
    # Run in a subshell so a command's own 'exit' (e.g. opencode's failure
    # paths) cannot terminate the interactive workspace shell itself.
    case "$cmd" in
    # 'start' is served by the main opencode() function, not opencode:start.
    start) (opencode "$@") ;;
    *) (opencode:"$cmd" "$@") ;;
    esac
}

# Define bare-name aliases (run, exec, up, ...) that forward to the opencode:*
# functions, now that the workspace shell is a real interactive bash. Only
# names that are not already on PATH are aliased so system commands (git, ls)
# keep their meaning; bash builtins (exec, help) are overridden because the
# opencode functions are the point of this shell. The aliases make the shell
# behave like the old REPL ('run npm install') while still allowing the full
# non-prefixed command line.
_opencode_dispatch_shims() {
    local cmd kind
    for cmd in \
        start new up setup down delete list execute stop run shell scaffold bg \
        changes compose update help; do
        kind="$(type -t "$cmd" 2>/dev/null || true)"
        if [[ -z "$kind" || "$kind" == "builtin" ]]; then
            BASH_ALIASES["$cmd"]="_opencode_shim $cmd"
        fi
    done
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
custom_repl() {
    local ws="$1"
    shift || true
    if ! _check_within_workspace "$ws"; then
        _assert_continue_outside_workspace "$ws"
    fi

    # main() sets PROJECT_NAME before dispatching, but keep this self-sufficient
    # so direct calls behave the same as the other commands.
    if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$(basename "$ws")"
    fi

    local -a args=()
    local has_parent
    _resolve_effective_workspace ws has_parent
    _opencode_args_prepare "$ws" "$has_parent" args || return 1
    cleanup_add _cleanup

    OPENCODE_ARGS=("${args[@]}")

    # Resolve the launcher's own path so the rcfile can 'source' it for the
    # opencode:* definitions. The entry-point guard at the bottom stops main()
    # from re-dispatching when that source runs.
    local launcher_path
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        launcher_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    else
        launcher_path="$0"
    fi

    # FEATURE: Should this call the uptree command before entering the repl.
    # brining the projects container up first

    # Build the interactive shell's rcfile. Contrived values are embedded with
    # %q so paths/names with spaces survive re-parsing inside the shell.
    _cleanup_repl_rcfile="$(mktemp "${TMPDIR:-/tmp}/opencode-repl.XXXXXX")" || return 1
    cleanup_add _cleanup_repl
    {
        printf '%s\n' '# Auto-generated interactive opencode workspace shell. Do not edit.'
        printf 'source %s\n' "$(printf '%q' "$launcher_path")"
        printf '%s\n' 'set +e +u'
        printf '%s\n' 'set +o pipefail'
        # Interactive signal handling: restore defaults so Ctrl+C interrupts the
        # running foreground job instead of exiting the shell.
        printf '%s\n' 'trap - EXIT INT TERM'
        printf 'WORKSPACE=%s\n' "$(printf '%q' "$ws")"
        printf 'PROJECT_NAME=%s\n' "$(printf '%q' "$PROJECT_NAME")"
        printf '%s\n' 'export WORKSPACE PROJECT_NAME'
        printf 'declare -a OPENCODE_ARGS=(\n'
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
        printf 'PS1=%s\n' "$(printf '%q' "$PROJECT_NAME> ")"
        printf '%s\n' 'unset -f _opencode_dispatch_shims 2>/dev/null || true'
        #printf '%s\n' 'unset PATH'
        #printf 'alias docker="%s"\n' "$(which docker)"
        #printf 'alias sort="%s"\n' "$(which sort)"
        #printf 'alias mktemp="%s"\n' "$(which mktemp)"
        #printf 'alias rm="%s"\n' "$(which rm)"
    } >"$_cleanup_repl_rcfile"

    echo "                               .___                     .___           "
    echo "  ______ ____   ______  _  ____| _/____   ____        __| _/_______  __"
    echo " /  ___//    \ /  _ \ \/ \/ / __ |/  _ \ /    \      / __ |/ __ \  \/ /"
    echo " \___ \|   |  (  <_> )     / /_/ (  <_> )   |  \    / /_/ \  ___/\   / "
    echo "/____  >___|  /\____/ \/\_/\____ |\____/|___|  / /\ \____ |\___  >\_/  "
    echo "     \/     \/                  \/           \/  \/      \/    \/      "
    echo
    echo "Interactive opencode shell for $ws (project: $PROJECT_NAME)"
    echo "  type 'run <cmd>', 'exec <cmd>', 'opencode:list --all', or 'help'"
    echo "  type 'exit' to leave the shell"
    echo "  repl is in development, so be careful."

    bash --rcfile "$_cleanup_repl_rcfile" -i
    return $?
}

# Print detailed help for a single command.
# Usage: _opencode_help_cmd <name>
# Falls back to a generic message if no help exists for the command.
_opencode_help_cmd() {
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
        echo "    --all, -a   Also remove oneoff (throwaway 'compose run') containers."
        echo "    --other, -o Force-remove everything except the current workspace; its"
        echo "                containers, images, and networks are preserved."
        echo "    --dry-run   Print what would be removed (containers, images, networks)"
        echo "                without doing it."
        echo "    [project]   The path to the project to scope the delete to."
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
        echo "    --all, -a   Also stop oneoff (throwaway 'compose run') containers."
        echo "    --other, -o Stop every managed container except the current workspace's"
        echo "                (and its worktrees)."
        echo "    --dry-run   Print what would be stopped without doing it."
        echo "    [project]   The path to the project to scope the stop to."
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
        echo "  convenience alias for 'exec sh'. Creates the container first if needed."
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
        echo "  Run a one-off, non-interactive opencode task against an existing project"
        echo "  (). With --path the target lives under SD_REPO_HOME; otherwise the"
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
        echo "  Refresh the opencode launcher installation: git pull the repository,"
        echo "  pull the 'tui' image, and rebuild the local 'opencode' image with"
        echo "  --pull so its base image is refreshed. Not tied to a workspace."
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
opencode:help() {
    echo "opencode launcher - manage the opencode container and sessions"
    echo
    echo "Usage: $0 <command> [workspace] [args...]"
    echo
    echo "Commands:"
    printf '  %-11s %s\n' "start" "Create the container and run an interactive opencode session"
    printf '  %-11s %s\n' "new" "Stop existing containers and start a fresh session"
    printf '  %-11s %s\n' "up" "Start the container in the background without running a process"
    printf '  %-11s %s\n' "setup" "Run setup commands against the persisted instance"
    printf '  %-11s %s\n' "down" "Remove the project's containers, networks, volumes, and TUI"
    printf '  %-11s %s\n' "delete" "Force-remove all managed opencode container resources across workspaces (--all for oneoffs, --other to spare the current workspace)"
    printf '  %-11s %s\n' "ls|list" "List managed opencode containers in a ps-style table (--all for oneoffs)"
    printf '  %-11s %s\n' "exec" "Run a command interactively inside the running container"
    printf '  %-11s %s\n' "git" "Run a git command in the workspace on the host"
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
    printf '  %-11s %s\n' "update" "Refresh the launcher repo and rebuild its images"
    printf '  %-11s %s\n' "help" "Show help; 'help <command>' for command details"
    echo
    echo "The workspace defaults to the current directory, and SD_OPENCODE points to"
    echo "the compose directory (default: \$HOME/opencode)."
    echo
    echo "stop, delete, and ls accept --all (-a) to include throwaway one-off"
    echo "'compose run' containers, and --other (-o) to act on everything except the"
    echo "current workspace. delete --other also preserves the current workspace's"
    echo "images and networks."
    echo
    echo "stop, delete, and down accept --dry-run to print what would be done"
    echo "without touching any container, image, or network."
    echo
    echo "Launcher behaviour is configured by OPENCODE_* and SD_* environment"
    echo "variables (build context, caches, networks, CPU limits, the"
    echo "OPENCODE_WORKSPACE guard, ...); see the project README for details."
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

    if command -v git >/dev/null; then
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
_resolve_project_path() {
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
main() {
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

    # Just exit if there is no docker
    if ! _driver info >/dev/null 2>&1; then
        echo "Docker daemon is not running" >&2
        echo "Try something like: sudo systemctl start docker"
        exit 1
    fi

    # update etc does not operate on a workspace or compose project: it only
    # refreshes the launcher repo and images, so handle it before any workspace
    # resolution.
    case "$cmd" in
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
    git)
        opencode:git "$@"
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
    PROJECT_NAME="$(_sanitize_name "$(basename "$ws_out")")"
    echo "Starting workspace: $ws_out"
    echo "Starting project: $PROJECT_NAME"

    # Dispatch to the appropriate command handler
    case "$cmd" in
    down)
        _opencode_ctx opencode:down "$ws_out" "$@"
        ;;
    start)
        _opencode_ctx opencode "$ws_out" "$@"
        ;;
    exec)
        _opencode_ctx opencode:execute "$ws_out" "$@"
        ;;
    compose)
        _opencode_ctx opencode:compose "$ws_out" "$@"
        ;;
    shell)
        _opencode_ctx opencode:shell "$ws_out" "$@"
        ;;
    up)
        # Start containers without running processes
        _opencode_ctx opencode:up "$ws_out" "$@"
        ;;
    uptree)
        # TODO: docker ps --filter opencode.parent, if a worktree exists for
        # this start it, instead of the current dir, if none exists then normal
        # up. If more than on parent match is found, then not sure what we can
        # do. warnn....
        echo "Command not implemented"
        ;;
    scaffold)
        _opencode_ctx opencode:scaffold "$ws_out" "$@"
        ;;
    setup)
        # Run setup commands on an persisted instance
        _opencode_ctx opencode:setup "$ws_out" "$@"
        ;;
    run)
        # Run tasks (e.g. 'npm install' or 'go build') in the opencode container
        _opencode_ctx opencode:run "$ws_out" "$@"
        ;;
    new)
        # Remove existing containers before starting a fresh instance
        _opencode_ctx opencode:new "$ws_out" "$@"
        ;;
    changes)
        # Analyze branch changes for the workspace
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
