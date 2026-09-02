#!/bin/bash
# Test module for scripts/launcher.sh.
#
# Runs every launcher subcommand against a mocked `docker` binary so the actual
# docker invocations are printed and asserted WITHOUT anything being executed.
# This lets you see exactly which docker commands the launcher would run for a
# given subcommand, and verifies they are correct.
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

# Fresh, isolated sandbox per test: a fake compose dir the launcher reads its
# docker-compose files from, and a workspace with a .git dir so the launcher's
# read-only .git mount logic is exercised.
make_sandbox() {
  SD="$SCRIPT_DIR/.tmp/sandbox"
  rm -rf "$SD"
  mkdir -p "$SD/compose" "$SD/ws/.git"
  echo 'services: { opencode: {} }' >"$SD/compose/docker-compose.yml"
}

# Run the launcher, capturing both the launcher's stdout/err and the mock
# docker log. Nondeterministic temp paths (docker-compose.git.yml) are
# normalised so assertions are stable.
#   run_launcher <path-to-env-dotfile> <subcommand> [args...]
# Globals written: LAUNCH_OUT (launcher+vars), DOCKER_LOG (normalised docker lines)
run_launcher() {
  local dotfile="$1"
  local cmd="$2"
  shift 2

  export PATH="$MOCKBIN:$PATH"
  export OPENCODE_TEST_DOCKER_LOG="$SD/docker.log"
  export SD_OPENCODE="$SD/compose"
  export SD_REPO_HOME="$SD/repos"
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

  # Keep only the launcher's own output lines, dropping docker mock echoes.
  LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:' )"

  # Normalise the docker log: collapse the nondeterministic temp mount file.
  DOCKER_LOG="$(sed -E \
    -e 's#-f [^ ]*docker-compose\.git\.yml#-f <tmp>/docker-compose.git.yml#g' \
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

# --- individual tests ---------------------------------------------------

t_up() {
  run_launcher /dev/null up
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml up -d opencode"
}

t_stop() {
  run_launcher /dev/null stop
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml down"
}

t_exec() {
  run_launcher /dev/null exec sh -c 'echo hi'
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml up -d --no-recreate opencode
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml exec -it opencode sh -c echo hi"
}

t_run() {
  # Container already running -> task runs inside it via exec.
  run_launcher /dev/null run "npm install"
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml ps -q opencode
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml exec -T -w /workspace opencode npm install"
}

t_run_nocontainer() {
  # No running container -> throwaway `compose run` (no ports), removed on exit.
  OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml ps -q opencode
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml run --rm -w /workspace opencode npm install"
}

t_setup() {
  run_launcher /dev/null setup "npm install"
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml ps -q opencode
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml exec -T -w /workspace opencode npm install"
}

t_compose() {
  run_launcher /dev/null compose config --services
  assert_docker "docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml config --services"
}

t_start() {
  run_launcher /dev/null start --model gpt
  assert_docker "docker ps -q --filter label=dev.snowdon.opencode.managed=true
docker inspect --format {{index .Config.Labels \"dev.snowdon.opencode.workspace\"}} c1
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml up -d opencode
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml exec -w /workspace opencode opencode --model gpt
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml ps -q -a opencode"
}

t_start_conflict() {
  # A managed container for a *different* workspace is already running. The
  # fixed port binding cannot be shared, so `start` must abort before creating
  # a new container, telling the user how to free the workspace.
  OPENCODE_TEST_CONFLICT=1 run_launcher /dev/null start --model gpt
  if grep -Fq "Container already running for workspace /workspace/other." <<<"$LAUNCH_OUT" \
     && grep -Fq "opencode:stop /workspace/other" <<<"$LAUNCH_OUT"; then
    PASS=$((PASS+1)); echo "  ok: conflict message printed"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT:msg")
    echo "  FAIL: no conflict message"
    printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
  fi
  # Must NOT have attempted to create the container.
  assert_docker "docker ps -q --filter label=dev.snowdon.opencode.managed=true
docker inspect --format {{index .Config.Labels \"dev.snowdon.opencode.workspace\"}} c1"
}

t_new() {
  run_launcher /dev/null new "do something"
  assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
  assert_docker_contains "docker rm -f c1"
  assert_docker_contains "exec -w /workspace opencode opencode do something"
}

t_changes() {
  run_launcher /dev/null changes
  assert_docker_contains "ps -q opencode"
  assert_docker_contains "exec -T -w /workspace opencode sh -c"
  # `changes` should always run a non-interactive opencode run with the plan
  # agent (no -T, so it streams to the terminal) without making changes.
  assert_docker_contains "exec -w /workspace opencode opencode run --agent plan --auto"
}

t_changes_nocontainer() {
  # No running container -> both steps use a throwaway `compose run`.
  OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null changes
  assert_docker_contains "ps -q opencode"
  assert_docker_contains "run --rm -w /workspace opencode sh -c"
  assert_docker_contains "run --rm -w /workspace opencode opencode run --agent plan --auto"
}

t_scaffold() {
  # scaffold expects an empty workspace; the sandbox ws is not empty, so use a
  # named new project in the repo home instead (mirrors main()'s scaffold path).
  local name="proj-scaffold"
  local repo_home="$SD/repos"
  mkdir -p "$repo_home"
  run_launcher /dev/null scaffold "$name"
  # scaffold => setup_git_dir + docker compose run
  assert_docker_contains "run --rm opencode"
  assert_docker_contains "opencode --auto"
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
