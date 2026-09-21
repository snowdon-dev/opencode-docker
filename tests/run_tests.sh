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
    mkdir -p "$SD/compose" "$SD/compose/compose/vol" "$SD/compose/compose/net" "$SD/compose/compose/sys" "$SD/ws/.git"
    echo 'services: { opencode: {} }' >"$SD/compose/docker-compose.yml"
    # Compose base args used in every expected command (git mount is pruned by
    # mktemp normalisation).
    CBASE="docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml"
    # Every launcher execution begins with the docker daemon reachability check.
    DINFO="docker info"
    # _opencode_args_prepare probes for worktree-child containers of the workspace
    # before preparing the compose args; the fresh sandbox has none, so only the
    # discovery call itself is logged.
    CPARENTPS="docker ps -q -a --filter label=dev.snowdon.opencode.managed=true --filter label=dev.snowdon.opencode.parent=$SD/ws"
    # The workspace-scoped listing used by up/setup (opencode:list).
    CWSPS="docker ps -q -a --filter label=dev.snowdon.opencode.managed=true --filter label=dev.snowdon.opencode.workspace=$SD/ws"
    # docker inspect record produced by the launcher's _container_info helper
    # (id, status, workspace, project, oneoff, tui, parent, sentinel).
    CINFO="docker inspect --format {{.ID}}{{\"\\t\"}}{{.State.Status}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.workspace\"}}{{\"\\t\"}}{{index .Config.Labels \"com.docker.compose.project\"}}{{\"\\t\"}}{{index .Config.Labels \"com.docker.compose.oneoff\"}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.tui\"}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.parent\"}}{{\"\\t\"}}. c1"
    # `opencode:list` probes a running main container for any opencode process
    # (serve, run, attach, ...) so it can render STATUS as "idle" when none is
    # up (mock exits 1 when OPENCODE_TEST_NO_SERVE=1).
    CPGREP="docker exec c1 pgrep -f opencode"
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
    out="$(cd "$SD/ws" && bash "$LAUNCHER" "$cmd" "$@" </dev/null 2>&1)"
    LAUNCH_RC=$?

    # Keep only the launcher's own output lines, dropping mock echoes.
    LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:')"

    # Normalise the docker log: collapse the nondeterministic temp mount file
    # and the scaffold container pid.
    DOCKER_LOG="$(sed -E \
        -e 's#-f [^ ]*docker-compose\.git\.yml#-f <tmp>/docker-compose.git.yml#g' \
        -e 's/oc-scaffold-[0-9]+/oc-scaffold-<pid>/g' \
        -e 's/oc-changes-[0-9]+/oc-changes-<pid>/g' \
        -e 's/oc-bg-[0-9]+/oc-bg-<pid>/g' \
        "$OPENCODE_TEST_DOCKER_LOG")"
}

# Assert that docker was called (in order) exactly the given commands.
#   assert_docker <expected-multiline-string>
assert_docker() {
    local expected="$1"
    if [[ "$DOCKER_LOG" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: docker commands match"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:docker")
        echo "  FAIL: docker commands differ"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$DOCKER_LOG") | sed 's/^/    /'
    fi
}

# Assert that the docker log contains at least the given line (in order).
assert_docker_contains() {
    local needle="$1"
    if grep -Fq "$needle" <<<"$DOCKER_LOG"; then
        PASS=$((PASS + 1))
        echo "  ok: docker log contains: $needle"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:contains:$needle")
        echo "  FAIL: docker log does not contain: $needle"
        echo "  --- docker log ---"
        printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
    fi
}

# Assert that the launcher's own output (stdout/stderr) contains the given text.
assert_launcher_output_contains() {
    local needle="$1"
    if grep -Fq "$needle" <<<"$LAUNCH_OUT"; then
        PASS=$((PASS + 1))
        echo "  ok: launcher output contains: $needle"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:output:$needle")
        echo "  FAIL: launcher output does not contain: $needle"
        echo "  --- launcher output ---"
        printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
    fi
}

# --- individual tests ---------------------------------------------------

t_up() {
    # up: worktree-child discovery during args preparation, then compose up, then
    # opencode:list (workspace-scoped + parent lookup) to show the container.
    run_launcher /dev/null up
    assert_docker "$DINFO
$CPARENTPS
$CBASE up -d opencode
$CWSPS
$CINFO
$CPARENTPS
$CINFO
$CPGREP"
}

t_stop() {
    # stop: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers (all workspaces by default), stops each.
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
$CPARENTPS
$CBASE exec -it opencode sh -c echo hi"
    assert_launcher_output_contains "Executing in opencode project: ws"
}

t_run() {
    # Container already running -> task runs inside it via exec.
    run_launcher /dev/null run "npm install"
    assert_docker "$DINFO
$CPARENTPS
$CBASE ps -q opencode
$CBASE exec -T -w /workspace opencode npm install"
    assert_launcher_output_contains "Running in opencode project: ws"
}

t_run_nocontainer() {
    # No running container -> throwaway `compose run` (no ports), removed on exit.
    # Uses --entrypoint /bin/sh so the task args are exec'd by a real shell.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
    assert_docker "$DINFO
$CPARENTPS
$CBASE ps -q opencode
$CBASE run --rm -w /workspace --entrypoint /bin/sh opencode -c exec \"\$@\" sh npm install"
}

t_setup() {
    # setup calls _opencode_ensure_up (up -d --no-recreate so an existing
    # session is never disturbed) first, then opencode:list to show
    # the container, then _opencode_dispatch.
    run_launcher /dev/null setup "npm install"
    assert_docker "$DINFO
$CPARENTPS
$CBASE up -d --no-recreate opencode
$CWSPS
$CINFO
$CPARENTPS
$CINFO
$CPGREP
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
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: setup did not exit non-zero after build failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: setup exits non-zero after build failure"
    fi
    # Must NOT have attempted the dispatch (no ps/exec) after the failed up.
    if grep -Fq "ps -q opencode" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_dispatch")
        echo "  FAIL: dispatch ran despite build failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: no dispatch after build failure"
    fi
}

t_compose() {
    run_launcher /dev/null compose config --services
    assert_docker "$DINFO
$CPARENTPS
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
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
    unset SD_READ_ONLY
}

t_cache_all() {
    # OPENCODE_CACHE=all mounts every toolchain cache via docker-compose.cache.yml.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/vol/docker-compose.cache.yml"
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=all' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/vol/docker-compose.cache.yml -f <tmp>/docker-compose.git.yml config --services"
    unset OPENCODE_CACHE
}

t_cache_ids() {
    # Space-separated ids (case-insensitive) add only those override files.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/vol/docker-compose.go.yml"
    echo 'services: { opencode: {} }' >"$SD/compose/compose/vol/docker-compose.python.yml"
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE="Go PYTHON"' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/vol/docker-compose.go.yml -f $SD/compose/compose/vol/docker-compose.python.yml -f <tmp>/docker-compose.git.yml config --services"
    unset OPENCODE_CACHE
}

t_cache_false() {
    # OPENCODE_CACHE=false mounts no toolchain caches.
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=false' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
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
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: unknown cache id did not exit non-zero"
    else
        PASS=$((PASS + 1))
        echo "  ok: unknown cache id exits non-zero"
    fi
    unset OPENCODE_CACHE
}

t_cpu_cpuset() {
    # OPENCODE_CPUSET merges only the cpuset override file; cpus is not added.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpuset.yml"
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpus.yml"
    local dotfile="$SD/cpu.env"
    echo 'OPENCODE_CPUSET=2-3' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpuset.yml config --services"
    assert_launcher_output_contains "Using CPUSET: 2-3"
    unset OPENCODE_CPUSET
}

t_cpu_cpus() {
    # OPENCODE_CPUS merges only the cpus override file; cpuset is not added.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpus.yml"
    local dotfile="$SD/cpu.env"
    echo 'OPENCODE_CPUS=2' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpus.yml config --services"
    assert_launcher_output_contains "Using CPUS: 2"
    unset OPENCODE_CPUS
}

t_cpu_both() {
    # Both set: both override files are merged, cpuset first.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpuset.yml"
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpus.yml"
    local dotfile="$SD/cpu.env"
    printf '%s\n' 'OPENCODE_CPUSET=2-3' 'OPENCODE_CPUS=2' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$DINFO
$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpuset.yml -f $SD/compose/compose/sys/docker-compose.cpus.yml config --services"
    assert_launcher_output_contains "Using CPUSET: 2-3"
    assert_launcher_output_contains "Using CPUS: 2"
    unset OPENCODE_CPUSET OPENCODE_CPUS
}

t_start() {
    # start: warn on other running workspaces -> ensure_up (up -d) -> resolve the
    # published backend port (compose port) -> backend health (mocked curl returns
    # skipped) -> attach via mocked opencode at the resolved host port -> ps.
    run_launcher /dev/null start --model gpt
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "opencode attach http://127.0.0.1:32768 --model gpt"
    assert_docker_contains "$CBASE ps -q -a opencode"
    assert_launcher_output_contains "Backend ready. Attaching..."
}

t_start_custom_port() {
    # OPENCODE_TEST_HOST_PORT customises the mocked port to prove the resolved
    # host port is used (not a hardcoded one).
    OPENCODE_TEST_HOST_PORT=49152 run_launcher /dev/null start --model gpt
    assert_docker_contains "opencode attach http://127.0.0.1:49152 --model gpt"
    assert_launcher_output_contains "Backend: http://127.0.0.1:49152"
}

t_start_port_fail() {
    # If the backend port cannot be resolved (e.g. no port mapping), start must
    # abort with a helpful message rather than attach to a bogus address.
    local rc=0
    OPENCODE_TEST_PORT_FAIL=1 run_launcher /dev/null start --model gpt
    rc=$LAUNCH_RC
    assert_launcher_output_contains "Failed to resolve the published backend port"
    assert_launcher_output_contains "opencode:compose port opencode 4096"
    if [[ "$rc" -eq 0 ]]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: start did not exit non-zero after port resolution failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: start exits non-zero after port resolution failure"
    fi
    # Must NOT have attempted the health check or attach.
    if grep -Fq "opencode attach" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_attach")
        echo "  FAIL: attach ran despite port resolution failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: no attach after port resolution failure"
    fi
}

t_start_other_workspace() {
    # A managed container for a *different* workspace is already running. Since
    # each backend publishes on a random host port the sessions coexist: start
    # proceeds fully but warns that pre-existing containers are active.
    OPENCODE_TEST_CONFLICT=1 run_launcher /dev/null start --model gpt
    assert_launcher_output_contains "NOTICE: pre-existing opencode containers are running for other workspaces"
    assert_launcher_output_contains "opencode:stop"
    # Must NOT have aborted: the full start sequence still runs.
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "opencode attach http://127.0.0.1:32768 --model gpt"
}

t_new() {
    # new: opencode:stop (find + stop all managed containers) then opencode (full
    # start sequence: ensure_up, attach, verify).
    run_launcher /dev/null new "do something"
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "opencode attach http://127.0.0.1:32768 do something"
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
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: start did not exit non-zero after build failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: start exits non-zero after build failure"
    fi
    # Must NOT have attempted the backend health check or attach (no exec/attach).
    if grep -Fq "opencode attach" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_attach")
        echo "  FAIL: attach ran despite build failure"
    else
        PASS=$((PASS + 1))
        echo "  ok: no attach after build failure"
    fi
}

t_shell() {
    # shell is a convenience alias for 'exec sh ...' in main().
    run_launcher /dev/null shell -c 'echo hi'
    assert_docker "$DINFO
$CPARENTPS
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

t_down_refuses_other() {
    # down can only remove the current workspace's project, so the --other flag
    # (act on everything except the current workspace) has no coherent meaning
    # and must be refused without touching docker.
    local dotfile="$SD/down-other.env"
    : >"$dotfile"
    run_launcher "$dotfile" down --other
    if ((LAUNCH_RC == 2)) &&
        grep -Fq "error: --other cannot be combined with down" <<<"$LAUNCH_OUT"; then
        PASS=$((PASS + 1))
        echo "  ok: down --other refused with a clear message"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("down_refuses_other")
        echo "  FAIL: down --other should exit 2 with a refusal message"
        printf '  rc=%s out=%s\n' "$LAUNCH_RC" "$LAUNCH_OUT" | sed 's/^/    /'
    fi
    # Refuse before even probing docker: nothing may be downed.
    assert_docker ""
}

t_delete() {
    # delete: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers --stopped (includes -a for stopped containers),
    # force-removes each.
    run_launcher /dev/null delete
    assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker rm -f c1"
    assert_launcher_output_contains "Force-removing managed container"
}

t_delete_other_worktree() {
    # delete --all --other invoked from a parent repository whose synced git
    # worktree child is running: the effective workspace is the child (the same
    # resolution _opencode_args_prepare applies), so the child's container, image
    # and network are preserved while everything else is force-removed. The
    # parent repo is a real git repo with the same commit in the child worktree
    # so the worktree-resync check passes.
    rm -rf "$SD/ws/.git"
    git -C "$SD/ws" init -q -b main
    git -C "$SD/ws" -c user.name=test -c user.email=test@example.com \
        commit -q --allow-empty -m init
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
    OPENCODE_TEST_IMAGE_WS="img-wt" \
    OPENCODE_TEST_IMAGES="img-wt img-other" \
    OPENCODE_TEST_NETWORK_WS="net-wt" \
    OPENCODE_TEST_NETWORKS="net-wt net-other" \
        run_launcher /dev/null delete --all --other

    # The child container record: workspace=$SD/wt, parent=$SD/ws.
    local child_info="${CINFO% c1} wt1"
    # The delete discovery (_select_managed_containers --other) inspects both
    # managed containers in a single batch call.
    local batch_info="${CINFO% c1} c1 wt1"
    assert_docker "$DINFO
$CPARENTPS
$child_info
$child_info
docker ps -q -a --filter label=dev.snowdon.opencode.managed=true
$batch_info
$CINFO
docker rm -f c1
docker image ls -q --filter label=dev.snowdon.opencode.workspace=$SD/wt
docker network ls -q --filter label=dev.snowdon.opencode.workspace=$SD/wt
docker image ls -q --filter label=dev.snowdon.opencode.workspace
docker image rm img-other
docker network ls -q --filter label=dev.snowdon.opencode.managed
docker network rm net-other"

    # The effective (child) workspace's resources must be preserved.
    if grep -Fq "docker rm -f wt1" <<<"$DOCKER_LOG" ||
        grep -Fq "docker image rm img-wt" <<<"$DOCKER_LOG" ||
        grep -Fq "docker network rm net-wt" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:preserve_child")
        echo "  FAIL: the effective (child) workspace's resources were force-removed"
    else
        PASS=$((PASS + 1))
        echo "  ok: the effective (child) workspace's resources are preserved"
    fi
}

t_ls() {
    # ls: discovers managed containers (including stopped) and prints them in a
    # ps-style table built from per-container inspect records. The record format
    # must separate fields with a Go string literal {{"\t"}} (docker inspect does
    # not interpolate a raw \t, unlike docker ps).
    run_launcher /dev/null ls
    assert_docker_contains "docker ps -q -a --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains '{{"\t"}}'
    # A running main container is probed for its backend process before it is
    # reported as running (rather than idle).
    assert_docker_contains "$CPGREP"
    assert_launcher_output_contains "CONTAINER ID"
    assert_launcher_output_contains "STATUS"
    assert_launcher_output_contains "WORKSPACE"
    assert_launcher_output_contains "PROJECT"
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "running"
    assert_launcher_output_contains "main"
}

t_ls_idle() {
    # A running container whose backend process is gone (OPENCODE_TEST_NO_SERVE=1
    # makes the pgrep probe exit 1) must be reported as idle, not running.
    OPENCODE_TEST_NO_SERVE=1 run_launcher /dev/null ls
    assert_docker_contains "$CPGREP"
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "idle"
    if grep -Fq "running" <<<"$LAUNCH_OUT"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:running")
        echo "  FAIL: idle container must not be reported as running"
    else
        PASS=$((PASS + 1))
        echo "  ok: idle container is not reported as running"
    fi
}

t_ls_stopped() {
    # A stopped container must keep its own State.Status and must NOT be probed
    # for the backend process: `docker exec` on a stopped container would fail
    # and mislabel it as idle.
    OPENCODE_TEST_STATUS=exited run_launcher /dev/null ls
    if grep -Fq "$CPGREP" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_pgrep")
        echo "  FAIL: stopped containers must not be probed for the opencode process"
    else
        PASS=$((PASS + 1))
        echo "  ok: stopped containers are not probed for the opencode process"
    fi
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "exited"
}

t_ls_quiet() {
    # ls --quiet prints only the short container ids, one per line.
    run_launcher /dev/null ls --quiet
    if [[ "$LAUNCH_OUT" == "c1" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: ls --quiet prints only container ids"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:quiet")
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

t_ls_scope_worktree() {
    # A workspace scope also lists containers launched from its git worktrees:
    # those are labelled dev.snowdon.opencode.parent=<scope>, so ls queries that
    # label in addition to the workspace label. stop/delete stay exact-match.
    run_launcher /dev/null ls "$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.parent=$SD/ws"
    assert_launcher_output_contains "c1"
}

t_stop_scope() {
    # stop scoped to a workspace stays an exact workspace-label match: worktree
    # containers (parent label) are deliberately NOT stopped.
    run_launcher /dev/null stop "$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
    if grep -Fq "filter label=dev.snowdon.opencode.parent=$SD/ws" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_parent_filter")
        echo "  FAIL: stop must not use the parent-worktree label filter"
    else
        PASS=$((PASS + 1))
        echo "  ok: stop does not use the parent-worktree label filter"
    fi
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

t_ls_batch() {
    # Two managed containers discovered in one ps call are inspected in a single
    # docker inspect request (one record per id), not one round-trip per
    # container. --all skips _select_managed_containers' per-id oneoff filter,
    # so the batch is the only inspect of the listing.
    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/ws/wt" \
        run_launcher /dev/null ls --all

    local batch_info="${CINFO% c1} c1 wt1"
    assert_docker_contains "$batch_info"
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "wt1"
    local inspect_count
    inspect_count="$(grep -c '^docker inspect ' <<<"$DOCKER_LOG" || true)"
    if [[ "$inspect_count" -eq 1 ]]; then
        PASS=$((PASS + 1))
        echo "  ok: containers inspected in a single batch"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:batch")
        echo "  FAIL: expected exactly 1 docker inspect, got $inspect_count:"
        printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
    fi
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

t_bg() {
    # bg runs against an existing (non-empty) workspace: unlike scaffold there is
    # no empty-directory requirement, so the sandbox ws (which has a .git dir) is
    # used directly via './'. First positional is the path (like scaffold), the
    # second is the task.
    run_launcher /dev/null bg ./ "test task"
    # The one-off compose run uses the bg container name and --auto, then the
    # cleanup removes the container by name.
    assert_docker_contains "oc-bg-<pid> opencode exec"
    assert_docker_contains "opencode --auto"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Running background task on opencode project: ws"
}

t_bg_path() {
    # A relative project name resolves under SD_REPO_HOME and is created (not
    # empty-dir checked), mirroring scaffold's path handling.
    mkdir -p "$SD/repos"
    run_launcher /dev/null bg proj-bg "test task"
    assert_docker_contains "oc-bg-<pid> opencode exec"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Running background task on opencode project: proj-bg"
}

t_help() {
    run_launcher /dev/null help
    assert_launcher_output_contains "opencode launcher - manage the opencode container and sessions"
    assert_launcher_output_contains "Commands:"
    for cmd in start new up setup stop delete ls exec down run shell bg scaffold changes compose help; do
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
        PASS=$((PASS + 1))
        echo "  ok: unknown help command message"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:msg")
        echo "  FAIL: expected 'No help available for command: nonexistent'"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

t_unknown_command() {
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
        SD_YOLO=true bash "$LAUNCHER" bogus 2>&1)"
    if grep -Fq "Unknown command: bogus" <<<"$out"; then
        PASS=$((PASS + 1))
        echo "  ok: unknown command message"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:msg")
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
        PASS=$((PASS + 1))
        echo "  ok: no-docker message"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_docker")
        echo "  FAIL: expected exit 1 and 'Docker daemon is not running'"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

t_outside_root_abort() {
    # With SD_YOLO=false and HOME pointing outside the workspace, a command must
    # prompt about the directory and abort (exit != 0) without reaching any
    # compose command. The prompt reads from /dev/tty, which the test harness
    # has no controlling terminal for, so the default-abort path always runs
    # here.
    local dotfile="$SD/yolo-off.env"
    mkdir -p "$SD/home"
    printf '%s\n' 'SD_YOLO=false' "HOME=$SD/home" >"$dotfile"
    run_launcher "$dotfile" up
    assert_docker "$DINFO"
    assert_launcher_output_contains "is outside a subdirectory of HOME:"
    assert_launcher_output_contains "$SD/ws"
    assert_launcher_output_contains "Aborted."
    if [[ "$LAUNCH_RC" -eq 0 ]]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: outside-root command did not abort"
    else
        PASS=$((PASS + 1))
        echo "  ok: outside-root command aborts"
    fi
}

t_outside_root_validate() {
    # Unit test for the _check_valid_within_root contract behind the prompt:
    # HOME subdirectory rules, the "/" root shorthand, trailing-slash
    # normalisation, the normalized path written back through param 3, and the
    # previously-approved roots in param 4. Sourcing the launcher reuses the
    # real function without docker or a terminal. The approve() wrapper mirrors
    # _assert_maybe_check_outside_root's scope chain (a local ws_out_normalized
    # receiving the nameref writeback), guarding against a same-named local
    # inside the helper silently swallowing it.
    cat >"$SD/check.sh" <<'SCRIPT'
set +e
source "$LAUNCHER"
set +e
pass=1

# Contract: HOME subdirectory rules, trailing-slash normalisation, "/" root.
norm=""; prev=""
_check_valid_within_root "$HOME/proj" "$HOME" norm prev || { echo "FAIL inside"; pass=0; }
[[ "$norm" == "$HOME/proj" ]] || { echo "FAIL norm=$norm"; pass=0; }
_check_valid_within_root "$HOME/proj/" "$HOME" norm prev || { echo "FAIL trailing"; pass=0; }
[[ "$norm" == "$HOME/proj" ]] || { echo "FAIL norm2=$norm"; pass=0; }
_check_valid_within_root "$HOME/sub" "$HOME" norm prev || { echo "FAIL deeper"; pass=0; }
_check_valid_within_root "$HOME" "$HOME" norm prev && { echo "FAIL home itself counted"; pass=0; }
_check_valid_within_root / / norm prev && { echo "FAIL / counted"; pass=0; }
_check_valid_within_root /anywhere / norm prev || { echo "FAIL under-slash-root"; pass=0; }
_check_valid_within_root "$SD_OTHER" "$HOME" norm prev && { echo "FAIL outside"; pass=0; }

# Previously approved roots (param 4) pass once listed.
prev="$HOME/approved
"
_check_valid_within_root "$HOME/approved/deep" "$HOME" norm prev || { echo "FAIL approved"; pass=0; }
_check_valid_within_root "$HOME/approved/" "$HOME" norm prev || { echo "FAIL approved trailing"; pass=0; }
_check_valid_within_root "$SD_OTHER/approved" "$HOME" norm prev && { echo "FAIL sibling"; pass=0; }

# Scope parity: the production caller declares local ws_out_normalized and
# relies on the nameref writeback reaching it (bash resolves namerefs
# innermost-first, so a same-named local in the helper would swallow it).
tmp_approved=""
approve() {
    local ws_out="$1" home="$2" ws_out_normalized="" rc=0
    if _check_valid_within_root "$ws_out" "$home" ws_out_normalized tmp_approved; then
        return 0
    fi
    # Rejected: the normalized path must still have been written back.
    [[ "$ws_out_normalized" == "${ws_out%/}" ]] || return 99
    tmp_approved+="$ws_out_normalized"$'\n'
    return 1
}
approve "$HOME/proj/" "$HOME" || { echo "FAIL approve-inside"; pass=0; }
# Outside HOME: rejected, recorded via the approved-dir storage, then an
# under-path is accepted on a later call; a sibling stays rejected.
if ! approve "$SD_OTHER/approved-one/" "$HOME"; then
    approve "$SD_OTHER/approved-one/deep" "$HOME" || { echo "FAIL approved-dir not remembered"; pass=0; }
else
    echo "FAIL approve-outside accepted"
    pass=0
fi
_rc=0
approve "$SD_OTHER/approved-two" "$HOME" || _rc=1
[[ "$_rc" -eq 0 ]] && { echo "FAIL approve-sibling accepted"; pass=0; }

((pass)) && echo "outside_root_validate ok" || echo "outside_root_validate FAIL"
SCRIPT
    local out
    out="$(PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" HOME="$SD/home_home" \
        SD_OTHER="$SD/elsewhere" bash "$SD/check.sh")"
    if grep -Fq "outside_root_validate ok" <<<"$out"; then
        PASS=$((PASS + 1))
        echo "  ok: _check_valid_within_root validation contract"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:validate")
        echo "  FAIL: _check_valid_within_root validation contract"
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
