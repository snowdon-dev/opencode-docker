#!/bin/bash

tmp_compose_dir=""
tmp_compose_file=""

# Cleanup temporary files on script exit
cleanup() {
  if [[ -n "$tmp_compose_dir" && -d "$tmp_compose_dir" ]]; then
    rm -rf -- "$tmp_compose_dir"
  fi
}

# Set traps for proper cleanup and signal handling
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

  # Add network configuration if OPENCODE_NETWORK environment variable is set
  if [[ -n "${OPENCODE_NETWORK:-}" ]]; then
    args_out+=(-f "$compose_dir/docker-compose.network.yml")
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
  while IFS= read -r -d '' git_dir; do
      git_dirs+=("$git_dir")
      echo "read-only locking dir: $git_dir"
  done < <(find "$ws_out" -type d -name .git -print0)

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
      } > "$tmp_compose_file"

      args_out+=(-f "$tmp_compose_file")
  fi
  
  # Display CPU resource allocation if configured
  if [ -n "$OPENCODE_CPUSET" ]; then
   echo "Using CPUSET: $OPENCODE_CPUSET"
  fi
}

# Prepares the opencode environment by resolving workspace paths.
_opencode_prepare() {
  # Use the provided target directory, falling back to current directory
  local target="${1:-.}"

  # Reference parameters for output values
  local -n ws_out="$2"
  local -n proj_out="$3"

  # Resolve the absolute path of the workspace directory
  if ! ws_out="$(cd "$target" 2>/dev/null && pwd)"; then
    echo "Error: Workspace directory '$target' does not exist." >&2
    return 1
  fi

  # Set up compose directory and project name
  local compose_dir="${SD_OPENCODE:-$HOME/opencode}"
  proj_out="$(basename "$ws_out")"  
}

# Main function to start and run opencode in a Docker container
# This function creates and executes the opencode container with proper
# workspace configuration and environment isolation.
opencode() {
  local target_dir="$1"
  shift

  # Initialize local variables for function scope
  local ws proj
  local -a args=()
  _opencode_prepare "$target_dir" ws proj || return 1
  _opencode_args_prepare "$ws" "$proj" args || return 1

  # Display configuration information
  echo "Using opencode workspace: $ws"
  echo "Compose project: $proj"
  [[ -n "${OPENCODE_NETWORK:-}" ]] && echo "Using network: $OPENCODE_NETWORK"

  # Execute Docker commands in a subshell to isolate environment variables
  (
    cd "$ws" || exit 1

    # Export environment variables for Docker Compose
    export WORKSPACE="$ws"
    [[ -n "${OPENCODE_NETWORK:-}" ]] && export OPENCODE_NETWORK="$OPENCODE_NETWORK"

    # Start the opencode container and execute the command
    docker compose "${args[@]}" up -d opencode
    docker compose "${args[@]}" exec -w /workspace opencode opencode "$@"

    # TODO: Implement container conflict detection
    # If port bindings do not allow multiple running containers, filter by label
    # dev.snowdon.opencode.managed to detect existing instances. If found, retrieve
    # the workspace path from label dev.snowdon.opencode.workspace and prompt user
    # to stop the existing container before creating a new one.
    # Example message: "Container already running for workspace /path/to/workspace.
    # Run 'opencode:stop /path/to/workspace' first, or use 'opencode:new' to
    # automatically remove the existing container."

    # Verify container status after execution
    container_id="$(docker compose "${args[@]}" ps -q -a opencode)"
    if [[ -z "$container_id" ]]; then
      echo "The container removed: $container_id"
      exit 1
    else
      echo "ended container_id: $container_id"
    fi
  )
}

# Execute commands in an existing opencode container
# This function runs interactive commands within a running container
# without creating a new container instance.
opencode:exec() {
  local target_dir="$1"
  shift
  local ws proj 
  local -a args
  _opencode_prepare "$target_dir" ws proj || return 1
  _opencode_args_prepare "$ws" "$proj" args || return 1

  echo "Executing in opencode project: $proj ($ws)"

  (
    cd "$ws" || exit 1

    export WORKSPACE="$ws"
    [[ -n "${OPENCODE_NETWORK:-}" ]] && export OPENCODE_NETWORK="$OPENCODE_NETWORK"

    # TODO: Ensure container is running before executing commands
    # If the container is not started, automatically start it first.
    # This may require using 'docker compose up -d' with --force-recreate
    # to handle cases where the container was stopped or crashed.

    # Execute command interactively in the running container
    docker compose "${args[@]}" exec -it opencode "$@"
  )
}

# Execute arbitrary Docker Compose commands for the opencode project
# This function provides direct access to Docker Compose functionality
# for advanced container management operations.
opencode:compose() {
  local target_dir="$1"
  shift
  local ws proj 
  local -a args
  _opencode_prepare ws proj || return 1
  _opencode_args_prepare "$ws" "$proj" args || return 1

  echo "Running Docker Compose for project: $proj ($ws)"

  (
    cd "$ws" || exit 1

    export WORKSPACE="$ws"
    [[ -n "${OPENCODE_NETWORK:-}" ]] && export OPENCODE_NETWORK="$OPENCODE_NETWORK"

    # Pass all arguments directly to Docker Compose
    docker compose "${args[@]}" "$@"
  )
}

# Stop and remove all opencode containers for the specified project
# This function gracefully shuts down the container and cleans up resources
# while preserving the workspace configuration.
opencode:stop() {
  local target_dir="$1"
  shift
  local ws proj
  local -a args
  _opencode_prepare "$target_dir" ws proj || return 1
  _opencode_args_prepare "$target_dir" "$ws" "$proj" || return 1

  echo "Stopping opencode project: $proj ($ws)"

  (
    cd "$ws" || exit 1

    export WORKSPACE="$ws"
    [[ -n "${OPENCODE_NETWORK:-}" ]] && export OPENCODE_NETWORK="$OPENCODE_NETWORK";

    # Stop and remove containers, networks, and volumes
    docker compose "${args[@]}" down
  )
}

# Initialize a git repository in the specified directory
# This function creates a new git repository with an initial commit
# containing a README file. Used during the scaffold command.
setup_git_dir() {
  if ! which git > /dev/null; then
    return
  fi

  # Initialize git repository and create initial commit
  git init # assumed directory is empty
  echo "# $1" > README.md
  git add README.md
  git commit -m "Initial commit."
}

print_git_context() {
  if ! which git > /dev/null; then
    return
  fi
  echo "\nAdditional project context:

The author details for this task:
Name: $(git config --global user.name)
Email: $(git config --global user.email)

git log --stat:
\`\`\`
$(git log --stat | cat)
\`\`\`"
}

# Create a new opencode project scaffold with git initialization
# This function sets up a new project workspace with proper configuration
# and launches the opencode runner to begin development.
opencode:scaffold() {
  local target_dir="$1"
  shift

  # Initialize project variables and prepare environment
  # NOTE: Project name is derived from basename only, which may cause naming
  # conflicts when different directories share the same final component.
  # For example: /home/user/repos/gists/one and /home/user/repos/projects/one
  # both become project name "one". A future improvement should use a sanitized
  # version of the full relative path to ensure uniqueness while maintaining
  # Docker Compose naming compatibility (lowercase, hyphens only).
  local ws proj 
  _opencode_prepare "$target_dir" ws proj || return 1

  echo "Running on opencode project: $proj ($ws)"
  
  # Configure CPU resources for the container
  local cpus="${OPENCODE_CPUSET:-2-3}"
  (
    cd "$ws" || exit 1

    # Initialize git repository in the workspace
    setup_git_dir "$proj"

    local -a args
    _opencode_args_prepare "$ws" "$proj" args || return 1
  
    # Build context information for the opencode runner. Reduces execution
    # overhead and could eliminate a dependency on shell environment within the
    # container.
    local tmp_context="<task-information>
You are creating the inital project scaffold. The inital project information is as follows.
You have access to the CPUSET: $cpus
Project name: $proj
Working directory: /workspace
Workspace contents of /workspace:
\`\`\`
$(ls -la $ws)
\`\`\`

README.md:
\`\`\`
$(cat README.md)
\`\`\`
$(print_git_context)
</task-information>

Your task is as follows:

"

    # Configure and launch the opencode runner in Docker
    export WORKSPACE="$ws"
    [[ -n "${OPENCODE_NETWORK:-}" ]] && export OPENCODE_NETWORK="$OPENCODE_NETWORK";

    # TODO: Implement custom agent and model configuration
    # Allow users to specify custom agent definitions and model settings
    # for scaffold operations via environment variables or configuration files.

    # Execute opencode with context information
    docker compose "${args[@]}" run --rm opencode \
      'exec opencode run "$@"' opencode "$tmp_context" "$@"
  )
}

# Main entry point for the opencode launcher script
# This function parses command-line arguments and dispatches to the
# appropriate handler function based on the specified command.
main() {
  local cmd="${1:-}"
  shift || true

  # Get the workspace directory from arguments or current directory
  local ws_out="${1:-$(pwd)}"

  case "$cmd" in
  scaffold)
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
      local repo_home=="$(SD_REPO_HOME:-/home/$USER/repos/$name)"
      local tmp_ws_out="$repo_home"

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

      elif [[ -d "$tmp_ws_out" ]]; then
          # Check if temporary workspace directory is empty
          if [[ -n $(find "$tmp_ws_out" -mindepth 1 -print -quit) ]]; then
              echo "$tmp_ws_out is not empty; scaffold failed" >&2
              exit 1
          fi

          echo "Using existing empty directory: $tmp_ws_out"
          ws_out=$(realpath -- "$tmp_ws_out")

      else
          # Create new directory for the project
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
  
  # Dispatch to the appropriate command handler
  case "$cmd" in
  stop)
    opencode:stop "$ws_out" "$@"
    ;;
  start)
    opencode "$ws_out" "$@"
    ;;
  exec)
    opencode:exec "$ws_out" "$@"
    ;;
  compose)
    opencode:compose "$ws_out" "$@"
    ;;
  up)
    echo "up command not implemented"
    # TODO: Implement command to start containers without running processes
    ;;
  scaffold)
    opencode:scaffold "$ws_out" "$@"
    ;;
  setup)
    # TODO: Implement command to run on existing persisted instance
    # Should call start first, then execute non-interactive commands
    # before returning to the user shell
    echo "setup command not implemented"
    ;;
  run)
    # TODO: Implement command to run tasks in opencode container
    # Should support running commands like 'npm install' or 'go build'
    echo "run command not implemented"
    ;;
  new)
    # TODO: Implement command to remove existing containers before starting
    # Should filter containers by label dev.snowdon.opencode.managed = true
    # and remove them before running normal opencode
    echo "new command not implemented"
    ;;
  changes)
    # TODO: Implement command to analyze branch changes
    echo "command not implemented"
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
  *)
    echo "Unknown command: $cmd" >&2
    echo "Usage: $0 [stop | start] [args...]" >&2
    return 1
    ;;
  esac
}

# Execute the main function with all provided arguments
main "$@"
