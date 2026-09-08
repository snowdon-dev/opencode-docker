#!/bin/bash
# Test module for scripts/launcher.sh.
#
# Runs every launcher subcommand against a mocked `docker` binary (and mocked
# `curl`/`opencode`) so the actual docker invocations are printed and asserted
# WITHOUT anything being executed. This lets you see exactly which docker
# commands the launcher would run for a given subcommand, and verifies they are
# correct.
#
# Usage:
#   ./tests/run_tests.sh            # run all tests
#   ./tests/run_tests.sh <name...>  # run specific tests by name
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$ROOT_DIR/scripts/launcher.sh"
MOCKBIN="$SCRIPT_DIR/mockbin"

# --- test runner helpers -------------------------------------------------

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

# Fresh, isolated sandbox per test, kept out of the repo in /tmp: a fake
# compose dir the launcher reads its docker-compose files from, and a workspace
# with a .git dir so the launcher's read-only .git mount logic is exercised.
make_sandbox() {
  SD="$(mktemp -d "${TMPDIR:-/tmp}/opencode-tests.XXXXXX")"
  mkdir -p "$SD/compose" "$SD/compose/compose-vol" "$SD/compose/compose-net" "$SD/ws/.git"
  echo 'services: { opencode: {} }' >"$SD/compose/docker-compose.yml"
  # Compose base args used in every expected command (git mount is pruned by
  # mktemp normalisation).
  CBASE="docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml"
  # Every launcher execution begins with the docker daemon reachability check.
  DINFO="docker info"
}

# Run the launcher, capturing both the launcher's stdout/err and the mock
# docker log. Nondeterministic temp paths (docker-compose.git.yml) are
# normalised so assertions are stable.
#   run_launcher <path-to-env-dotfile> <subcommand> [args...]
# Globals written: LAUNCH_OUT (launcher+vars), LAUNCH_RC (exit code),
# DOCKER_LOG (normalised docker lines)
run_launcher() {
  local dotfile="$1"
  local cmd="$2"
  shift 2

  export PATH="$MOCKBIN:$PATH"
  export OPENCODE_TEST_DOCKER_LOG="$SD/docker.log"
  export SD_OPENCODE="$SD/compose"
  export SD_REPO_HOME="$SD/repos"
  export SD_YOLO=true
  : >"$OPENCODE_TEST_DOCKER_LOG"

  # Optional env overrides
  if [[ -f "$dotfile" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$dotfile"
    set +a
  fi

  local out
  out="$(cd "$SD/ws" && bash "$LAUNCHER" "$cmd" "$@" 2>&1)"
  LAUNCH_RC=$?

  # Keep only the launcher's own output lines, dropping mock echoes.
  LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:' )"

  # Normalise the docker log: collapse the nondeterministic temp mount file
  # and the scaffold container pid.
  DOCKER_LOG="$(sed -E \
    -e 's#-f [^ ]*docker-compose\.git\.yml#-f <tmp>/docker-compose.git.yml#g' \
    -e 's/oc-scaffold-[0-9]+/oc-scaffold-<pid>/g' \
    -e 's/oc-changes-[0-9]+/oc-changes-<pid>/g' \
    "$OPENCODE_TEST_DOCKER_LOG")"
}

# Assert that docker was called (in order) exactly the given commands.
#   assert_docker <expected-multiline-string>
assert_docker() {
  local expected="$1"
  if [[ "$DOCKER_LOG" == "$expected" ]]; then
    PASS=$((PASS+1))
    echo "  ok: docker commands match"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:docker")
    echo "  FAIL: docker commands differ"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$DOCKER_LOG") | sed 's/^/    /'
  fi
}

# Assert that the docker log contains at least the given line (in order).
assert_docker_contains() {
  local needle="$1"
  if grep -Fq "$needle" <<<"$DOCKER_LOG"; then
    PASS=$((PASS+1))
    echo "  ok: docker log contains: $needle"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:contains:$needle")
    echo "  FAIL: docker log does not contain: $needle"
    echo "  --- docker log ---"
    printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
  fi
}

# Assert that the launcher's own output (stdout/stderr) contains the given text.
assert_launcher_output_contains() {
  local needle="$1"
  if grep -Fq "$needle" <<<"$LAUNCH_OUT"; then
    PASS=$((PASS+1))
    echo "  ok: launcher output contains: $needle"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:output:$needle")
    echo "  FAIL: launcher output does not contain: $needle"
    echo "  --- launcher output ---"
    printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
  fi
}

# --- individual tests ---------------------------------------------------

t_up() {
  run_launcher /dev/null up
  assert_docker "$DINFO
$CBASE up -d opencode"
}

t_stop() {
  # stop: dispatched before workspace resolution, discovers managed containers
  # via _find_docker_managed (all workspaces by default), stops each.
  run_launcher /dev/null stop
  assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "docker stop c1"
  assert_launcher_output_contains "Stopping existing opencode containers"
}

t_exec() {
  # exec calls opencode:exec directly (ensure_up is commented out in the
  # launcher), which runs docker compose exec -it.
  run_launcher /dev/null exec sh -c 'echo hi'
  assert_docker "$DINFO
$CBASE exec -it opencode sh -c echo hi"
  assert_launcher_output_contains "Executing in opencode project: ws"
}

t_run() {
  # Container already running -> task runs inside it via exec.
  run_launcher /dev/null run "npm install"
  assert_docker "$DINFO
$CBASE ps -q opencode
$CBASE exec -T -w /workspace opencode npm install"
  assert_launcher_output_contains "Running in opencode project: ws"
}

t_run_nocontainer() {
  # No running container -> throwaway `compose run` (no ports), removed on exit.
  # Uses --entrypoint /bin/sh so the task args are exec'd by a real shell.
  OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
  assert_docker "$DINFO
$CBASE ps -q opencode
$CBASE run --rm -w /workspace --entrypoint /bin/sh opencode -c exec \"\$@\" sh npm install"
}

t_setup() {
  # setup calls _opencode_ensure_up (no-recreate) first, then _opencode_dispatch.
  run_launcher /dev/null setup "npm install"
  assert_docker "$DINFO
$CBASE up -d --no-recreate opencode
$CBASE ps -q opencode
$CBASE exec -T -w /workspace opencode npm install"
  assert_launcher_output_contains "Setting up opencode project: ws"
}

t_setup_build_fail() {
  # setup when `compose up` fails (e.g. build failure) must abort and NOT run
  # the dispatch command.
  local rc=0
  OPENCODE_TEST_BUILD_FAIL=1 run_launcher /dev/null setup "npm install"
  rc=$LAUNCH_RC
  assert_launcher_output_contains "Failed to start the opencode container"
  if [[ "$rc" -eq 0 ]]; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:exit")
    echo "  FAIL: setup did not exit non-zero after build failure"
  else
    PASS=$((PASS+1)); echo "  ok: setup exits non-zero after build failure"
  fi
  # Must NOT have attempted the dispatch (no ps/exec) after the failed up.
  if grep -Fq "ps -q opencode" <<<"$DOCKER_LOG"; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:no_dispatch")
    echo "  FAIL: dispatch ran despite build failure"
  else
    PASS=$((PASS+1)); echo "  ok: no dispatch after build failure"
  fi
}

t_compose() {
  run_launcher /dev/null compose config --services
  assert_docker "$DINFO
$CBASE config --services"
  assert_launcher_output_contains "Running Docker Compose for project: ws"
}

t_compose_no_readonly() {
  # SD_READ_ONLY=false disables the read-only .git override: the generated
  # docker-compose.git.yml must NOT be merged into the docker compose command.
  # run_launcher sources the dotfile in the parent shell, so unset it again to
  # avoid leaking into later tests.
  local dotfile="$SD/readonly.env"
  echo 'SD_READ_ONLY=false' >"$dotfile"
  run_launcher "$dotfile" compose config --services
  assert_docker "$DINFO
docker compose -p ws -f $SD/compose/docker-compose.yml config --services"
  assert_launcher_output_contains "Running Docker Compose for project: ws"
  unset SD_READ_ONLY
}

t_cache_all() {
  # OPENCODE_CACHE=all mounts every toolchain cache via docker-compose.cache.yml.
  echo 'services: { opencode: {} }' >"$SD/compose/compose-vol/docker-compose.cache.yml"
  local dotfile="$SD/cache.env"
  echo 'OPENCODE_CACHE=all' >"$dotfile"
  run_launcher "$dotfile" compose config --services
  assert_docker "$DINFO
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose-vol/docker-compose.cache.yml -f <tmp>/docker-compose.git.yml config --services"
  unset OPENCODE_CACHE
}

t_cache_ids() {
  # Space-separated ids (case-insensitive) add only those override files.
  echo 'services: { opencode: {} }' >"$SD/compose/compose-vol/docker-compose.go.yml"
  echo 'services: { opencode: {} }' >"$SD/compose/compose-vol/docker-compose.python.yml"
  local dotfile="$SD/cache.env"
  echo 'OPENCODE_CACHE="Go PYTHON"' >"$dotfile"
  run_launcher "$dotfile" compose config --services
  assert_docker "$DINFO
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose-vol/docker-compose.go.yml -f $SD/compose/compose-vol/docker-compose.python.yml -f <tmp>/docker-compose.git.yml config --services"
  unset OPENCODE_CACHE
}

t_cache_false() {
  # OPENCODE_CACHE=false mounts no toolchain caches.
  local dotfile="$SD/cache.env"
  echo 'OPENCODE_CACHE=false' >"$dotfile"
  run_launcher "$dotfile" compose config --services
  assert_docker "$DINFO
$CBASE config --services"
  assert_launcher_output_contains "Running container without toolchain cache"
  unset OPENCODE_CACHE
}

t_cache_unknown() {
  # An unknown cache id aborts with a clear error listing valid ids.
  local dotfile="$SD/cache.env"
  echo 'OPENCODE_CACHE=bogus' >"$dotfile"
  run_launcher "$dotfile" compose config --services
  assert_launcher_output_contains "Error: unknown toolchain cache id: bogus (valid ids: all, go, node, python, rust)"
  if [[ "$LAUNCH_RC" -eq 0 ]]; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:exit")
    echo "  FAIL: unknown cache id did not exit non-zero"
  else
    PASS=$((PASS+1)); echo "  ok: unknown cache id exits non-zero"
  fi
  unset OPENCODE_CACHE
}

t_start() {
  # start: conflict check -> ensure_up (no-recreate) -> backend health (mocked
  # curl returns ok, so serve is skipped) -> attach via mocked opencode -> ps.
  run_launcher /dev/null start --model gpt
  assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "$CBASE up -d --no-recreate opencode"
  assert_docker_contains "opencode attach http://127.0.0.1:4096 --model gpt"
  assert_docker_contains "$CBASE ps -q -a opencode"
  assert_launcher_output_contains "Backend ready. Attaching..."
}

t_start_conflict() {
  # A managed container for a *different* workspace is already running. The
  # fixed port binding cannot be shared, so `start` aborts before creating
  # a new container, telling the user how to free the workspace.
  OPENCODE_TEST_CONFLICT=1 run_launcher /dev/null start --model gpt
  assert_launcher_output_contains "Container already running for workspace /workspace/other."
  assert_launcher_output_contains "opencode:down /workspace/other"
  # Must NOT have attempted to create the container (no compose up/exec/attach).
  if grep -Fq "up -d" <<<"$DOCKER_LOG"; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:should_not_create")
    echo "  FAIL: compose up was called despite conflict"
  else
    PASS=$((PASS+1)); echo "  ok: no container creation on conflict"
  fi
}

t_new() {
  # new: opencode:stop (find + stop all managed containers) then opencode (full
  # start sequence: conflict check, ensure_up, attach, verify).
  run_launcher /dev/null new "do something"
  assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "docker stop c1"
  assert_docker_contains "$CBASE up -d --no-recreate opencode"
  assert_docker_contains "opencode attach http://127.0.0.1:4096 do something"
  assert_launcher_output_contains "Starting fresh opencode container"
}

t_start_build_fail() {
  # start when `compose up` fails (e.g. build failure) must abort rather than
  # proceeding to the backend health check and attach.
  local rc=0
  OPENCODE_TEST_BUILD_FAIL=1 run_launcher /dev/null start --model gpt
  rc=$LAUNCH_RC
  assert_launcher_output_contains "Failed to start the opencode container"
  if [[ "$rc" -eq 0 ]]; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:exit")
    echo "  FAIL: start did not exit non-zero after build failure"
  else
    PASS=$((PASS+1)); echo "  ok: start exits non-zero after build failure"
  fi
  # Must NOT have attempted the backend health check or attach (no exec/attach).
  if grep -Fq "opencode attach" <<<"$DOCKER_LOG"; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:no_attach")
    echo "  FAIL: attach ran despite build failure"
  else
    PASS=$((PASS+1)); echo "  ok: no attach after build failure"
  fi
}

t_shell() {
  # shell is a convenience alias for 'exec sh ...' in main().
  run_launcher /dev/null shell -c 'echo hi'
  assert_docker "$DINFO
$CBASE exec -it opencode sh -c echo hi"
}

t_down() {
  # down: compose down clears the project's networks/volumes, then stop is
  # called workspace-scoped to catch any remaining managed containers (TUI).
  run_launcher /dev/null down
  assert_docker_contains "$CBASE down"
  assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "docker stop c1"
  assert_launcher_output_contains "Stopping opencode project: ws"
}

t_delete() {
  # delete: dispatched before workspace resolution, discovers managed containers
  # via _find_docker_managed --stopped (includes -a for stopped containers),
  # force-removes each.
  run_launcher /dev/null delete
  assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "docker rm -f c1"
  assert_launcher_output_contains "Force-removing all opencode containers"
}

t_ls() {
  # ls: discovers managed containers (including stopped) and prints them in a
  # ps-style table built from per-container inspect records. The record format
  # must separate fields with a Go string literal {{"\t"}} (docker inspect does
  # not interpolate a raw \t, unlike docker ps).
  run_launcher /dev/null ls
  assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains '{{"\t"}}'
  assert_launcher_output_contains "CONTAINER ID"
  assert_launcher_output_contains "STATUS"
  assert_launcher_output_contains "WORKSPACE"
  assert_launcher_output_contains "PROJECT"
  assert_launcher_output_contains "c1"
  assert_launcher_output_contains "running"
  assert_launcher_output_contains "main"
}

t_ls_quiet() {
  # ls --quiet prints only the short container ids, one per line.
  run_launcher /dev/null ls --quiet
  if [[ "$LAUNCH_OUT" == "c1" ]]; then
    PASS=$((PASS+1)); echo "  ok: ls --quiet prints only container ids"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:quiet")
    echo "  FAIL: expected output 'c1', got:"
    printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
  fi
}

t_ls_scope() {
  # A workspace argument scopes the listing with an extra label filter.
  run_launcher /dev/null ls "$SD/ws"
  assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
  assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
}

t_ls_no_containers() {
  # With no managed containers, ls prints a helpful message (and nothing with
  # --quiet).
  OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null ls
  assert_launcher_output_contains "No managed opencode containers"
}

t_ls_all() {
  # --all also lists oneoff (throwaway 'compose run') containers: the docker ps
  # call must use -a and include no oneoff filtering.
  run_launcher /dev/null ls --all
  assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
  assert_launcher_output_contains "CONTAINER ID"
}

t_changes() {
  # changes with a running container: git analysis via exec -T, then opencode
  # run --agent plan --auto via exec -T (non-interactive).
  run_launcher /dev/null changes
  assert_docker_contains "$CBASE ps -q opencode"
  assert_docker_contains "$CBASE exec -T -w /workspace opencode sh -c"
  assert_docker_contains "$CBASE exec -T -w /workspace opencode opencode run --agent plan --auto"
  assert_launcher_output_contains "Analyzing changes for project: ws"
}

t_changes_nocontainer() {
  # No running container -> both steps use a throwaway `compose run`, via
  # --entrypoint /bin/sh so the git-analysis script and opencode are exec'd.
  OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null changes
  assert_docker_contains "$CBASE ps -q opencode"
  assert_docker_contains "$CBASE run --rm -w /workspace --entrypoint /bin/sh opencode -c exec \"\$@\" sh sh -c"
  assert_docker_contains "$CBASE run --rm -w /workspace --entrypoint /bin/sh opencode -c exec \"\$@\" sh opencode run --agent plan --auto"
}

t_scaffold() {
  # scaffold expects an empty workspace; the sandbox ws is not empty, so use a
  # named new project in the repo home (mirrors main()'s scaffold path).
  local name="proj-scaffold"
  mkdir -p "$SD/repos"
  run_launcher /dev/null scaffold "$name" "test task"
  # The one-off compose run uses the scaffold container name and --auto, then
  # the cleanup removes the container by name.
  assert_docker_contains "oc-scaffold-<pid> opencode exec"
  assert_docker_contains "opencode --auto"
  assert_docker_contains "docker rm -f -v oc-scaffold-<pid>"
  assert_launcher_output_contains "Running on opencode project: proj-scaffold"
}

t_help() {
  run_launcher /dev/null help
  assert_launcher_output_contains "opencode launcher - manage the opencode container and sessions"
  assert_launcher_output_contains "Commands:"
  for cmd in start new up setup stop delete ls exec down run shell scaffold changes compose help; do
    assert_launcher_output_contains "$cmd"
  done
}

t_help_cmd() {
  # help start prints the detailed start help.
  run_launcher /dev/null help start
  assert_launcher_output_contains "start [opencode args...]"
  assert_launcher_output_contains "(Re)create the opencode container"
}

t_help_unknown() {
  # help <unknown> returns an error to stderr.
  local out
  out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
    bash "$LAUNCHER" help nonexistent 2>&1)"
  if grep -Fq "No help available for command: nonexistent" <<<"$out"; then
    PASS=$((PASS+1)); echo "  ok: unknown help command message"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:msg")
    echo "  FAIL: expected 'No help available for command: nonexistent'"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

t_unknown_command() {
  local out
  out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
    SD_YOLO=true bash "$LAUNCHER" bogus 2>&1)"
  if grep -Fq "Unknown command: bogus" <<<"$out"; then
    PASS=$((PASS+1)); echo "  ok: unknown command message"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:msg")
    echo "  FAIL: expected 'Unknown command: bogus'"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

t_no_docker() {
  # When the docker daemon is not reachable, the launcher prints a helpful
  # message and exits 1. We use a fake docker that always fails.
  local fake_dir="$SD/fakebin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/docker" <<'FAKE'
#!/bin/bash
exit 1
FAKE
  chmod +x "$fake_dir/docker"
  local out
  out="$(cd "$SD/ws" && PATH="$fake_dir:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
    bash "$LAUNCHER" start 2>&1)"
  local rc=$?
  if [[ "$rc" -ne 0 ]] && grep -Fq "Docker daemon is not running" <<<"$out"; then
    PASS=$((PASS+1)); echo "  ok: no-docker message"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:no_docker")
    echo "  FAIL: expected exit 1 and 'Docker daemon is not running'"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# --- main ---------------------------------------------------------------

main() {
  local wanted=("$@")
  local -a selected=()

  if ((${#wanted[@]} > 0)); then
    # run the requested tests (t_<name>), preserving order
    for name in "${wanted[@]}"; do
      if declare -F "t_$name" >/dev/null; then
        selected+=("t_$name")
      else
        echo "unknown test: $name"
      fi
    done
  else
    # run every discovered t_* function, sorted
    while IFS= read -r fn; do
      selected+=("$fn")
    done < <(declare -F | awk '{print $3}' | grep '^t_' | sort)
  fi

  echo "=== opencode launcher tests ==="

  for test_fn in "${selected[@]}"; do
    make_sandbox
    CURRENT="${test_fn#t_}"
    echo
    echo "--- ${CURRENT} ---"
    "$test_fn"
    rm -rf -- "$SD"
    SD=""
  done

  echo
  echo "=== results ==="
  echo "passed: $PASS, failed: $FAIL"
  if ((FAIL > 0)); then
    echo "failed tests: ${FAILED_TESTS[*]}"
    exit 1
  fi
  exit 0
}

main "$@"
