#!/usr/bin/env bash

SD_OPENCODE="${SD_OPENCODE:-$HOME/opencode}"
SD_REPO_HOME="${SD_REPO_HOME:-/home/$USER/repos}"
MANAGE_LABEL="dev.snowdon.opencode.managed"
WORKSPACE_LABEL="dev.snowdon.opencode.workspace"
LABEL_CONTAINER_PROJECT_NAME="com.docker.compose.project"
LABEL_ONE_OFF="com.docker.compose.oneoff"
LABEL_DEV_CONTAINER="dev.snowdon.image.opencode.devcontainer"
LABEL_IMAGE_WORKSPACE="dev.snowdon.opencode.workspace"
LABEL_NETWORK_MANAGED="dev.snowdon.opencode.managed"
LABEL_NETWORK_WORKSPACE="dev.snowdon.opencode.workspace"
TUI_LABEL="dev.snowdon.opencode.tui"
IMAGE_URL="${OPENCODE_IMAGE_URL:-devsnowdon/opencode-docker:latest}"
LOOPBACK="127.0.0.1"
COMPOSE_NET_DIR="$SD_OPENCODE/compose-net"
COMPOSE_VOL_DIR="$SD_OPENCODE/compose-vol"
DOCKER_ARGS="${DOCKER_ARGS:-}"

# Range for managed docker networks: an explicit CIDR ("172.20.0.0/16"), or a
# bare prefix whose mask is implied at 8 bits per octet ("172.20" -> /16).
NETWORK_RANGE="${OPENCODE_NET_RANGE:-172.20.0.0/16}"
# Mask of each network created inside the range (a /16 range slices into 256 /24s).
NET_SUBNET_MASK="${OPENCODE_NET_SUBNET:-24}"

# Parsed NETWORK_RANGE: 32-bit network address and prefix length, set by _net_parse.
net_base=""
net_mask=""

PROJECT_NAME=""
OPENCODE_ARGS=""

tmp_compose_dir=""
tmp_compose_file=""

network_name=""

_cleanup_scaffold_name=""
_cleanup_scaffold_pid=""
_cleanup_scaffold_output=""

_cleanup_changes_name=""
_cleanup_changes_pid=""
_cleanup_changes_output=""

declare -ga _cleanup_stack=()

_cleanup_run() {
  local i
  for ((i = ${#_cleanup_stack[@]} - 1; i >= 0; i--)); do
    "${_cleanup_stack[i]}"
  done
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

# --- docker driver -------------------------------------------------------
# Wraps docker_exec (which prepends DOCKER_ARGS) for every operation the
# launcher needs. The podman_<op> stubs below mark the future driver's shape.

docker_info() { docker_exec info; }
docker_compose() { docker_exec compose "$@"; }
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
docker_network_rm() { docker_exec network rm "$@"; }
docker_container_ls() { docker_exec ps "$@"; }
docker_container_inspect() { docker_exec inspect "$@"; }
docker_container_rm() { docker_exec rm "$@"; }
docker_container_kill() { docker_exec kill "$@"; }
docker_container_stop() { docker_exec stop "$@"; }
docker_image_ls() { docker_exec image ls "$@"; }
docker_image_rm() { docker_exec image rm "$@"; }
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
  # TODO: Cap can be increased to allow smaller OPENCODE_NET_SUBNET="28"
  if [[ "$NETWORK_RANGE" != */* ]]; then
    mask=$((${#octs[@]} * 8))
    ((mask > 24)) && mask=24
  fi
  if [[ ! "$mask" =~ ^[0-9]{1,2}$ ]] || ((mask < 1 || mask > 24)); then
    echo "error: OPENCODE_NET_RANGE mask must be between /1 and /24" >&2
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
  if ! _net_parse; then
    return 1
  fi

  if [[ ! "$NET_SUBNET_MASK" =~ ^[0-9]{1,2}$ ]] ||
    ((NET_SUBNET_MASK < 1 || NET_SUBNET_MASK > 24)); then
    echo "error: OPENCODE_NET_SUBNET must be between /1 and /24" >&2
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
  mapfile -t networks < <(_driver network_ls -q)
  while IFS= read -r subnet; do
    [[ -z "$subnet" ]] && continue
    used_networks["$subnet"]=1
  done < <(_driver network_subnets "${networks[@]}")

  # Slice the range into fixed-size subnets. When subnets are smaller than
  # the range the index selects the slice bits (e.g. a /16 range slices into
  # 256 x /24); a subnet mask no larger than the range mask yields a single
  # subnet (index 0).
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
  # TODO: Project name conflict - proj name is derived from basename, mighe have conflicts
  network_name="sd-$proj-default"

  available_subnet="$(find_free_network)" || {
    echo "No free subnet available" >&2
    return 1
  }

  # TODO: create network as a compose network, not external
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
  echo "git log --stat:"
  echo '```'
  git log --stat | cat
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

_sanitize_network_name() {
  local name="$1"

  name="${name,,}"               # lowercase
  name="${name//[^a-z0-9_.-]/-}" # invalid chars -> -
  while [[ "$name" == *--* ]]; do
    name="${name//--/-}"
  done
  name="${name#[-._]}"
  name="${name%[-._]}"

  printf '%s\n' "$name"
}

# Prepares the Docker Compose arguments. This function sets up the project
# configuration including network settings and git directory mounts.
_opencode_args_prepare() {
  local ws_out="$1"
  local -n args_out="$2"

  local compose_dir="${SD_OPENCODE:-$HOME/opencode}"
  # Build Docker Compose arguments starting with the main compose file
  args_out=(
    -p "$PROJECT_NAME"
    -f "$compose_dir/docker-compose.yml"
  )

  # TODO: Transient volumes - OPENCODE_DATA=false disables persisted volume
  # OPENCODE_CACHE=false disables the cache volumes, "all" adds all
  # "go python" adds go and python. Values are case-insensitive.
  if [[ -n "${OPENCODE_CACHE}" ]]; then
    if [[ "${OPENCODE_CACHE,,}" == "all" ]]; then
      args_out+=(-f "$COMPOSE_VOL_DIR/docker-compose.cache.yml")
    elif [[ "${OPENCODE_CACHE,,}" == "false" ]]; then
      echo "Running container without toolchain cache"
    else
      for id in ${OPENCODE_CACHE,,}; do
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

  # default to using compose default network but add labels to it, merge config
  # Add network configuration if OPENCODE_NETWORK environment or use custom default
  if [[ "$OPENCODE_NETWORK" == "@default" ]]; then
    # default to using a custom workspace
    # TODO: Project name conflict - proj name is derived from basename, might have conflicts
    local proj_name
    proj_name="$(_sanitize_network_name "$PROJECT_NAME")"
    _network_builder "$proj_name" "$ws_out" || {
      echo "Failed to create or find network for project: $proj_name" >&2
      return 1
    }
    OPENCODE_NETWORK="$network_name"
    export OPENCODE_NETWORK
    args_out+=(-f "$COMPOSE_NET_DIR/docker-compose.network.yml")
    echo "Using network: $OPENCODE_NETWORK"
  elif [[ -n "$OPENCODE_NETWORK" ]]; then
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
  if [[ ! ${SD_READ_ONLY:-} =~ ^[Ff][Aa][Ll][Ss][Ee]$ ]]; then
    # Create temporary directory for git compose configuration
    tmp_compose_dir="$(mktemp -d)"
    tmp_compose_file="$tmp_compose_dir/docker-compose.git.yml"

    # Find all .git directories in workspace for read-only mounting
    # This ensures git repositories are accessible but protected from modifications
    # SECURITY NOTE: Current implementation mounts all .git directories found within
    # the workspace. A future improvement should consider whether to traverse up to
    # the git root directory or leave directories as-is for security isolation.
    #
    # Vendor/build/test-artifact directories are pruned so throwaway nested repos
    # (e.g. node_modules, tests/.tmp sandboxes) aren't mounted or counted, which
    # keeps the compose config stable across command invocations.
    # TODO: read the exlcude list from .gitignore?
    git_dirs=()
    while IFS= read -r -d '' git_dir; do
      git_dirs+=("$git_dir")
      echo "read-only locking dir: $git_dir"
    done < <(find "$ws_out" \
      \( -name node_modules -o -name .cargo -o -name target -o \
      -name .tmp -o -name vendor \) -prune -o \
      -type d -name .git -print0)

    # Generate docker-compose override file if git directories were found
    if ((${#git_dirs[@]} > 0)); then
      {
        printf '%s\n' 'services:'
        printf '%s\n' '  opencode:'
        printf '%s\n' '    volumes:'

        for git_dir in "${git_dirs[@]}"; do
          rel="${git_dir#"$ws_out"/}"
          printf '      - %s:/workspace/%s:ro\n' \
            "$git_dir" \
            "$rel"
        done
      } >"$tmp_compose_file"

      args_out+=(-f "$tmp_compose_file")
    fi
  fi

  # Display CPU resource allocation if configured
  if [ -n "$OPENCODE_CPUSET" ]; then
    echo "Using CPUSET: $OPENCODE_CPUSET"
  fi
}

# Ensure the opencode container exists and is running.
# Assumes the caller is inside _opencode_ctx (cd'd into the workspace, WORKSPACE
# exported) and OPENCODE_ARGS is set. Shared precondition used by start, exec,
# and up to avoid repeating the 'docker compose up' step.
#
# Never recreates an already-running container (--no-recreate), so inspection
# commands don't disturb an existing session. Only the explicit recreate
# commands (start/new) pass --recreate.
_opencode_ensure_up() {
  #local recreate=0
  #if [[ "${1:-}" == "--recreate" ]]; then
  #  recreate=1
  #  shift
  #fi

  #if ((recreate)); then
  _driver compose "${OPENCODE_ARGS[@]}" up -d opencode
  #else
  #  _driver compose "${OPENCODE_ARGS[@]}" up -d --no-recreate opencode
  #fi
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

# Run a command in the opencode project context.
# Centralises the setup shared by every command: prepares the Docker Compose
# args, cd's into the workspace, exports WORKSPACE, and exposes the compose
# args via the global OPENCODE_ARGS array. It then invokes the named function
# with only the remaining command arguments, so command bodies can use the
# inherited ws/proj, the OPENCODE_ARGS array, and $@ for trailing args.
_opencode_ctx() {
  local fn="$1"
  WORKSPACE="$2"
  PROJECT_NAME="$3"
  shift 3

  local -a args=()
  _opencode_args_prepare "$WORKSPACE" args || return 1
  cleanup_add _cleanup

  OPENCODE_ARGS=("${args[@]}")

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

_backend_healthy() {
  local BACKEND_HEALTH_URL="${OPENCODE_BACKEND_ORIGIN:-http://$LOOPBACK:4096}"
  curl -fsS \
    --connect-timeout 0.2 \
    --max-time 0.5 \
    "$BACKEND_HEALTH_URL" >/dev/null 2>&1
}

# List managed containers. By default oneoff (throwaway `compose run`) containers
# are skipped; pass --all to include them. An optional workspace argument scopes
# the results to containers labelled for that workspace.
_find_docker_managed() {
  local include_oneoff=0
  local ws_filter stopped
  for arg in "$@"; do
    case "$arg" in
    --all) include_oneoff=1 ;;
    --stopped) stopped="-a" ;;
    *) ws_filter="$arg" ;;
    esac
  done
  local id rec oneoff istui
  _driver container_ls -q $stopped \
    --filter "label=$MANAGE_LABEL=true" \
    ${ws_filter:+--filter "label=$WORKSPACE_LABEL=$ws_filter"} 2>/dev/null | while read -r id; do
    if [ "$include_oneoff" -eq 0 ]; then
      rec="$(
        _driver container_inspect \
          --format '{{index .Config.Labels "'"$LABEL_ONE_OFF"'"}}{{"\t"}}{{index .Config.Labels "'"$TUI_LABEL"'"}}{{"\t"}}.' \
          "$id" 2>/dev/null
      )"
      IFS=$'\t' read -r oneoff istui _ <<<"$rec"
      if [ "$oneoff" = "True" ] && [ "$istui" != "true" ]; then
        continue
      fi
    fi
    printf '%s\n' "$id"
  done
}

_find_workspace() {
  _driver container_inspect \
    --format "{{index .Config.Labels \"$WORKSPACE_LABEL\"}}" \
    "$1" 2>/dev/null
}

_run_opencode_executable() {
  if command which opencode >/dev/null 2>&1; then
    local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://$LOOPBACK:4096}"
    echo "Using opencode tui $(command which opencode)"
    command opencode attach "$BACKEND_ORIGIN" "$@"
  else
    local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://opencode:4096}"
    # this need to be able to pass info to healthy, without a port
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
        echo "  run: $DRIVER_BIN rm -f $_cleanup_scaffold_name" >&2
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
        echo "  run: $DRIVER_BIN rm -f $_cleanup_changes_name" >&2
        _driver container_ls -a --filter "name=oc-changes-" \
          --format '  {{.ID}}  {{.Names}}  {{.Status}}' >&2 || true
      fi
    fi
  fi
  if [[ -n "$_cleanup_changes_output" ]]; then
    rm -f -- "$_cleanup_changes_output"
  fi
}

# Main function to start and run opencode in a Docker container
# This function creates and executes the opencode container with proper
# workspace configuration and environment isolation.
opencode() {
  # Container conflict detection.
  # The service binds a fixed host port that cannot be shared by multiple
  # running containers, so a new container cannot be created while another
  # managed opencode container is already running. Detect those instances by
  # label, and if one belongs to a different workspace, abort and tell the
  # user how to remove it before proceeding.
  local conflict_id conflict_ws
  while read -r conflict_id; do
    [[ -z "$conflict_id" ]] && continue

    # Use docker inspect, not docker ps --format: .Config.Labels is always a
    # map, whereas .Labels from 'ps --format' can surface as a slice (indexing
    # a slice by string then fails), depending on the docker/compose build.
    conflict_ws="$(_find_workspace "$conflict_id")"
    if [[ -n "$conflict_ws" && "$conflict_ws" != "$WORKSPACE" ]]; then
      echo "Container already running for workspace $conflict_ws." >&2
      echo "Run 'opencode:down $conflict_ws' first, or use 'opencode:new' to" >&2
      echo "automatically remove the existing container." >&2
      exit 1
    fi
  done < <(_find_docker_managed)

  # start the containers
  _opencode_ensure_up || {
    echo "Failed to start the opencode container" >&2
    exit 1
  }

  # ensure cleanup afterwards
  cleanup_add _cleanup_opencode_backend

  # TODO: don't expose the port on the host unless required, then one backend
  # cannot talk to another projects backend, this will be helpfull if multiple
  # containers are enabled

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
opencode:exec() {
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

# Run a task (e.g. 'npm install' or 'go build') inside the opencode service.
# This is a non-interactive variant of opencode:exec, useful for one-off
# build/setup commands. If the project's persistent container is already
# running the task runs inside it (leaving it running); otherwise a throwaway
# `compose run` container runs the task and exits, publishing no ports.
opencode:run() {
  echo "Running in opencode project: $PROJECT_NAME ($WORKSPACE)"

  # TODO: Background so it can be canceled

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

  # Refresh the repository holding the launcher, compose file, and Dockerfile.
  git -C "$SD_OPENCODE" pull

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
  # docker compose down does not remove one-off containers created via
  # 'compose run' (like the TUI). Stop any remaining managed containers
  # scoped to this workspace.
  opencode:stop "$WORKSPACE"

  # Stop and remove containers, networks, and volumes
  _driver compose "${OPENCODE_ARGS[@]}" down
}

# Start the opencode container without running any processes in it.
# This is useful to keep the container alive in the background so it can be
# attached to later with 'opencode:exec' without the overhead of creating it.
opencode:up() {
  echo "Starting opencode container: $PROJECT_NAME ($WORKSPACE)"

  _driver compose "${OPENCODE_ARGS[@]}" up -d opencode "$@"

  # TODO: start the backend?
}

# Create a new opencode project scaffold with git initialization
# This function sets up a new project workspace with proper configuration
# and launches the opencode runner to begin development.
#
# TODO: Project name conflict - is derived from basename only, which may cause naming
# conflicts when different directories share the same final component.
#
# For example: /home/user/repos/gists/one and /home/user/repos/projects/one
# both become project name "one". A future improvement should use a sanitized
# version of the full relative path to ensure uniqueness while maintaining
# Docker Compose naming compatibility (lowercase, hyphens only).
opencode:scaffold() {
  if (($# != 1)) && [[ -t 0 ]]; then
    echo "Error: no task provided" >&2
    _opencode_help_cmd "scaffold"
    exit 1
  fi

  echo "Running on opencode project: $PROJECT_NAME ($WORKSPACE)"

  # Configure CPU resources for the container
  local cpus="${OPENCODE_CPUSET:-2-3}"

  # Build context information for the opencode runner. Reduces execution
  # overhead and could eliminate a dependency on shell environment within the
  # container.
  local tmp_context
  tmp_context="<task-information>
You are creating the inital project scaffold.
The inital project information is as follows.
You have access to the CPUSET: $cpus
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

  # TODO: Implement custom agent and model configuration
  # Allow users to specify custom agent definitions and model settings
  # for scaffold operations via environment variables or configuration files.

  # The one-off container runs as a background job of the host launcher (the
  # container itself still lives in the docker daemon). Its output is captured
  # to a temp file so it can be streamed to the terminal, and on Ctrl+C the
  # existing INT trap -> EXIT -> cleanup_add stack kills the compose client and
  # the container instead of docker's (absent, with -T) signal proxy.
  local cname="oc-scaffold-$$"
  local outfile status
  outfile="$(mktemp "${TMPDIR:-/tmp}/opencode-scaffold.XXXXXX")" || return 1

  _cleanup_scaffold_name="$cname"
  _cleanup_scaffold_output="$outfile"
  _cleanup_scaffold_pid=""
  cleanup_add _cleanup_scaffold

  # Execute opencode with context information
  {
    printf '%s' "$tmp_context"
    if [ "$#" -gt 0 ]; then
      printf '%s' "$1"
    else
      cat
    fi
  } | _driver compose "${OPENCODE_ARGS[@]}" \
    run --rm -T --name "$cname" opencode 'exec opencode run "$@"' \
    opencode --auto "$@" >"$outfile" 2>&1 &
  _cleanup_scaffold_pid=$!

  # Stream the captured output to the terminal
  tail -f "$outfile" &
  local _tail_pid=$!
  wait "$_cleanup_scaffold_pid"
  status=$?
  kill $_tail_pid

  return "$status"
}

# Remove existing opencode containers before starting.
# This resolves port-binding conflicts when multiple managed containers
# (labelled dev.snowdon.opencode.managed=true) cannot share the same port.
opencode:new() {
  opencode:stop

  echo "Starting fresh opencode container for project: $PROJECT_NAME"
  opencode "$@"
}

# Stops the existing managed containers
# Pass --all to include oneoff (throwaway `compose run`) containers.
# An optional workspace argument scopes the stop to containers for that
# workspace; by default all workspaces are stopped.
opencode:stop() {
  echo "Stopping existing opencode containers"

  local all=0
  local args=()
  for arg in "$@"; do
    case "$arg" in
    --all | -a) all=1 ;;
    *) args+=("$arg") ;;
    esac
  done

  # First positional argument is the workspace to scope to; empty = all
  # workspaces.
  local ws_scope=""
  if [[ -n "${args[0]:-}" ]]; then
    ws_scope="$(realpath "${args[0]}")"
  fi

  local find_args=()
  [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
  ((all)) && find_args+=(--all)

  while read -r id; do
    [[ -z "$id" ]] && continue
    ws_label="$(_find_workspace "$id")"
    if [[ -n "$ws_label" && "$ws_label" != "$WORKSPACE" ]]; then
      echo "Stopping managed container $id (workspace: $ws_label)"
    else
      echo "Stopping managed container $id"
    fi
    _driver container_stop "$id"
  done < <(_find_docker_managed "${find_args[@]}")
}

# Force-remove all managed opencode containers.
# Unlike 'stop' which gracefully stops containers, this immediately removes
# them using 'docker rm -f', which is useful when a container is stuck or
# when you need to fully clean up.
# Pass --all to include oneoff (throwaway `compose run`) containers.
# An optional workspace argument scopes the delete to containers for that
# workspace; by default all workspaces are removed.
opencode:delete() {
  echo "Force-removing all opencode containers"
  local all=0
  local args=()
  for arg in "$@"; do
    case "$arg" in
    --all | -a) all=1 ;;
    *) args+=("$arg") ;;
    esac
  done

  # First positional argument is the workspace to scope to; empty = all
  # workspaces.
  local ws_scope=""
  if [[ -n "${args[0]:-}" ]]; then
    ws_scope="$(realpath "${args[0]}")"
  fi

  local find_args=(--stopped)
  [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
  ((all)) && find_args+=(--all)

  while read -r id; do
    [[ -z "$id" ]] && continue
    ws_label="$(_find_workspace "$id")"
    if [[ -n "$ws_label" && "$ws_label" != "$WORKSPACE" ]]; then
      echo "Force-removing managed container $id (workspace: $ws_label)"
    else
      echo "Force-removing managed container $id"
    fi
    _driver container_rm -f "$id"
  done < <(_find_docker_managed "${find_args[@]}")

  if [ "$all" -eq 1 ]; then
    # remove the images
    local filter_images=(
      --filter "label=$LABEL_DEV_CONTAINER"
    )
    # if a workspace exist, only for that workspace
    if [[ -n "$ws_scope" ]]; then
      filter_images+=(--filter "label=$LABEL_IMAGE_WORKSPACE=$ws_scope")
    fi

    local -a images
    mapfile -t images < <(_driver image_ls -q "${filter_images[@]}")
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
    mapfile -t networks < <(_driver network_ls -q "${filters_network[@]}")

    if ((${#networks[@]})); then
      _driver network_rm "${networks[@]}"
    fi
  fi
}

# Print the managed opencode containers in a ps-style table.
# By default oneoff (throwaway `compose run`) containers are skipped; pass
# --all to include them. An optional workspace argument scopes the listing to
# containers labelled for that workspace; pass --quiet to print only the
# container ids (one per line), handy for scripting stop/delete.
opencode:ls() {
  local all=0 quiet=0
  local args=()
  for arg in "$@"; do
    case "$arg" in
    --all | -a) all=1 ;;
    --quiet | -q) quiet=1 ;;
    *) args+=("$arg") ;;
    esac
  done

  # First positional argument is the workspace to scope to; empty = all
  # workspaces.
  local ws_scope=""
  if [[ -n "${args[0]:-}" ]]; then
    ws_scope="$(realpath "${args[0]}")"
  fi

  # Gather one tab-separated record per managed container (id, status,
  # workspace, project, oneoff, tui). `docker inspect` is used rather than
  # `docker ps --format`: .Config.Labels is always a map there, while .Labels
  # from `ps --format` can surface as a slice (indexing a slice by string then
  # fails) depending on the docker/compose build. Fields are separated with
  # {{"\t"}} (a Go template string literal), not a raw \t: docker inspect does
  # not interpolate \t escapes the way docker ps does. A trailing '.' keeps
  # empty trailing label columns from being dropped by `read -a`.
  local find_args=(--stopped)
  [[ -n "$ws_scope" ]] && find_args+=("$ws_scope")
  ((all)) && find_args+=(--all)

  local -a records=()
  local id rec
  while read -r id; do
    [[ -z "$id" ]] && continue
    rec="$(
      _driver container_inspect \
        --format '{{.ID}}{{"\t"}}{{.State.Status}}{{"\t"}}{{index .Config.Labels "'"$WORKSPACE_LABEL"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_CONTAINER_PROJECT_NAME"'"}}{{"\t"}}{{index .Config.Labels "'"$LABEL_ONE_OFF"'"}}{{"\t"}}{{index .Config.Labels "'"$TUI_LABEL"'"}}{{"\t"}}.' \
        "$id" 2>/dev/null
    )"
    [[ -n "$rec" ]] && records+=("$rec")
  done < <(_find_docker_managed "${find_args[@]}")

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
    if [[ "$oneoff" == "True" ]]; then
      mode="one off"
    elif [[ "${istui,,}" == "true" ]]; then
      mode="tui"
    else
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
  echo "Analyzing changes for project: $PROJECT_NAME ($WORKSPACE)"

  # Run the git analysis against the existing container when it is running,
  # otherwise a throwaway `compose run` container; either way the returned
  # paths (under /workspace) match what opencode sees. Capture the output for
  # feeding into opencode below.
  local changes
  # TODO: explain the refs used in the diff (from upstream to HEAD etc)
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
  local outfile status
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
  wait "$_cleanup_changes_pid"
  status=$?
  kill "$_tail_pid" 2>/dev/null || true
  return "$status"
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
    echo "  Remove all managed opencode containers (resolving any port conflicts) then"
    echo "  start a fresh container and opencode session."
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
    echo "down"
    echo "  Remove the project's compose resources (containers, networks, volumes) and"
    echo "  stop any remaining managed containers (e.g. the TUI) for this workspace,"
    echo "  preserving the workspace configuration."
    echo "  Args:"
    echo "    (none)"
    ;;
  delete)
    echo "delete <project> [--all]"
    echo "  Force-remove all managed opencode containers across workspaces using"
    echo "  'docker rm -f'. Immediately removes stuck or unwanted containers."
    echo "  If <project> is not specified, all opencode-docker managed containers"
    echo "  will be removed"
    echo "  Args:"
    echo "    --all     Also remove oneoff (throwaway 'compose run') containers."
    echo "    <project> The path to the project"
    ;;
  ls)
    echo "ls [directory] [--all] [--quiet]"
    echo "  List the managed opencode containers in a ps-style table (id, status,"
    echo "  workspace, project, mode), including stopped ones. Mode is one of"
    echo "  'tui', 'one off', or 'main'. By default oneoff (throwaway 'compose"
    echo "  run') containers are skipped."
    echo "  Args:"
    echo "    --all, -a   Also list oneoff (throwaway 'compose run') containers."
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
    echo "stop <project> [--all]"
    echo "  Gracefully stop the managed opencode containers across all workspaces,"
    echo "  freeing their ports. 'down' scopes this to the current workspace."
    echo "  If <project> is specified then only act on that project."
    echo "  Args:"
    echo "    --all     Also stop oneoff (throwaway 'compose run') containers."
    echo "    <project> The path to the project"
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
  scaffold)
    echo "scaffold [path] (task) [opencode args...]"
    echo "  Create a new project using opencode at the path; with a path that does"
    echo "  not start with /, it defaults to SD_REPO_HOME (default: /home/<user>/repos),"
    echo "  then runs an interactive opencode scaffolding session."
    echo "  If not given a task argument, it will read from the stdin"
    echo "  Args:"
    echo "    path                Project name or './relative/path'. Optional."
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
  printf '  %-11s %s\n' "new" "Remove conflicting containers and start a fresh session"
  printf '  %-11s %s\n' "up" "Start the container in the background without running a process"
  printf '  %-11s %s\n' "setup" "Run setup commands against the persisted instance"
  printf '  %-11s %s\n' "down" "Remove the project's containers, networks, volumes, and TUI"
  printf '  %-11s %s\n' "delete" "Force-remove all managed opencode container resources across workspaces (--all for oneoffs)"
  printf '  %-11s %s\n' "ls" "List managed opencode containers in a ps-style table (--all for oneoffs)"
  printf '  %-11s %s\n' "exec" "Run a command interactively inside the running container"
  printf '  %-11s %s\n' "stop" "Stop the managed opencode containers across all workspaces (--all for oneoffs + images)"
  printf '  %-11s %s\n' "run" "Run a one-off non-interactive task in the service"
  printf '  %-11s %s\n' "shell" "Open an interactive shell inside the running container"
  printf '  %-11s %s\n' "scaffold" "Create a new opencode project with a fresh git repo"
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
  echo "Run '$0 help <command>'   for details on a specific command."
  echo "Run '$0 <command> --help' for details on a specific command."
  echo "Run '$0 <command> -h'     for details on a specific command."

  if _driver image_inspect "$IMAGE_URL" >/dev/null 2>&1; then
    echo
    local opencode_version
    local devcontainer_version

    opencode_version="$(
      _driver image_inspect "$IMAGE_URL" \
        --format '{{ index .Config.Labels "dev.snowdon.image.opencode.version" }}'
    )"

    devcontainer_version="$(
      _driver image_inspect "$IMAGE_URL" \
        --format '{{ index .Config.Labels "dev.snowdon.image.opencode.devcontainer" }}'
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

  if command -v git &>/dev/null; then
    local tags
    tags="$(git -C "$SD_OPENCODE" describe --tags --exact-match 2>/dev/null || echo unknown)"
    local commit
    commit="$(git -C "$SD_OPENCODE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    # Get the current git location from ~/opencode
    echo "Git tag:            $tags"
    echo "Git commit:         $commit"
  fi
}

_maybe_check_outside_home() {
  local ws_out home ws_out_normalized valid_subdir answer
  ws_out="$1"

  if [[ ! ${SD_YOLO:-} =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
    # Remove trailing slashes, while preserving "/".
    if [[ "$SD_YOLO_HOME" == "true" ]]; then
      home="$SD_REPO_HOME"
    else
      home="$HOME"
    fi
    while [[ $home != "/" && $home == */ ]]; do
      home=${home%/}
    done

    ws_out_normalized=$ws_out
    while [[ $ws_out_normalized != "/" && $ws_out_normalized == */ ]]; do
      ws_out_normalized=${ws_out_normalized%/}
    done

    valid_subdir=0

    if [[ $home == "/" ]]; then
      # Any non-root absolute path is a subdirectory of "/".
      if [[ $ws_out_normalized != "/" &&
        $ws_out_normalized == /* ]]; then
        valid_subdir=1
      fi
    elif [[ $ws_out_normalized == "$home"/* ]]; then
      # The "$home/*" pattern excludes "$home" itself.
      valid_subdir=1
    fi

    if ((!valid_subdir)); then
      printf 'Output directory is outside a subdirectory of HOME:\n  %s\n' "$ws_out"
      read -r -p "Continue anyway? [y/N] " answer </dev/tty

      case ${answer,,} in
      y | yes) ;;
      *)
        printf 'Aborted.\n' >&2
        exit 1
        ;;
      esac
    fi
  fi
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
    _opencode_help_cmd "$cmd"
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
  ls)
    opencode:ls "$@"
    return 0
    ;;
  esac

  # TODO: if OPENCODE_WORKSPACE env is set, then we can use then over workspace
  # when no argument is provided

  # Get the workspace directory from arguments or current directory
  local ws_out

  case "$cmd" in
  scaffold)
    # require a task argument when stdin is a terminal (nothing can be piped in)
    if [ -t 0 ] && [[ $# -lt 2 ]]; then
      echo "You did not provide a task to scaffold." >&2
      exit 1
    fi

    if [[ -z ${1+x} ]]; then
      # No project name: the current directory must be empty.
      if [[ -n $(find "$ws_out" -mindepth 1 -print -quit) ]]; then
        echo "$ws_out is not empty, scaffold failed" >&2
        exit 1
      fi
    else
      # Resolve the project name to an absolute workspace path.
      local name=$1
      if [[ "$name" == ./ ]]; then
        # "./" alone means the current directory itself
        ws_out="$(pwd)"
      elif [[ "$name" == ./* ]]; then
        # relative to the current directory
        ws_out="$(pwd)/${name#./}"
      elif [[ "$name" == /* ]]; then
        # absolute path
        ws_out="$name"
      else
        # under the SD_REPO_HOME root
        ws_out="${SD_REPO_HOME}/$name"
      fi
      shift

      # An absolute path is used as-is: no emptiness check, the caller owns it.
      # repo-home paths must target a new or empty directory.
      local check_empty=1
      [[ "$name" == /* || "$name" == ./* ]] && check_empty=0

      if [[ -e "$ws_out" || -L "$ws_out" ]]; then
        if [[ ! -d "$ws_out" ]]; then
          echo "Path already exists but is not a directory: $ws_out" >&2
          exit 1
        elif ((check_empty)) && [[ -n $(find "$ws_out" -mindepth 1 -print -quit) ]]; then
          echo "$ws_out is not empty; scaffold failed" >&2
          exit 1
        elif ((check_empty)); then
          echo "Using existing empty directory: $ws_out"
        else
          echo "Using existing directory: $ws_out"
        fi
      else
        echo "Creating $ws_out"
        mkdir -p -- "$ws_out" || exit 1
      fi
      ws_out="$(cd -- "$ws_out" && pwd)"
    fi
    ;;
  esac

  # when argument one is a path starting with / or ./ capture it as the ws_out,
  # else we use the cwd.
  if [[ -z ${ws_out+x} ]]; then
    if [[ "$1" == ./* || "$1" == /* ]] && [[ -d $1 ]]; then
      ws_out="$(realpath "$1")"
      shift
    else
      ws_out="$(pwd)"
    fi
  fi

  # Skip this check when SD_YOLO is set to "true" (case-insensitive).
  # Check if the workspace lies outside of a sub directory of $HOME.
  _maybe_check_outside_home "$ws_out"

  # Set up compose directory and project name
  local proj
  proj="$(basename "$ws_out")"

  # Display configuration information
  echo "Using opencode workspace: $ws_out"
  echo "Compose project: $proj"

  # Dispatch to the appropriate command handler
  case "$cmd" in
  down)
    _opencode_ctx opencode:down "$ws_out" "$proj" "$@"
    ;;
  start)
    _opencode_ctx opencode "$ws_out" "$proj" "$@"
    ;;
  exec)
    _opencode_ctx opencode:exec "$ws_out" "$proj" "$@"
    ;;
  compose)
    _opencode_ctx opencode:compose "$ws_out" "$proj" "$@"
    ;;
  shell)
    _opencode_ctx opencode:exec "$ws_out" "$proj" sh "$@"
    ;;
  up)
    # Start containers without running processes
    _opencode_ctx opencode:up "$ws_out" "$proj" "$@"
    ;;
  scaffold)
    _opencode_ctx opencode:scaffold "$ws_out" "$proj" "$@"
    ;;
  setup)
    # Run setup commands on an persisted instance
    _opencode_ctx opencode:setup "$ws_out" "$proj" "$@"
    ;;
  run)
    # Run tasks (e.g. 'npm install' or 'go build') in the opencode container
    _opencode_ctx opencode:run "$ws_out" "$proj" "$@"
    ;;
  new)
    # Remove existing containers before starting a fresh instance
    _opencode_ctx opencode:new "$ws_out" "$proj" "$@"
    ;;
  changes)
    # Analyze branch changes for the workspace
    _opencode_ctx opencode:changes "$ws_out" "$proj" "$@"
    ;;
  security)
    # TODO: Implement command to analyze repository security Should read code
    # files and check for executable commands in normal usage For example,
    # checking for npm pre-install scripts or other potential risks
    echo "command not implemented"
    ;;
  clone)
    # TODO: Implement commadn to retrieve a git repository and clone it into a
    # location clone --check runs security, then perform come action or check
    # if it already exists and preform some action
    echo "command not implemented"
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

# Execute the main function with all provided arguments
main "$@"
