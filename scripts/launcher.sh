#!/usr/bin/env bash

SD_OPENCODE="${SD_OPENCODE:-$HOME/opencode}"
MANAGE_LABEL="dev.snowdon.opencode.managed"
WORKSPACE_LABEL="dev.snowdon.opencode.workspace"
IMAGE_URL="${OPENCODE_IMAGE_URL:-devsnowdon/opencode-docker}"
LOOPBACK="127.0.0.1"

declare -ga _cleanup_stack=()

tmp_compose_dir=""
tmp_compose_file=""

OPENCODE_ARGS=""

_cleanup_run() {
  local i
  for ((i=${#_cleanup_stack[@]}-1; i>=0; i--)); do
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

# clean up time main files with the docker compose merge
_cleanup() {
  if [[ -n "$tmp_compose_dir" && -d "$tmp_compose_dir" ]]; then
    rm -rf -- "$tmp_compose_dir"
  fi
}

# print a message about the current git details of the cwd
_print_git_context() {
  if ! which git > /dev/null; then
    return
  fi
  if [[ ! -d .git ]]; then
    return
  fi

  echo "Additional project context:

The author details for this task:
Name: $(git config --global user.name)
Email: $(git config --global user.email)

git log --stat:
\`\`\`
$(git log --stat | cat)
\`\`\`"
}

# print details about the readme file is one exists in cwd
_print_readme() {
  if [[ ! -f ./README.md ]]; then
    return
  fi
  echo "README.md:
\`\`\`
$(cat README.md)
\`\`\`"
}

# Prepares the Docker Compose arguments. This function sets up the project
# configuration including network settings and git directory mounts.
_opencode_args_prepare() {
  local ws_out="$1"
  local proj_out="$2"
  local -n args_out="$3"

  local compose_dir="${SD_OPENCODE:-$HOME/opencode}"
  # Build Docker Compose arguments starting with the main compose file
  args_out=(
    -p "$proj_out"
    -f "$compose_dir/docker-compose.yml"
  )

  # TODO: Transient volumes - OPENCODE_DATA=false disables persisted volume
  # OPENCODE_CACHE=false disables the cache volumes

  # Add network configuration if OPENCODE_NETWORK environment variable is set
  if [[ -n "${OPENCODE_NETWORK:-}" ]]; then
    args_out+=(-f "$compose_dir/docker-compose.network.yml")
    echo "Using network: $OPENCODE_NETWORK"
  fi

  # TODO: Add a merge point for a user defined config

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
        rel="${git_dir#$ws_out/}"
        printf '      - %s:/workspace/%s:ro\n' \
            "$git_dir" \
            "$rel"
      done
    } > "$tmp_compose_file"

    args_out+=(-f "$tmp_compose_file")
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
  local recreate=0
  if [[ "${1:-}" == "--recreate" ]]; then
    recreate=1
    shift
  fi

  if ((recreate)); then
    docker compose "${OPENCODE_ARGS[@]}" up -d opencode
  else
    docker compose "${OPENCODE_ARGS[@]}" up -d --no-recreate opencode
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
  running="$(docker compose "${OPENCODE_ARGS[@]}" ps -q opencode)"

  if [[ -n "$running" ]]; then
    # Use the already-running container. Without -T (interactive) output streams
    # straight to the terminal; with -T it can be captured by the caller.
    if ((interactive)); then
      docker compose "${OPENCODE_ARGS[@]}" exec -w /workspace opencode "$@"
    else
      docker compose "${OPENCODE_ARGS[@]}" exec -T -w /workspace opencode "$@"
    fi
  else
    # No running container: use a throwaway container that runs the task and
    # exits, publishing no ports.
    docker compose "${OPENCODE_ARGS[@]}" run --rm -w /workspace opencode "$@"
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
  local ws="$2"
  local proj="$3"
  shift 3

  local -a args=()
  _opencode_args_prepare "$ws" "$proj" args || return 1
  cleanup_add _cleanup

  OPENCODE_ARGS=("${args[@]}")

  (
    # traps inside subshell for proper cleanup and signal handling
    trap _cleanup_run EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cd "$ws" || exit 1
    export WORKSPACE="$ws"
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

_find_docker_managed() {
  docker ps -q \
    --filter "label=$MANAGE_LABEL=true" 2>/dev/null
}

_find_workspace() {
  docker inspect \
    --format "{{index .Config.Labels \"$WORKSPACE_LABEL\"}}" \
    "$1" 2>/dev/null
}

_run_opencode_executable() {
  if command which opencode > /dev/null 2>&1; then
    local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://$LOOPBACK:4096}"
    echo "Using opencode tui $(command which opencode)"
    command opencode attach "$BACKEND_ORIGIN" "$@"
  else
    local BACKEND_ORIGIN="${OPENCODE_BACKEND_ORIGIN:-http://opencode:4096}"
    # this need to be able to pass info to healthy, without a port
    docker compose "${OPENCODE_ARGS[@]}" run --rm --remove-orphans tui \
      attach "$BACKEND_ORIGIN" \
      "$@"
  fi
}

_cleanup_opencode_backend() {
  docker compose "${OPENCODE_ARGS[@]}" exec \
    opencode pkill -f 'opencode serve' || true
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

    oneoff=$(docker inspect \
      --format '{{ index .Config.Labels "com.docker.compose.oneoff" }}' \
      "$conflict_id" 2>/dev/null)
    if [ "$oneoff" = "True" ]; then
      continue
    fi

    # Use docker inspect, not docker ps --format: .Config.Labels is always a
    # map, whereas .Labels from 'ps --format' can surface as a slice (indexing
    # a slice by string then fails), depending on the docker/compose build.
    conflict_ws="$(_find_workspace $conflict_id)"
    if [[ -n "$conflict_ws" && "$conflict_ws" != "$ws" ]]; then
      echo "Container already running for workspace $conflict_ws." >&2
      echo "Run 'opencode:stop $conflict_ws' first, or use 'opencode:new' to" >&2
      echo "automatically remove the existing container." >&2
      exit 1
    fi
  done < <(_find_docker_managed)
  
  # start the containers
  _opencode_ensure_up
  
  # ensure cleanup afterwards
  cleanup_add _cleanup_opencode_backend
  
  # start or resuse and existing container for the workspace
  if ! _backend_healthy; then
    # Start the handler in the background
    docker compose "${OPENCODE_ARGS[@]}" exec \
      -d \
      -w /workspace \
      opencode opencode serve --hostname 0.0.0.0 --port 4096 

    echo "Waiting for the opencode backend to launch"
    # 40 secs
    for i in {1..200}; do
      if _backend_healthy; then
        break
      fi

      if [ "$i" -eq 200 ]; then
        echo "OpenCode server failed to start"
        echo 'It may be a delayed start'
        exit 1
      fi
      
      sleep 0.2
    done
  fi

  echo 'Backend ready. Attaching...'

  # attach a host TUI and wait. on exit kill
  _run_opencode_executable "$@"

  # Verify container status after execution
  container_id="$(docker compose "${OPENCODE_ARGS[@]}" ps -q -a opencode)"
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
  echo "Executing in opencode project: $proj ($ws)"

  # Ensure the container is running before executing commands
  #_opencode_ensure_up

  # Execute command interactively in the running container
  docker compose "${OPENCODE_ARGS[@]}" exec -it opencode "$@"
}

# Run a task (e.g. 'npm install' or 'go build') inside the opencode service.
# This is a non-interactive variant of opencode:exec, useful for one-off
# build/setup commands. If the project's persistent container is already
# running the task runs inside it (leaving it running); otherwise a throwaway
# `compose run` container runs the task and exits, publishing no ports.
opencode:run() {
  echo "Running in opencode project: $proj ($ws)"

  _opencode_dispatch 0 "$@"
}

# Run setup commands on an existing persisted opencode instance.
# This runs the given non-interactive commands (e.g. 'npm install' or
# 'go build') against the existing container when it is running, otherwise a
# throwaway `compose run` container, then returns to the user shell while
# leaving any pre-existing container running for later work.
opencode:setup() {
  echo "Setting up opencode project: $proj ($ws)"

  _opencode_ensure_up
  # and create the resources in that container
  _opencode_dispatch 0 "$@"
}

# Execute arbitrary Docker Compose commands for the opencode project
# This function provides direct access to Docker Compose functionality
# for advanced container management operations.
opencode:compose() {
  echo "Running Docker Compose for project: $proj ($ws)"

  # Pass all arguments directly to Docker Compose
  docker compose "${OPENCODE_ARGS[@]}" "$@"
}

# Stop all managed opencode containers for the specified project
# This function stops managed containers and cleans up resources
# while preserving the workspace configuration.
opencode:stop() {
  echo "Stopping opencode project: $proj ($ws)"

  # Stop and remove containers, networks, and volumes
  docker compose "${OPENCODE_ARGS[@]}" down
}

# Start the opencode container without running any processes in it.
# This is useful to keep the container alive in the background so it can be
# attached to later with 'opencode:exec' without the overhead of creating it.
opencode:up() {
  echo "Starting opencode container: $proj ($ws)"

  docker compose "${OPENCODE_ARGS[@]}" up -d opencode "$@"

  # TODO: start the backend?
}

# Create a new opencode project scaffold with git initialization
# This function sets up a new project workspace with proper configuration
# and launches the opencode runner to begin development.
# NOTE: Project name is derived from basename only, which may cause naming
# conflicts when different directories share the same final component.
# For example: /home/user/repos/gists/one and /home/user/repos/projects/one
# both become project name "one". A future improvement should use a sanitized
# version of the full relative path to ensure uniqueness while maintaining
# Docker Compose naming compatibility (lowercase, hyphens only).
opencode:scaffold() {
  if (( $# >= 1 )); then
    task=$1
    shift 1
  elif [[ ! -t 0 ]]; then
      task=$(cat)
  else
      echo "error: no task provided" >&2
      exit 1
  fi

  echo "Running on opencode project: $proj ($ws)"

  # Configure CPU resources for the container
  local cpus="${OPENCODE_CPUSET:-2-3}"

  # Build context information for the opencode runner. Reduces execution
  # overhead and could eliminate a dependency on shell environment within the
  # container.
  local tmp_context="<task-information>
You are creating the inital project scaffold.
The inital project information is as follows.
You have access to the CPUSET: $cpus
/workspace is the project: $proj 
Working directory: /workspace
Workspace contents of /workspace:
\`\`\`
$(ls -la $ws)
\`\`\`

$(_print_readme)

$(_print_git_context)
</task-information>

Your task is as follows:

"

  # TODO: Implement custom agent and model configuration
  # Allow users to specify custom agent definitions and model settings
  # for scaffold operations via environment variables or configuration files.
  
  # TODO: pass task via stdin

  # Execute opencode with context information
  printf '%s' "$task" | docker compose "${OPENCODE_ARGS[@]}" run --rm -T opencode \
    'exec opencode run "$@"' opencode --auto "$tmp_context" "$@"
}

# Remove existing opencode containers before starting.
# This resolves port-binding conflicts when multiple managed containers
# (labelled dev.snowdon.opencode.managed=true) cannot share the same port.
opencode:new() {
  opencode:end 

  echo "Starting fresh opencode container for project: $proj"
  opencode "$@"
}

# Stops the existing managed containers
opencode:end() {
  echo "Stopping existing opencode containers for project: $proj ($ws)"

  # Inspect managed containers and their workspace labels to warn about
  # conflicts before stopping them
  while read -r id; do
    [[ -z "$id" ]] && continue
    ws_label="$(_find_workspace $id)"
    if [[ -n "$ws_label" && "$ws_label" != "$ws" ]]; then
      echo "Stopping managed container $id (workspace: $ws_label)"
    else
      echo "Stopping managed container $id"
    fi
    docker stop "$id"
  done < <(_find_docker_managed)
}

# Force-remove all managed opencode containers.
# Unlike 'end' which gracefully stops containers, this immediately removes
# them using 'docker rm -f', which is useful when a container is stuck or
# when you need to fully clean up.
opencode:delete() {
  echo "Force-removing existing opencode containers for project: $proj ($ws)"

  while read -r id; do
    [[ -z "$id" ]] && continue
    ws_label="$(_find_workspace $id)"
    if [[ -n "$ws_label" && "$ws_label" != "$ws" ]]; then
      echo "Force-removing managed container $id (workspace: $ws_label)"
    else
      echo "Force-removing managed container $id"
    fi
    docker rm -f "$id"
  done < <(_find_docker_managed)
}

# Analyze the workspace branch changes with a non-interactive opencode run.
# Gathers the git changes inside the container (so paths are container-relative),
# then runs `opencode run --agent plan` so it analyses the code and proposes a
# plan without making any changes. Output streams to the user's terminal.
opencode:changes() {
  echo "Analyzing changes for project: $proj ($ws)"

  # Run the git analysis against the existing container when it is running,
  # otherwise a throwaway `compose run` container; either way the returned
  # paths (under /workspace) match what opencode sees. Capture the output for
  # feeding into opencode below.
  local changes
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
          git diff
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
    ')" || { echo "Failed to gather changes." >&2; exit 1; }

  echo "$changes"

  # Default task: analyse and propose a plan. Overridable by the user.
  local task="${1:-analyze the branch changes above and produce a detailed plan of action to address them.}"
  shift || true

  local prompt="<task-information>
Project: $proj
Working directory: /workspace
Branch changes:
\`\`\`
$changes
\`\`\`
</task-information>

Your task is as follows:

$task

"

  # Run a non-interactive opencode session using the built-in plan agent. The
  # plan agent restricts edit/bash to "ask", so it analyses the code and
  # proposes a plan without modifying the working tree. Output streams to the
  # terminal (interactive dispatch), reusing the running container when present.
  printf '%s' "$prompt" | _opencode_dispatch 0 \
    opencode run --agent plan --auto "$@"
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
  stop)
    echo "stop"
    echo "  Gracefully stop opencode containers, networks, and volumes for this project,"
    echo "  preserving the workspace configuration."
    echo "  Args:"
    echo "    (none)"
    ;;
  delete)
    echo "delete"
    echo "  Force-remove all managed opencode containers across workspaces using"
    echo "  'docker rm -f'. Immediately removes stuck or unwanted containers."
    echo "  Args:"
    echo "    (none)"
    ;;
  exec)
    echo "exec [command...]"
    echo "  Run a command interactively inside the already-running opencode container."
    echo "  Args:"
    echo "    command...   The command (and its args) to run inside the container."
    ;;
  end)
    echo "end"
    echo "  Stop all managed opencode containers across workspaces. This stops"
    echo "  containers labelled as managed, freeing their ports."
    echo "  Args:"
    echo "    (none)"
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
    echo "    path      Project name or './relative/path'. Optional."
    echo "    task      A description of what opencode should do"
    echo "    opencode args...   Additional arguments forwarded to the opencode CLI."
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
  printf '  %-11s %s\n' "start"    "Create the container and run an interactive opencode session"
  printf '  %-11s %s\n' "new"      "Remove conflicting containers and start a fresh session"
  printf '  %-11s %s\n' "up"       "Start the container in the background without running a process"
  printf '  %-11s %s\n' "setup"    "Run setup commands against the persisted instance"
  printf '  %-11s %s\n' "stop"     "Stop and remove the project's containers, networks, and volumes"
  printf '  %-11s %s\n' "delete"   "Force-remove all managed opencode containers across workspaces"
  printf '  %-11s %s\n' "exec"     "Run a command interactively inside the running container"
  printf '  %-11s %s\n' "end"      "Stop all managed opencode containers across workspaces"
  printf '  %-11s %s\n' "run"      "Run a one-off non-interactive task in the service"
  printf '  %-11s %s\n' "shell"    "Open an interactive shell inside the running container"
  printf '  %-11s %s\n' "scaffold" "Create a new opencode project with a fresh git repo"
  printf '  %-11s %s\n' "security" "Analyse the repository for potential security risks (not implemented)"
  printf '  %-11s %s\n' "changes"  "Analyse the branch changes and propose a plan"
  printf '  %-11s %s\n' "clone"    "Clone a git repository into a managed location (not implemented)"
  printf '  %-11s %s\n' "compose"  "Pass arguments straight through to Docker Compose"
  printf '  %-11s %s\n' "help"     "Show help; 'help <command>' for command details"
  echo
  echo "The workspace defaults to the current directory, and SD_OPENCODE points to"
  echo "the compose directory (default: \$HOME/opencode)."
  echo
  echo "Run '$0 help <command>' for details on a specific command."

  local image="devsnowdon/opencode-docker"

  if docker image inspect "$image" >/dev/null 2>&1; then
    echo
    local opencode_version
    local devcontainer_version

    opencode_version="$(
      docker image inspect "$IMAGE_URL" \
        --format '{{ index .Config.Labels "dev.snowdon.image.opencode.version" }}'
    )"

    devcontainer_version="$(
      docker image inspect "$IMAGE_URL" \
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

  if which git; then
    local tags="$(git -C "$SD_OPENCODE" describe --tags --exact-match 2>/dev/null || echo unknown)"
    local commit="$(git -C "$SD_OPENCODE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    # Get the current git location from ~/opencode
    echo "Git tag:            $tags"
    echo "Git commit:         $commit"
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
  help|-h|--help)
    if [[ "$cmd" == "help" && -n "${1:-}" ]]; then
      _opencode_help_cmd "$1"
    else
      opencode:help
    fi
    return 0
    ;;
  esac

  # Just exit if there is no docker
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running" >&2
    echo "Try something like: sudo systemctl start docker"
    exit 1
  fi

  # Get the workspace directory from arguments or current directory
  local ws_out="${1:-$(pwd)}"

  case "$cmd" in
  scaffold)
    if [ -t 0 ]; then
      # has no stdin, require task argument
      if [[ $# -lt 2 ]]; then
        echo "You did not provide a task to scaffold."
        exit 1
      fi
    fi

    # Handle scaffold command with directory validation and creation
    if [[ -z ${1+x} ]]; then
      # Check if current directory is empty for scaffold operation
      if [[ -n $(find "$ws_out" -mindepth 1 -print -quit) ]]; then
        echo "$ws_out is not empty, scaffold failed" 
        exit 1
      fi
    else
      # Process the provided project name
      local name=$1

      # If the name starts with ./ treat it as relative to the current directory
      # instead of under the SD_REPO_HOME root.
      if [[ "$name" == ./ ]]; then
        # "./" alone means the current directory itself
        ws_out="$(pwd)"
      elif [[ "$name" == ./* ]]; then
        name="${name#./}"
        ws_out="$(pwd)/$name"
      elif [[ "$name" == /* ]]; then
        ## if absolute
        ws_out="$name"
      else
        ws_out="${SD_REPO_HOME:-/home/$USER/repos}/$name"
      fi

      local tmp_ws_out="$ws_out"

      if [[ -d "$name" ]]; then
        # Check if the directory is empty
        if [[ -n $(find "$name" -mindepth 1 -print -quit) ]]; then
          echo "Exiting because of existing non-empty directory: $name"
          exit 1
        else
          echo "Using existing empty directory: $name"
        fi

        # Convert relative path to absolute path
        ws_out=$(realpath -- "$name")
      elif [[ -e "$name" || -L "$name" ]]; then
        # Handle case where path exists but is not a directory
        echo "Path already exists but is not a directory: $name" >&2
        exit 1
      elif [[ -e "$tmp_ws_out" || -L "$tmp_ws_out" ]]; then
        # Handle case where path exists but is not a directory
        echo "Path already exists but is not a directory: $tmp_ws_out" >&2
        exit 1
      elif [[ -d "$tmp_ws_out" ]]; then
        # Check if temporary workspace directory is empty
        if [[ -n $(find "$tmp_ws_out" -mindepth 1 -print -quit) ]]; then
            echo "$tmp_ws_out is not empty; scaffold failed" >&2
            exit 1
        fi

        echo "Using existing empty directory: $tmp_ws_out"
        ws_out=$(realpath -- "$tmp_ws_out")
      else
        # if the first is the path, and the second is the task
        echo "Creating $tmp_ws_out"
        mkdir -p -- "$tmp_ws_out" || exit 1
        ws_out=$(realpath -- "$tmp_ws_out")
      fi
    fi
    ;;
  esac

  # Validate the workspace directory exists and is accessible
  if ws_out="$(cd "$ws_out" 2>/dev/null && pwd)"; then
    shift || true
  else
    ws_out="$(pwd)"
  fi

  local ws="$ws_out"

  # Set up compose directory and project name
  local compose_dir="${SD_OPENCODE:-$HOME/opencode}"
  local proj="$(basename "$ws")"  

  # Display configuration information
  echo "Using opencode workspace: $ws"
  echo "Compose project: $proj"
  
  # Dispatch to the appropriate command handler
  case "$cmd" in
  stop)
    _opencode_ctx opencode:stop "$ws" "$proj" "$@"
    ;;
  start)
    _opencode_ctx opencode "$ws" "$proj" "$@"
    ;;
  exec)
    _opencode_ctx opencode:exec "$ws" "$proj" "$@"
    ;;
  compose)
    _opencode_ctx opencode:compose "$ws" "$proj" "$@"
    ;;
  shell)
    _opencode_ctx opencode:exec "$ws" "$proj" sh "$@"
    ;;
  up)
    # Start containers without running processes
    _opencode_ctx opencode:up "$ws" "$proj" "$@"
    ;;
  scaffold)
    _opencode_ctx opencode:scaffold "$ws" "$proj" "$@"
    ;;
  setup)
    # Run setup commands on an persisted instance
    _opencode_ctx opencode:setup "$ws" "$proj" "$@"
    ;;
  run)
    # Run tasks (e.g. 'npm install' or 'go build') in the opencode container
    _opencode_ctx opencode:run "$ws" "$proj" "$@"
    ;;
  new)
    # Remove existing containers before starting a fresh instance
    _opencode_ctx opencode:new "$ws" "$proj" "$@"
    ;;
  end)
    opencode:end "$ws" "$proj" "$@"
    ;;
  delete)
    opencode:delete "$ws" "$proj" "$@"
    ;;
  changes)
    # Analyze branch changes for the workspace
    _opencode_ctx opencode:changes "$ws" "$proj" "$@"
    ;;
  security)
    # TODO: Implement command to analyze repository security
    # Should read code files and check for executable commands in normal usage
    # For example, checking for npm pre-install scripts or other potential risks
    echo "command not implemented"
    ;;
  clone)
    # TODO: Implement commadn to retrieve a git repository and clone it into a location
    # clone --check runs security, then perform come action or check if it already exists
    # and preform some action
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
