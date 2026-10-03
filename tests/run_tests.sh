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

# The launcher prompts on /dev/tty when a workspace is outside $HOME (or outside
# $OPENCODE_WORKSPACE). It is therefore always run through `setsid`, which puts
# it in a new session with no controlling terminal: without that, an interactive
# `make test` hands the launcher the developer's terminal and the read blocks
# there (swallowing keystrokes) until Enter is pressed. Detached, /dev/tty
# cannot be opened, so the prompt always takes its default-abort path and the
# suite behaves the same from a terminal, a pipe or CI. util-linux and busybox
# both ship setsid.
if ! command -v setsid >/dev/null 2>&1; then
    echo "Error: setsid is required to run the tests (provided by util-linux or busybox)" >&2
    exit 1
fi

# --- test runner helpers -------------------------------------------------

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

# Fresh, isolated sandbox per test, kept out of the repo in /tmp: a fake
# compose dir the launcher reads its docker-compose files from, and a workspace
# with a .git dir so the launcher's read-only .git mount logic is exercised.
make_sandbox() {
    SD="$(mktemp -d "${TMPDIR:-/tmp}/opencode-tests.XXXXXX")"
    mkdir -p "$SD/compose" "$SD/compose/compose/vol" "$SD/compose/compose/net" \
        "$SD/compose/compose/sys" "$SD/compose/compose/image" "$SD/ws/.git"
    echo 'services: { opencode: {} }' >"$SD/compose/docker-compose.yml"
    # The launcher runs the host-side helpers straight out of the repository, so
    # the sandbox repo root carries a copy of them: waitforserver.sh to wait for
    # the backend, and the versioned start-tui.sh to run the TUI. Both exec the
    # (mocked) opencode/curl binaries, so the copies are the real scripts, in the
    # same scripts/<version>/ layout the launcher resolves them from.
    # Dockerfile.example is copied there too: 'create' scaffolds a workspace
    # Dockerfile from the launcher's own example, which it reads from SD_OPENCODE.
    mkdir -p "$SD/compose/scripts/v1" "$SD/compose/scripts/v2"
    cp "$ROOT_DIR/scripts/waitforserver.sh" "$SD/compose/scripts/"
    cp "$ROOT_DIR/scripts/v1/start-tui.sh" "$SD/compose/scripts/v1/"
    cp "$ROOT_DIR/scripts/v2/start-tui.sh" "$SD/compose/scripts/v2/"
    chmod +x "$SD/compose/scripts/"*.sh "$SD/compose/scripts/v1/"*.sh "$SD/compose/scripts/v2/"*.sh
    cp "$ROOT_DIR/Dockerfile.example" "$SD/compose/"
    # The launcher injects a per-component skills file into the container
    # (~/.opencode/skills/available-<component>-tools.md) whenever an image
    # component is selected, which parse_image_url derives for the default image
    # tag too. It reads it from $SD_OPENCODE/opencode/skills, so the sandbox
    # carries the real skill files or every command aborts with
    # "Failed to resolve a skills path".
    mkdir -p "$SD/compose/opencode/skills" "$SD/compose/compose/env"
    cp "$ROOT_DIR/opencode/skills/"*.md "$SD/compose/opencode/skills/"
    # Set up env files for tests - password is included for v2 server mode
    cp "$ROOT_DIR/compose/env/docker-compose.password.yml" "$SD/compose/compose/env/" 2>/dev/null || echo 'services: { opencode: {} }' >"$SD/compose/compose/env/docker-compose.password.yml"
    # The port override is always merged in these tests because the mocked
    # opencode CLI is on PATH (a host-side TUI attach requires the published
    # host port; see _opencode_on_host in the launcher).
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.port.yml"
    # The sandbox workspace has no Dockerfile, so _opencode_args_prepare takes
    # the "mount a prebuilt image" branch and merges the image overlay.
    CIMG="$SD/compose/compose/image/docker-compose.image.yml"
    echo 'services: { opencode: {} }' >"$CIMG"
    # Toolchain cache dirs live in the sandbox, not under the host's $HOME, so a
    # launcher run never stops to offer creating them (see _cache_dirs).
    _cache_dirs
    # Compose base args used in every expected command, in the order
    # _opencode_args_prepare merges them: main file, [cache], image, git mount,
    # port. The git mount lives in a mktemp dir and is normalised to <tmp>.
    CBASE="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml"
    # Container discovery: the managed label first, then -a, then the scoping
    # label. Shared by every expectation so the flag order is defined once.
    CPS="docker ps -q --filter label=dev.snowdon.opencode.managed=true -a"
    # _opencode_args_prepare probes for worktree-child containers of the workspace
    # before preparing the compose args; the fresh sandbox has none, so only the
    # discovery call itself is logged.
    CPARENTPS="$CPS --filter label=dev.snowdon.opencode.parent=$SD/ws"
    # A workspace-scoped network query is limited to the managed label as well, so
    # only our own networks are considered.
    CMANAGED="--filter label=dev.snowdon.opencode.managed=true"
    # The workspace-scoped listing used by up/setup (opencode:list).
    CWSPS="$CPS --filter label=dev.snowdon.opencode.workspace=$SD/ws"
    # docker inspect record produced by the launcher's _container_info helper
    # (id, status, workspace, project, oneoff, tui, parent, sentinel).
    CINFO="docker inspect --format {{.ID}}{{\"\\t\"}}{{.State.Status}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.workspace\"}}{{\"\\t\"}}{{index .Config.Labels \"com.docker.compose.project\"}}{{\"\\t\"}}{{index .Config.Labels \"com.docker.compose.oneoff\"}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.tui\"}}{{\"\\t\"}}{{index .Config.Labels \"dev.snowdon.opencode.parent\"}}{{\"\\t\"}}. c1"
}

# Turn the sandbox workspace into a real git repository with a single commit, so
# the worktree actions of `create` run `git worktree add` for real. The default
# sandbox .git is an empty directory, which only satisfies the read-only git
# mount of the container tests.
make_git_workspace() {
    rm -rf "$SD/ws/.git"
    git -C "$SD/ws" init -q
    git -C "$SD/ws" -c user.email=launcher@tests -c user.name=launcher \
        commit -q --allow-empty -m init
}

# The agent worktree root that `create --worktree` and `uptree` agree on:
# $SD_REPO_HOME/agent-trees (SD_REPO_HOME is $SD/repos in the sandbox).
make_agent_tree_root() {
    mkdir -p "$SD/repos/agent-trees"
}

# Run the launcher, capturing both the launcher's stdout/err and the mock
# docker log. Nondeterministic temp paths (docker-compose.git.yml) are
# normalised so assertions are stable.
#   run_launcher <path-to-env-dotfile> <subcommand> [args...]
# The directory the launcher is driven from is $LAUNCH_CWD (default the sandbox
# workspace), so a test can run it from a git worktree instead.
# Globals written: LAUNCH_OUT (launcher+vars), LAUNCH_RC (exit code),
# DOCKER_LOG (normalised docker lines)
run_launcher() {
    local dotfile="$1"
    local cmd="$2"
    shift 2

    export PATH="$MOCKBIN:$PATH"
    export OPENCODE_TEST_DOCKER_LOG="$SD/docker.log"
    # The image URLs pin the image layer, so the overlay set (password file,
    # version layer, ...) a command composes is deterministic. Setting
    # LAUNCH_NO_IMAGE_URL=1 opts out, for the paths that are only reachable when
    # OPENCODE_CACHE picks the image variant itself (image_url_set=false).
    if [[ "${LAUNCH_NO_IMAGE_URL:-}" == 1 ]]; then
        unset OPENCODE_IMAGE_URL OPENCODE_IMAGE_URL_TUI
    else
        export OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:duck-v2"
        export OPENCODE_IMAGE_URL_TUI="devsnowdon/opencode-docker:empty-v2"
    fi
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
    out="$(cd "${LAUNCH_CWD:-$SD/ws}" && setsid bash "$LAUNCHER" "$cmd" "$@" \
        </dev/null 2>&1)"
    LAUNCH_RC=$?

    # Keep only the launcher's own output lines, dropping mock echoes.
    LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:')"

    # Normalise the docker log: collapse the nondeterministic temp files the
    # launcher generates per run (the git mount, the worktree label override)
    # and the scaffold container pid.
    DOCKER_LOG="$(sed -E \
        -e 's#-f [^ ]*docker-compose\.git\.yml#-f <tmp>/docker-compose.git.yml#g' \
        -e 's#-f [^ ]*docker-compose\.labels\.yml#-f <tmp>/docker-compose.labels.yml#g' \
        -e 's/oc-scaffold-[0-9]+/oc-scaffold-<pid>/g' \
        -e 's/oc-changes-[0-9]+/oc-changes-<pid>/g' \
        -e 's/oc-bg-[0-9]+/oc-bg-<pid>/g' \
        "$OPENCODE_TEST_DOCKER_LOG")"
}

# Same as run_launcher, but with every PATH entry holding an `opencode` binary
# dropped (the mocked docker/curl are kept), so the launcher takes the
# in-container tui path: no published port, and the backend is only reachable
# over the compose network. Same globals as run_launcher.
#   run_launcher_no_host_opencode <path-to-env-dotfile> <subcommand> [args...]
run_launcher_no_host_opencode() {
    local dotfile="$1"
    local cmd="$2"
    shift 2

    export PATH="$MOCKBIN:$PATH"
    export OPENCODE_TEST_DOCKER_LOG="$SD/docker.log"
    export SD_OPENCODE="$SD/compose"
    export SD_REPO_HOME="$SD/repos"
    export SD_YOLO=true
    : >"$OPENCODE_TEST_DOCKER_LOG"

    if [[ -f "$dotfile" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$dotfile"
        set +a
    fi

    local tbin="$SD/tbin"
    mkdir -p "$tbin"
    cp "$MOCKBIN/docker" "$MOCKBIN/curl" "$tbin/"
    chmod +x "$tbin/docker" "$tbin/curl"

    local new_path="" dir
    local -a dirs
    IFS=: read -r -a dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -n "$dir" && ! -x "$dir/opencode" ]] && new_path+=":$dir"
    done

    local out
    out="$(cd "$SD/ws" && setsid env PATH="$tbin$new_path" \
        OPENCODE_TEST_NO_HOST_TUI=1 \
        OPENCODE_TEST_DOCKER_LOG="$SD/docker.log" \
        SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" SD_YOLO=true \
        bash "$LAUNCHER" "$cmd" "$@" </dev/null 2>&1)"
    LAUNCH_RC=$?

    LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:')"
    DOCKER_LOG="$(sed -E \
        -e 's#-f [^ ]*docker-compose\.git\.yml#-f <tmp>/docker-compose.git.yml#g' \
        -e 's#-f [^ ]*docker-compose\.labels\.yml#-f <tmp>/docker-compose.labels.yml#g' \
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
    if grep -Fq -- "$needle" <<<"$DOCKER_LOG"; then
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

# Assert that docker was NOT called with the given line.
#   assert_docker_lacks <needle>
assert_docker_lacks() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:docker-lacks:$needle")
        echo "  FAIL: docker log unexpectedly contains: $needle"
        echo "  --- docker log ---"
        printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
    else
        PASS=$((PASS + 1))
        echo "  ok: docker log does not contain: $needle"
    fi
}

# Assert that the launcher's own output (stdout/stderr) contains the given text.
assert_launcher_output_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$LAUNCH_OUT"; then
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

# Assert that the launcher's own output does NOT contain the given needle.
#   assert_launcher_output_lacks <needle>
assert_launcher_output_lacks() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$LAUNCH_OUT"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:output-lacks:$needle")
        echo "  FAIL: launcher output unexpectedly contains: $needle"
        echo "  --- launcher output ---"
        printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
    else
        PASS=$((PASS + 1))
        echo "  ok: launcher output does not contain: $needle"
    fi
}

# Assert that a command exited with the given status.
#   assert_rc <expected-rc> <actual-rc> <description>
assert_rc() {
    local expected="$1"
    local actual="$2"
    local what="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: $what (rc=$actual)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:rc:$what")
        echo "  FAIL: $what (expected rc=$expected, got rc=$actual)"
    fi
}

# Assert that the file contains the given needle.
#   assert_file_contains <path> <needle>
assert_file_contains() {
    local path="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$path"; then
        PASS=$((PASS + 1))
        echo "  ok: $path contains: $needle"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:file:$needle")
        echo "  FAIL: $path does not contain: $needle"
    fi
}

# Assert that the given text contains the given needle.
#   assert_output_contains <text> <needle>
assert_output_contains() {
    local text="$1"
    local needle="$2"
    if grep -Fq -- "$needle" <<<"$text"; then
        PASS=$((PASS + 1))
        echo "  ok: output contains: $needle"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:output:$needle")
        echo "  FAIL: output does not contain: $needle"
        printf '%s\n' "$text" | sed 's/^/    /'
    fi
}

# Create the toolchain cache override files named on the command line in the
# sandbox compose/vol directory, so _opencode_args_prepare finds the
# per-id files it merges. Sets CACHEVOL for the expected compose args.
#   _cache_vol_files go rust ...
# The launcher aborts with "not a regular file: ..." when an id's override file
# is absent, so every id the request is normalised to needs a file here.
_cache_vol_files() {
    CACHEVOL="$SD/compose/compose/vol"
    local id
    for id in "$@"; do
        echo 'services: { opencode: {} }' >"$CACHEVOL/docker-compose.$id.yml"
    done
}

# Point every toolchain cache dir override at a directory inside the sandbox and
# create it. The launcher checks the host dirs backing the selected caches and
# refuses to start when one of them is missing, and the compose vol overrides
# read the very same variables; both default to paths under $HOME. Keeping them
# in the sandbox is what makes the cache tests independent of whoever runs the
# suite: a CI runner home holds none of them, so without this the launcher
# stopped on the missing directories and never built the compose command the
# cache tests assert.
#   _cache_dirs
_cache_dirs() {
    mkdir -p "$SD/cache/pip" "$SD/cache/npm" "$SD/cache/go-build" \
        "$SD/cache/go-mod" "$SD/cache/cargo-registry" "$SD/cache/cargo-git" \
        "$SD/cache/sccache"
    export OPENCODE_PIP_CACHE_DIR="$SD/cache/pip"
    export OPENCODE_NPM_CACHE_DIR="$SD/cache/npm"
    export OPENCODE_GO_BUILD_CACHE_DIR="$SD/cache/go-build"
    export OPENCODE_GO_MOD_CACHE_DIR="$SD/cache/go-mod"
    export OPENCODE_CARGO_REGISTRY_DIR="$SD/cache/cargo-registry"
    export OPENCODE_CARGO_GIT_DIR="$SD/cache/cargo-git"
    export OPENCODE_SCCACHE_DIR="$SD/cache/sccache"
}

# Point the same overrides at paths that do not exist, so the launcher's offer
# to create a missing cache dir (and the abort that follows when it is
# declined) can be exercised without touching the host's home.
#   _cache_dirs_absent
_cache_dirs_absent() {
    export OPENCODE_PIP_CACHE_DIR="$SD/absent/pip"
    export OPENCODE_NPM_CACHE_DIR="$SD/absent/npm"
    export OPENCODE_GO_BUILD_CACHE_DIR="$SD/absent/go-build"
    export OPENCODE_GO_MOD_CACHE_DIR="$SD/absent/go-mod"
    export OPENCODE_CARGO_REGISTRY_DIR="$SD/absent/cargo-registry"
    export OPENCODE_CARGO_GIT_DIR="$SD/absent/cargo-git"
    export OPENCODE_SCCACHE_DIR="$SD/absent/sccache"
}

# --- individual tests ---------------------------------------------------

t_up() {
    # up: worktree-child discovery during args preparation, then compose up, then
    # opencode:list (workspace-scoped + parent lookup) to show the container.
    run_launcher /dev/null up
    assert_docker "$CPARENTPS
$CBASE up -d opencode
$CWSPS
$CINFO
$CPARENTPS
$CINFO"
}

t_stop() {
    # stop: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers (all workspaces by default), stops each.
    run_launcher /dev/null stop
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_launcher_output_contains "Stopping existing opencode containers"
}

t_stop_dry_run() {
    # stop --dry-run: read-only discovery still runs (so the report names the
    # real containers), but the destructive stop is only printed, never sent to
    # docker.
    run_launcher /dev/null stop --dry-run
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_launcher_output_contains "DRY RUN: docker stop c1"
    assert_docker_lacks "docker stop c1"
}

t_exec() {
    # exec calls opencode:exec directly (ensure_up is commented out in the
    # launcher), which runs docker compose exec -it.
    run_launcher /dev/null exec sh -c 'echo hi'
    assert_docker "$CPARENTPS
$CBASE exec -it opencode sh -c echo hi"
    assert_launcher_output_contains "Executing in opencode project: ws"
}

t_run() {
    # Container already running -> task runs inside it via exec.
    run_launcher /dev/null run "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE exec -T -w /workspace/project opencode npm install"
    assert_launcher_output_contains "Running in opencode project: ws"
}

t_run_nocontainer() {
    # No running container -> throwaway `compose run` (no ports), removed on exit.
    # Uses --entrypoint /bin/sh so the task args are exec'd by a real shell.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE run --rm -w /workspace/project --entrypoint /bin/sh opencode -c exec \"\$@\" sh npm install"
}

t_setup() {
    # setup calls _opencode_ensure_up (up -d --no-recreate so an existing
    # session is never disturbed) first, then opencode:list to show
    # the container, then _opencode_dispatch.
    run_launcher /dev/null setup "npm install"
    assert_docker "$CPARENTPS
$CBASE up -d --no-recreate opencode
$CWSPS
$CINFO
$CPARENTPS
$CINFO
$CBASE ps -q opencode
$CBASE exec -T -w /workspace/project opencode npm install"
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
    assert_docker "$CPARENTPS
$CBASE config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
}

t_compose_no_readonly() {
    # SD_READ_ONLY=false disables the read-only .git mounts. The generated
    # docker-compose.git.yml is still merged, because the same override file now
    # also carries the read-only skills mount (a non-.git read-only mount), so
    # the presence of the -f flag is no longer what proves .git locking. What
    # proves it is the launcher's "read-only locking dir:" line, which is
    # printed once per .git dir it locks.
    # run_launcher sources the dotfile in the parent shell, so unset it again to
    # avoid leaking into later tests.
    local dotfile="$SD/readonly.env"
    echo 'SD_READ_ONLY=false' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
    assert_launcher_output_lacks "read-only locking dir:"
    unset SD_READ_ONLY
}

t_context_file_derive() {
    # OPENCODE_DOCKERFILE pointing at a file derives the build context from the
    # file's directory (basedir). Both are resolved to absolute paths so the
    # derived context and dockerfile stay consistent regardless of the cwd the
    # launcher is driven from.
    mkdir -p "$SD/ws/myBuild"
    : >"$SD/ws/myBuild/Dockerfile.dev"
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" OPENCODE_DOCKERFILE="myBuild/Dockerfile.dev" \
        bash -c 'unset OPENCODE_CONTEXT; source "$1"
            printf "%s|%s\n" "$OPENCODE_CONTEXT" "$OPENCODE_DOCKERFILE"' _ "$LAUNCHER")"
    if [[ "$out" == "$SD/ws/myBuild|$SD/ws/myBuild/Dockerfile.dev" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: derived context and dockerfile from basedir"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:derive")
        echo "  FAIL: expected '$SD/ws/myBuild|$SD/ws/myBuild/Dockerfile.dev', got: '$out'"
    fi
}

t_context_must_be_file() {
    # OPENCODE_DOCKERFILE must name a regular file; a directory-valued variable
    # does NOT trigger derivation, so both keep the values they were given
    # (an unset OPENCODE_CONTEXT stays empty).
    mkdir -p "$SD/ws/myBuild"
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" OPENCODE_DOCKERFILE="myBuild" \
        bash -c 'unset OPENCODE_CONTEXT; source "$1"
            printf "%s|%s\n" "$OPENCODE_CONTEXT" "$OPENCODE_DOCKERFILE"' _ "$LAUNCHER")"
    if [[ "$out" == "|myBuild" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: no derivation for a directory-valued dockerfile"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_derive_dir")
        echo "  FAIL: expected '|myBuild', got: '$out'"
    fi
}

t_context_explicit_wins() {
    # An explicitly set OPENCODE_CONTEXT is never overridden by derivation.
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" \
        OPENCODE_DOCKERFILE="myBuild/Dockerfile.dev" OPENCODE_CONTEXT="myCtx" \
        bash -c 'source "$1"
            printf "%s|%s\n" "$OPENCODE_CONTEXT" "$OPENCODE_DOCKERFILE"' _ "$LAUNCHER")"
    if [[ "$out" == "myCtx|myBuild/Dockerfile.dev" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: explicit OPENCODE_CONTEXT is preserved"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:explicit")
        echo "  FAIL: expected 'myCtx|myBuild/Dockerfile.dev', got: '$out'"
    fi
}

t_cache_all() {
    # OPENCODE_CACHE=all selects the full toolchain. parse_cache normalises the
    # request to the variant's canonical id list ("go rust python node"), so
    # _opencode_args_prepare merges one override file per id, in that order.
    # The aggregate compose/vol/docker-compose.cache.yml is NOT merged: the
    # "all" branch that used it is unreachable, since parse_cache has already
    # rewritten OPENCODE_CACHE by the time the compose args are built.
    _cache_vol_files go rust python node
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=all' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CACHEVOL/docker-compose.cache.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    unset OPENCODE_CACHE
}

t_cache_all_bare_home() {
    # The cache tests must not lean on the toolchain cache dirs the host's home
    # happens to have. With OPENCODE_CACHE=all the launcher checks all seven and
    # offers to create the missing ones (see _assert_maybe_write_config_dirs),
    # answering that prompt from the closed stdin the suite runs it with: on a
    # home without them it aborts before building the compose command at all,
    # which is how this test failed in CI, where a runner home holds no
    # ~/.cache/pip, ~/go/pkg/mod, ~/.cargo/registry or ~/.cache/sccache. Running
    # against a bare HOME makes that dependency fail here on any machine
    # instead of only where the host home happens to be incomplete.
    _cache_vol_files go rust python node
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=all' >"$dotfile"
    local saved_home="$HOME"
    HOME="$SD/bare-home"
    export HOME
    mkdir -p "$HOME"
    run_launcher "$dotfile" compose config --services
    HOME="$saved_home"
    export HOME
    unset OPENCODE_CACHE
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CACHEVOL/docker-compose.cache.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_lacks "The following directories do not exist:"
}

t_cache_dirs_missing_aborts() {
    # The launcher side of the contract _cache_dirs works around: a cache dir
    # that does not exist is named and, run without a terminal (as here, with
    # stdin closed), reported and refused instead of being created, before any
    # compose command is built. So no container starts against a cache path
    # docker would have to create as root, and a non-interactive run fails on
    # the real cause instead of on a question nobody was there to answer. The
    # suite therefore hands the launcher cache dirs that already exist.
    _cache_vol_files go rust python node
    _cache_dirs_absent
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=all' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    # Restore the sandbox-provided dirs: the exports above outlive the test.
    _cache_dirs
    unset OPENCODE_CACHE
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "$SD/absent/go-mod"
    assert_launcher_output_contains "The following directories do not exist:"
    assert_launcher_output_contains "Not interactive: create them above and re-run."
    assert_rc 1 "$LAUNCH_RC" "a missing cache dir aborts before compose"
}

t_cache_dirs_uppercase_ids() {
    # OPENCODE_CACHE is documented, and used by t_cache_ids, as
    # case-insensitive, so "PYTHON NODE" has to be checked for its cache dirs
    # exactly like "python node". The check matched the raw value, so an
    # upper-case request skipped it entirely: the launcher went on to build the
    # compose command and docker created ~/.cache/pip and ~/.npm itself, as
    # root, instead of the user being offered to create them first.
    _cache_vol_files python node
    _cache_dirs_absent
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE="PYTHON NODE"' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    _cache_dirs
    unset OPENCODE_CACHE
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "$SD/absent/npm"
    assert_launcher_output_contains "The following directories do not exist:"
    assert_rc 1 "$LAUNCH_RC" "an upper-case cache id is still checked"
}

t_cache_ids() {
    # Space-separated ids are case-insensitive and select the variant that
    # carries them: python/node are the duck toolchain, so "PYTHON NODE" is
    # normalised to the duck id list and only those two override files merge.
    # Selecting no full-compiler id (is_full unset) used to abort the launcher
    # with "is_full: unbound variable".
    _cache_vol_files python node
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE="PYTHON NODE"' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CACHEVOL/docker-compose.python.yml -f $CACHEVOL/docker-compose.node.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    unset OPENCODE_CACHE
}

t_cache_false() {
    # OPENCODE_CACHE=false mounts no toolchain caches.
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=false' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
$CBASE config --services"
    assert_launcher_output_contains "Running container without toolchain cache"
    unset OPENCODE_CACHE
}

t_cache_unknown() {
    # An unrecognised cache id is rejected. parse_cache validates every id
    # before anything else runs, so OPENCODE_CACHE=bogus aborts with a
    # diagnostic and a non-zero status instead of mounting the wrong caches (or,
    # as it used to when OPENCODE_CACHE selected the image itself, silently
    # behaving like OPENCODE_CACHE=false). The abort happens while the launcher
    # is still being sourced, so no docker command has run at all.
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=bogus' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker ""
    assert_launcher_output_contains "unknown toolchain cache id: bogus"
    assert_rc 1 "$LAUNCH_RC" "an unknown cache id is rejected"
    unset OPENCODE_CACHE
}

t_cache_unknown_no_image_url() {
    # Same rejection without a pinned image URL (image_url_set=false), i.e. for
    # the configuration where OPENCODE_CACHE picks the image variant. That branch
    # used to classify the request by scanning for known ids only, so a bogus id
    # was dropped along with the image selection.
    LAUNCH_NO_IMAGE_URL=1
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=bogus' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker ""
    assert_launcher_output_contains "unknown toolchain cache id: bogus"
    assert_rc 1 "$LAUNCH_RC" "an unknown cache id is rejected without a pinned image url"
    unset OPENCODE_CACHE LAUNCH_NO_IMAGE_URL
}

t_cache_partial_unknown() {
    # A request that mixes a valid id with a typo must not be upgraded to the
    # whole toolchain: "go bogus" selected the full variant before validation
    # existed, silently mounting caches that were never asked for.
    LAUNCH_NO_IMAGE_URL=1
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE="go bogus"' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker ""
    assert_launcher_output_contains "unknown toolchain cache id: bogus"
    assert_rc 1 "$LAUNCH_RC" "a partially valid cache request is rejected"
    unset OPENCODE_CACHE LAUNCH_NO_IMAGE_URL
}

t_cpu_cpuset() {
    # OPENCODE_CPUSET merges only the cpuset override file; cpus is not added.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpuset.yml"
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpus.yml"
    local dotfile="$SD/cpu.env"
    echo 'OPENCODE_CPUSET=2-3' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpuset.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_contains "Using CPUSET: 2-3"
    unset OPENCODE_CPUSET
}

t_cpu_cpus() {
    # OPENCODE_CPUS merges only the cpus override file; cpuset is not added.
    echo 'services: { opencode: {} }' >"$SD/compose/compose/sys/docker-compose.cpus.yml"
    local dotfile="$SD/cpu.env"
    echo 'OPENCODE_CPUS=2' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpus.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
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
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.cpuset.yml -f $SD/compose/compose/sys/docker-compose.cpus.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_contains "Using CPUSET: 2-3"
    assert_launcher_output_contains "Using CPUS: 2"
    unset OPENCODE_CPUSET OPENCODE_CPUS
}

t_start() {
    # start: warn on other running workspaces -> ensure_up (up -d) -> resolve the
    # published backend port (compose port) -> backend health (mocked curl returns
    # skipped) -> TUI via scripts/v2/start-tui.sh, which runs the mocked
    # `opencode --server` against the resolved host port -> ps.
    # The default image layer is v2, so the health path is "/" and the TUI takes
    # the backend as a global flag; t_start_v1 pins v1 for the other branch.
    run_launcher /dev/null start --model gpt
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode --server http://127.0.0.1:32768 --model gpt"
    assert_docker_contains "$CBASE ps -q -a opencode"
    assert_launcher_output_contains "Backend ready. Attaching..."
}

t_start_v1() {
    # OPENCODE_IMAGE_VERSION=v1 pins the v1 layer: the health endpoint is
    # /api/health and the TUI comes from scripts/v1/start-tui.sh, which runs
    # `opencode attach <url>` because v1 has no global --server flag. v2 dropped
    # attach, so this also proves the version actually selects the script.
    OPENCODE_IMAGE_VERSION=v1 run_launcher /dev/null start --model gpt
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode attach http://127.0.0.1:32768 --model gpt"
    # The v2 entrypoint must not be used.
    if grep -Fq "opencode --server" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_server")
        echo "  FAIL: the v2 --server entrypoint ran on the v1 layer"
    else
        PASS=$((PASS + 1))
        echo "  ok: no --server on the v1 layer"
    fi
}

t_start_v2() {
    # OPENCODE_IMAGE_VERSION=v2 selects the v2 layer (also the default): the
    # health endpoint is "/", and the TUI comes from scripts/v2/start-tui.sh,
    # which runs `opencode --server <url>` because v2 dropped `opencode attach`.
    # Everything else about the sequence is identical.
    OPENCODE_IMAGE_VERSION=v2 run_launcher /dev/null start --model gpt
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode --server http://127.0.0.1:32768 --model gpt"
    # The v1 entrypoint must not be used.
    if grep -Fq "opencode attach" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_attach")
        echo "  FAIL: the v1 attach entrypoint ran on the v2 layer"
    else
        PASS=$((PASS + 1))
        echo "  ok: no attach on the v2 layer"
    fi
}

t_start_v2_missing_script() {
    # A version whose scripts/<version>/start-tui.sh is not in the repository
    # must fail with a clear message instead of silently running nothing.
    OPENCODE_IMAGE_VERSION=v3 run_launcher /dev/null start --model gpt
    assert_launcher_output_contains "The TUI script for opencode v3 is missing"
    if grep -Fq "opencode attach" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_attach")
        echo "  FAIL: the v1 attach entrypoint ran for an unknown version"
    else
        PASS=$((PASS + 1))
        echo "  ok: no TUI for an unknown version"
    fi
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
    assert_docker_contains "opencode --server http://127.0.0.1:32768 --model gpt"
}

t_new() {
    # new: opencode:stop (find + stop all managed containers) then opencode (full
    # start sequence: ensure_up, TUI, verify).
    run_launcher /dev/null new "do something"
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "opencode --server http://127.0.0.1:32768 do something"
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

t_start_no_host_tui() {
    # Without a host opencode CLI the throwaway `tui` service attaches to the
    # backend over the compose network: the port override is NOT merged, no host
    # port is published or resolved, and the backend health check runs from
    # inside the container (the host cannot reach the compose service name).
    # Inside the network the backend is on its private port, so the probe URL is
    # the service name and the container port (http://opencode:4096 + the v2
    # health path), never a published host port.
    # The service's entrypoint is `start-tui 0` (docker-compose.yml), so the
    # launcher only forwards the origin and the user's own arguments.
    run_launcher_no_host_opencode /dev/null start --model gpt

    # The compose args must NOT include the port override.
    local cbase_no_port="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml"
    assert_docker_contains "$cbase_no_port up -d opencode"
    assert_docker_contains "$cbase_no_port exec -T opencode curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "$cbase_no_port run --rm --remove-orphans -e BACKEND_ORIGIN=http://opencode:4096 tui --model gpt"
    assert_launcher_output_contains "Backend: http://opencode:4096"
    if grep -Fq "docker-compose.port.yml" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_override")
        echo "  FAIL: port override merged without a host opencode CLI"
    else
        PASS=$((PASS + 1))
        echo "  ok: port override not merged with the in-container tui"
    fi
    if grep -Fq "port opencode 4096" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_port")
        echo "  FAIL: resolved a host port without a host opencode CLI"
    else
        PASS=$((PASS + 1))
        echo "  ok: no host port resolved with the in-container tui"
    fi
}

t_start_waits_for_backend_in_container() {
    # Without a host opencode CLI there is no published port, so the wait runs
    # inside the container, where the compose service name resolves. The mocked
    # container's health probe fails, which is what drives start down the wait
    # path; the mocked `waitforserver` then succeeds. The TUI is then run as the
    # one-off `tui` service, whose entrypoint is the container-side start-tui.
    OPENCODE_TEST_HEALTH_FAIL=1 run_launcher_no_host_opencode /dev/null start --model gpt
    local cbase_no_port="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml"
    assert_docker_contains "$cbase_no_port exec -d -w /workspace/project opencode start-serve-backend"
    assert_docker_contains "$cbase_no_port exec -T -w /workspace/project opencode waitforserver http://127.0.0.1:4096"
    assert_docker_contains "$cbase_no_port run --rm --remove-orphans -e BACKEND_ORIGIN=http://opencode:4096 tui --model gpt"
    assert_launcher_output_contains "Waiting for the opencode backend to launch"
}

t_waitforserver() {
    # scripts/waitforserver.sh on its own: the origin comes from the argument or
    # the environment, the wait is bounded, and a bad timeout is rejected.
    local out rc
    out="$(PATH="$MOCKBIN:$PATH" bash "$ROOT_DIR/scripts/waitforserver.sh" \
        http://127.0.0.1:32768 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "waitforserver succeeds once the backend answers"

    out="$(PATH="$MOCKBIN:$PATH" BACKEND_ORIGIN=http://opencode:4096 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "waitforserver falls back to \$BACKEND_ORIGIN"

    # The mock curl counts its calls in a file, so the poll count survives
    # across the separate processes waitforserver spawns.
    : >"$SD/curl.count"
    out="$(PATH="$MOCKBIN:$PATH" OPENCODE_TEST_CURL_COUNT_FILE="$SD/curl.count" \
        OPENCODE_TEST_HEALTH_AFTER=1 WAITFORSERVER_TIMEOUT=5 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" http://127.0.0.1:32768 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "waitforserver polls until the backend answers"

    out="$(PATH="$MOCKBIN:$PATH" OPENCODE_TEST_HEALTH_FAIL=1 WAITFORSERVER_TIMEOUT=1 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" http://127.0.0.1:32768 2>&1)"
    rc=$?
    assert_rc 1 "$rc" "waitforserver times out when the backend never answers"
    assert_output_contains "$out" "(limit 1s) waiting for http://127.0.0.1:32768"

    out="$(PATH="$MOCKBIN:$PATH" bash "$ROOT_DIR/scripts/waitforserver.sh" \
        http://127.0.0.1:32768 soon 2>&1)"
    rc=$?
    assert_rc 2 "$rc" "waitforserver rejects a non-numeric timeout"
    assert_output_contains "$out" "timeout must be a positive whole number of seconds"
}

t_shell() {
    # shell is a convenience alias for 'exec sh ...' in main().
    run_launcher /dev/null shell -c 'echo hi'
    assert_docker "$CPARENTPS
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
    # and is refused once opencode:down parses its flags. Only the docker probe
    # and worktree-child discovery run first; nothing may actually be downed.
    local dotfile="$SD/down-other.env"
    : >"$dotfile"
    run_launcher "$dotfile" down --other
    if ((LAUNCH_RC == 2)) &&
        grep -Fq "error: --other,-o cannot be combined with down" <<<"$LAUNCH_OUT"; then
        PASS=$((PASS + 1))
        echo "  ok: down --other refused with a clear message"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("down_refuses_other")
        echo "  FAIL: down --other should exit 2 with a refusal message"
        printf '  rc=%s out=%s\n' "$LAUNCH_RC" "$LAUNCH_OUT" | sed 's/^/    /'
    fi
    # Nothing is downed: no compose down/stop reach docker.
    assert_docker "$CPARENTPS"
}

t_down_dry_run() {
    # down --dry-run: neither the compose down nor the workspace-scoped stop of
    # remaining one-off containers reaches docker.
    run_launcher /dev/null down --dry-run
    assert_docker_contains "$CPS"
    assert_launcher_output_contains "DRY RUN: docker compose -p ws -f"
    assert_launcher_output_contains "DRY RUN: docker stop c1"
    assert_docker_lacks "$CBASE down"
    assert_docker_lacks "docker stop c1"
}

t_delete() {
    # delete: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers --stopped (includes -a for stopped containers),
    # force-removes each. Removal is silent on stdout, so the removal itself is
    # asserted through the docker call rather than a launcher message.
    run_launcher /dev/null delete
    assert_docker_contains "$CPS"
    assert_docker_contains "docker rm -f c1"
}

t_delete_dry_run() {
    # delete --all --dry-run: every destructive primitive (container rm, image
    # rm, network rm) goes through _docker_run_destructive, so a dry run reports
    # each one and touches nothing.
    OPENCODE_TEST_IMAGES="img1" OPENCODE_TEST_NETWORKS="net1" \
        run_launcher /dev/null delete --all --dry-run
    assert_launcher_output_contains "DRY RUN: docker rm -f c1"
    assert_launcher_output_contains "DRY RUN: docker image rm img1"
    assert_launcher_output_contains "DRY RUN: docker network rm net1"
    assert_docker_lacks "docker rm -f"
    assert_docker_lacks "docker image rm"
    assert_docker_lacks "docker network rm"
}

t_delete_all_no_resources() {
    # delete --all when no managed image or network exists: the discovery still
    # runs, but an empty selection must produce no removal at all - not even an
    # empty id for docker to complain about.
    run_launcher /dev/null delete --all
    assert_rc 0 "$LAUNCH_RC" "delete --all exits zero"
    assert_docker "$CPS
docker rm -f c1
docker image ls -q --filter label=dev.snowdon.opencode.workspace
docker network ls -q --filter label=dev.snowdon.opencode.managed"
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
    # All resources are discovered first, then removed: the images of every
    # managed workspace and the managed networks, minus the ones of the
    # preserved effective (child) workspace. The workspace in use is the child,
    # so the worktree-parent label it carries for worktrees of its own is queried
    # too; nothing names it as a parent here.
    assert_docker "$CPARENTPS
$child_info
$child_info
$CPS
$batch_info
docker rm -f c1
docker image ls -q --filter label=dev.snowdon.opencode.workspace=$SD/wt
docker image ls -q --filter label=dev.snowdon.opencode.workspace_parent=$SD/wt
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace=$SD/wt
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace_parent=$SD/wt
docker image ls -q --filter label=dev.snowdon.opencode.workspace
docker network ls -q --filter label=dev.snowdon.opencode.managed
docker image rm img-other
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

t_image_parent_label() {
    # The image of a worktree names its repository through the
    # dev.snowdon.opencode.workspace_parent label, which is what makes a delete
    # scoped to the repository reach the worktree's image once the worktree's
    # container is gone. The label has three links: the launcher exports
    # WORKSPACE_PARENT for a worktree launch (recorded by the mock docker), the
    # compose build file passes it as the PROJECT_WORKSPACE_PARENT build arg, and
    # the workspace Dockerfile turns that arg into the label.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    LAUNCH_CWD="$SD/wt" run_launcher /dev/null up
    unset LAUNCH_CWD
    assert_rc 0 "$LAUNCH_RC" "up in the worktree exits zero"
    assert_docker_contains "[env WORKSPACE_PARENT=$SD/ws]"

    assert_file_contains "$ROOT_DIR/compose/image/docker-compose.build.yml" \
        'PROJECT_WORKSPACE_PARENT: ${WORKSPACE_PARENT:-}'
    assert_file_contains "$ROOT_DIR/Dockerfile.example" \
        'LABEL dev.snowdon.opencode.workspace_parent="${PROJECT_WORKSPACE_PARENT}"'

    # A workspace without a worktree parent exports no parent at all.
    run_launcher /dev/null up
    assert_docker_lacks "[env WORKSPACE_PARENT="
}

t_delete_all_worktree() {
    # delete --this, then delete --all --this, from a parent repository. By the
    # second command the worktree's container is gone, so the only thing relating
    # the worktree's image and network to the repository is their own
    # worktree-parent label - the container's dev.snowdon.opencode.parent label
    # went with the container. Scoping to the repository therefore queries that
    # label too, and the worktree's resources are removed with the repository's.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    # The worktree's resources carry its own workspace plus its parent.
    OPENCODE_TEST_NO_CONTAINER=1 \
    OPENCODE_TEST_IMAGE_WS_MAP="$SD/ws=img-ws $SD/wt=img-wt" \
    OPENCODE_TEST_IMAGE_PARENT_MAP="$SD/ws=img-wt" \
    OPENCODE_TEST_NETWORK_WS_MAP="$SD/ws=net-ws $SD/wt=net-wt" \
    OPENCODE_TEST_NETWORK_PARENT_MAP="$SD/ws=net-wt" \
        run_launcher /dev/null delete --all --this

    assert_rc 0 "$LAUNCH_RC" "delete --all --this exits zero"
    # The worktree-child probe finds nothing, then the scoped discovery of the
    # parent. Docker ANDs its --filter clauses, so each label is queried on its
    # own: the repository's own resources first, then those of its worktrees.
    assert_docker "$CPARENTPS
$CPS --filter label=dev.snowdon.opencode.workspace=$SD/ws
docker image ls -q --filter label=dev.snowdon.opencode.workspace=$SD/ws
docker image ls -q --filter label=dev.snowdon.opencode.workspace_parent=$SD/ws
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace=$SD/ws
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace_parent=$SD/ws
docker image rm img-ws img-wt
docker network rm net-ws net-wt"
}

t_delete_all_worktree_other_parent() {
    # The worktree-parent label is matched exactly: a resource of another
    # repository's worktree is neither found nor removed by a delete scoped to
    # this one, even though both are managed opencode resources.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    OPENCODE_TEST_NO_CONTAINER=1 \
    OPENCODE_TEST_IMAGE_PARENT_MAP="$SD/other-ws=img-other-wt" \
    OPENCODE_TEST_NETWORK_PARENT_MAP="$SD/other-ws=net-other-wt" \
        run_launcher /dev/null delete --all --this

    assert_rc 0 "$LAUNCH_RC" "delete --all --this exits zero"
    assert_docker_lacks "docker image rm"
    assert_docker_lacks "docker network rm"
}

t_delete_all_other_worktree() {
    # --other preserves the workspace in use and its worktrees. Here the
    # worktree's container is gone, so the workspace in use is the repository
    # itself; the worktree's resources name it as their parent and are spared
    # with it, while another workspace's are removed.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    OPENCODE_TEST_NO_CONTAINER=1 \
    OPENCODE_TEST_IMAGES="img-wt img-other" \
    OPENCODE_TEST_NETWORKS="net-wt net-other" \
    OPENCODE_TEST_IMAGE_WS_MAP="$SD/ws=img-ws $SD/wt=img-wt" \
    OPENCODE_TEST_IMAGE_PARENT_MAP="$SD/ws=img-wt" \
    OPENCODE_TEST_NETWORK_WS_MAP="$SD/ws=net-ws $SD/wt=net-wt" \
    OPENCODE_TEST_NETWORK_PARENT_MAP="$SD/ws=net-wt" \
        run_launcher /dev/null delete --all --other

    assert_rc 0 "$LAUNCH_RC" "delete --all --other exits zero"
    # The resources of the workspace in use and of its worktrees are collected
    # first, then everything else is discovered and removed.
    assert_docker "$CPARENTPS
$CPS
docker image ls -q --filter label=dev.snowdon.opencode.workspace=$SD/ws
docker image ls -q --filter label=dev.snowdon.opencode.workspace_parent=$SD/ws
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace=$SD/ws
docker network ls -q $CMANAGED --filter label=dev.snowdon.opencode.workspace_parent=$SD/ws
docker image ls -q --filter label=dev.snowdon.opencode.workspace
docker network ls -q --filter label=dev.snowdon.opencode.managed
docker image rm img-other
docker network rm net-other"
}

t_ls() {
    # ls: discovers managed containers (including stopped) and prints them in a
    # ps-style table built from per-container inspect records. The record format
    # must separate fields with a Go string literal {{"\t"}} (docker inspect does
    # not interpolate a raw \t, unlike docker ps).
    run_launcher /dev/null ls
    assert_docker_contains "$CPS"
    assert_docker_contains '{{"\t"}}'
    # A running main container reports docker's own State.Status ("running"); no
    # idle probe is performed for its backend process.
    assert_launcher_output_contains "CONTAINER ID"
    assert_launcher_output_contains "STATUS"
    assert_launcher_output_contains "WORKSPACE"
    assert_launcher_output_contains "PROJECT"
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "running"
    assert_launcher_output_contains "main"
}

t_ls_stopped() {
    # A stopped container keeps its own State.Status ("exited"); a running
    # container is never probed for a backend process (docker exec is no longer
    # used for idle detection).
    OPENCODE_TEST_STATUS=exited run_launcher /dev/null ls
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
    assert_docker_contains "$CPS"
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

t_worktree_labels() {
    # A worktree workspace merges the worktree-parent label override in, right
    # after the main compose file, so compose applies the label to the container
    # (dev.snowdon.opencode.parent) and to the network labels declared in
    # docker-compose.yml (dev.snowdon.opencode.workspace_parent). The compose call
    # also carries WORKSPACE_PARENT, the env var behind the image's label.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    LAUNCH_CWD="$SD/wt" run_launcher /dev/null up
    unset LAUNCH_CWD

    # A worktree resolves straight to itself (its parent is known from the .git
    # pointer), so there is no worktree-child probe: only the list afterwards
    # queries the parent label.
    assert_docker "docker compose -p wt -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.labels.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml up -d opencode [env WORKSPACE_PARENT=$SD/ws]
$CPS --filter label=dev.snowdon.opencode.workspace=$SD/wt
$CINFO
$CPS --filter label=dev.snowdon.opencode.parent=$SD/wt
$CINFO"
    assert_launcher_output_contains "read-only locking worktree parent: $SD/ws/.git"
}

t_network_labels() {
    # A network the launcher creates itself (OPENCODE_NETWORK=@default) is
    # external to compose, so compose ignores the labels it declares for it: the
    # worktree parent is labelled on `docker network create` instead, under the
    # same key the image uses. A plain (non-worktree) workspace carries no parent
    # label at all.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    local netfile="$SD/compose/compose/net/docker-compose.network.yml"
    echo 'services: { opencode: {} }' >"$netfile"
    local dotfile="$SD/net.env"
    echo 'OPENCODE_NETWORK=@default' >"$dotfile"

    run_launcher "$dotfile" up
    unset OPENCODE_NETWORK
    # the network of a workspace without a worktree parent is unlabelled
    assert_docker_lacks "--label=dev.snowdon.opencode.workspace_parent="
    assert_docker_contains "docker network create --driver bridge --subnet=172.20."

    LAUNCH_CWD="$SD/wt" run_launcher "$dotfile" up
    unset LAUNCH_CWD OPENCODE_NETWORK
    assert_docker_contains \
        "--label=dev.snowdon.opencode.workspace_parent=$SD/ws sd-wt-default"
    # the network is external to compose, so the merge still carries the label
    # for the compose side (and is harmless there)
    assert_docker_contains "-f $netfile"
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
    assert_docker_contains "$CPS"
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
    # changes with a running container: git analysis via the container-side
    # git-changes helper (exec -T), then opencode run --agent plan --auto via
    # exec -T (non-interactive).
    run_launcher /dev/null changes
    assert_docker_contains "$CBASE ps -q opencode"
    assert_docker_contains "$CBASE exec -T -w /workspace/project opencode git-changes"
    assert_docker_contains "$CBASE exec -T -w /workspace/project opencode opencode run --agent plan --auto"
    assert_launcher_output_contains "Analyzing changes for project: ws"
}

t_changes_nocontainer() {
    # No running container -> both steps use a throwaway `compose run`, via
    # --entrypoint /bin/sh so the git-analysis helper and opencode are exec'd.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null changes
    assert_docker_contains "$CBASE ps -q opencode"
    assert_docker_contains "$CBASE run --rm -w /workspace/project --entrypoint /bin/sh opencode -c exec \"\$@\" sh git-changes"
    assert_docker_contains "$CBASE run --rm -w /workspace/project --entrypoint /bin/sh opencode -c exec \"\$@\" sh opencode run --agent plan --auto"
}

t_scaffold() {
    # scaffold expects an empty workspace; the sandbox ws is not empty, so use a
    # --path project name in the repo home, which is created (empty) for us.
    local name="proj-scaffold"
    mkdir -p "$SD/repos"
    run_launcher /dev/null scaffold --path "$name" "test task"
    # The one-off compose run uses the scaffold container name and --auto, then
    # the cleanup removes the container by name.
    assert_docker_contains "oc-scaffold-<pid> opencode exec"
    assert_docker_contains "opencode --auto"
    assert_docker_contains "docker rm -f -v oc-scaffold-<pid>"
    assert_launcher_output_contains "Creating $SD/repos/proj-scaffold"
    assert_launcher_output_contains "Running on opencode project: proj-scaffold"
}

t_scaffold_path() {
    # Without --path the positional is a real path resolved against the cwd:
    # './proj' scaffolds (creates) $PWD/proj.
    run_launcher /dev/null scaffold ./proj-scaffold "test task"
    assert_docker_contains "oc-scaffold-<pid> opencode exec"
    assert_docker_contains "docker rm -f -v oc-scaffold-<pid>"
    assert_launcher_output_contains "Creating $SD/ws/proj-scaffold"
    assert_launcher_output_contains "Running on opencode project: proj-scaffold"
}

t_bg() {
    # bg runs against an existing (non-empty) workspace: unlike scaffold there is
    # no empty-directory requirement, so the sandbox ws (which has a .git dir) is
    # used directly via './'. First positional is the path (like scaffold), the
    # second is the task.
    run_launcher /dev/null bg ./ "test task"
    # The one-off compose run uses the bg container name and runs the
    # non-interactive agent, then the cleanup removes the container by name.
    assert_docker_contains "oc-bg-<pid> opencode exec"
    assert_docker_contains "opencode run --auto"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Using existing directory: $SD/ws"
    assert_launcher_output_contains "Running background task on opencode project: ws"
}

t_bg_path() {
    # --path targets an existing project under SD_REPO_HOME. bg never creates the
    # directory (unlike scaffold), so it must already exist.
    mkdir -p "$SD/repos/proj-bg"
    run_launcher /dev/null bg --path proj-bg "test task"
    assert_docker_contains "oc-bg-<pid> opencode exec"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Using existing directory: $SD/repos/proj-bg"
    assert_launcher_output_contains "Running background task on opencode project: proj-bg"
}

t_bg_missing() {
    # bg never creates its target: a missing directory aborts before any
    # container work (no docker command is issued at all).
    local rc=0
    run_launcher /dev/null bg ./missing "test task"
    rc=$LAUNCH_RC
    assert_launcher_output_contains "bg requires an existing directory: $SD/ws/missing"
    if [[ "$rc" -eq 0 ]]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:exit")
        echo "  FAIL: bg did not exit non-zero for a missing directory"
    else
        PASS=$((PASS + 1))
        echo "  ok: bg exits non-zero for a missing directory"
    fi
    # No container was run or created.
    if grep -Fq "oc-bg-" <<<"$DOCKER_LOG"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_container")
        echo "  FAIL: bg ran a container despite a missing directory"
    else
        PASS=$((PASS + 1))
        echo "  ok: no bg container started for a missing directory"
    fi
}

t_create() {
    # create: a host-side command dispatched before workspace resolution, so it
    # never prepares compose args: the only docker call is the worktree-child
    # discovery every command makes. With --dockerfile it scaffolds
    # <workspace>/ocdocker/Dockerfile.example from the launcher's own example
    # and prints the two exports that point the compose build at it.
    run_launcher /dev/null create --dockerfile
    assert_docker "$CPARENTPS"
    assert_rc 0 "$LAUNCH_RC" "create --dockerfile exits zero"

    local dockerfile="$SD/ws/ocdocker/Dockerfile.example"
    if [[ -f "$dockerfile" ]] && cmp -s "$dockerfile" "$SD/compose/Dockerfile.example"; then
        PASS=$((PASS + 1))
        echo "  ok: ocdocker/Dockerfile.example copied from the launcher example"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:dockerfile")
        echo "  FAIL: ocdocker/Dockerfile.example is not the launcher example"
    fi
    assert_launcher_output_contains "export OPENCODE_DOCKERFILE=\"$dockerfile\""
    assert_launcher_output_contains "export OPENCODE_CONTEXT=\"$SD/ws\""
}

t_create_exists() {
    # create --dockerfile is idempotent: an existing ocdocker directory is
    # reported and left untouched (a hand-edited Dockerfile is never
    # overwritten), and the command still exits zero so it is safe to re-run in a
    # shell profile.
    mkdir -p "$SD/ws/ocdocker"
    echo 'FROM scratch' >"$SD/ws/ocdocker/Dockerfile.example"
    run_launcher /dev/null create --dockerfile
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "Docker folder already exists"
    assert_rc 0 "$LAUNCH_RC" "create exits zero when ocdocker exists"
    if [[ "$(cat "$SD/ws/ocdocker/Dockerfile.example")" == 'FROM scratch' ]]; then
        PASS=$((PASS + 1))
        echo "  ok: an existing ocdocker directory is left untouched"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:untouched")
        echo "  FAIL: an existing ocdocker directory was overwritten"
    fi
}

t_create_worktree() {
    # create --worktree creates the agent worktree uptree expects, at
    # $SD_REPO_HOME/agent-trees/<project>-dev, on a branch of the same name. It
    # is host side only: no compose args are prepared, so the only docker call is
    # the worktree-child discovery every command makes.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --worktree
    assert_docker "$CPARENTPS"
    assert_rc 0 "$LAUNCH_RC" "create --worktree exits zero"

    local wstree="$SD/repos/agent-trees/ws-dev"
    if [[ -f "$wstree/.git" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: worktree created with a .git pointer file"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:git-pointer")
        echo "  FAIL: $wstree is not a worktree"
    fi
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" "worktree $wstree"
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" "branch refs/heads/ws-dev"
    # the hint has to name both the worktree and the command that uses it
    assert_launcher_output_contains "$wstree"
    assert_launcher_output_contains "opencode:uptree \"$SD/ws\""
}

t_create_worktree_branch() {
    # The branch name is an optional positional argument of the action, so
    # '--worktree <branch>' picks it and the worktree keeps the default name.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --worktree feature/my-branch
    assert_rc 0 "$LAUNCH_RC" "create --worktree <branch> exits zero"

    local wstree="$SD/repos/agent-trees/ws-dev"
    local listed
    listed="$(git -C "$SD/ws" worktree list --porcelain)"
    assert_output_contains "$listed" "worktree $wstree"
    assert_output_contains "$listed" "branch refs/heads/feature/my-branch"
}

t_create_worktree_exists() {
    # Idempotent like --dockerfile: an existing worktree of this repository is
    # reported and left alone (its branch and any work in it are not reset), so
    # the command exits zero.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B ws-dev "$SD/repos/agent-trees/ws-dev"

    run_launcher /dev/null create --worktree
    assert_rc 0 "$LAUNCH_RC" "create --worktree exits zero for an existing worktree"
    assert_launcher_output_contains "Worktree already exists: $SD/repos/agent-trees/ws-dev"
}

t_create_worktree_exists_branch() {
    # The existing worktree keeps its branch: the requested branch is reported as
    # ignored rather than applied, so no branch is ever reset behind the user's
    # back.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B other-branch "$SD/repos/agent-trees/ws-dev"

    run_launcher /dev/null create --worktree
    assert_rc 0 "$LAUNCH_RC" "create --worktree exits zero for an existing worktree"
    assert_launcher_output_contains "On branch 'other-branch', not the requested 'ws-dev'"
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" \
        "branch refs/heads/other-branch"
}

t_create_worktree_conflict() {
    # A path that exists but is not a worktree of this repository is an error:
    # the launcher never deletes or moves it.
    make_git_workspace
    make_agent_tree_root
    mkdir -p "$SD/repos/agent-trees/ws-dev"
    echo "keep" >"$SD/repos/agent-trees/ws-dev/keep"

    run_launcher /dev/null create --worktree
    if [[ "$LAUNCH_RC" -ne 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ok: create --worktree refuses a conflicting path (rc=$LAUNCH_RC)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:rc")
        echo "  FAIL: create --worktree accepted a conflicting path"
    fi
    assert_launcher_output_contains "is not a worktree of $SD/ws"
    assert_output_contains "$(cat "$SD/repos/agent-trees/ws-dev/keep")" "keep"
}

t_create_worktree_no_root() {
    # The worktree root is the agent-trees directory, which has to exist: the
    # launcher does not create it, since SD_AGENT_TREE_ROOT may point at shared
    # storage that is mounted per host.
    make_git_workspace

    run_launcher /dev/null create --worktree
    if [[ "$LAUNCH_RC" -ne 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ok: create --worktree fails without the worktree root (rc=$LAUNCH_RC)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:rc")
        echo "  FAIL: create --worktree succeeded without the worktree root"
    fi
    assert_launcher_output_contains "no directory at the worktree root: $SD/repos/agent-trees"
}

t_create_worktree_not_git() {
    # A worktree needs a repository: the sandbox workspace carries a .git
    # directory, but not a repository, which is what this asserts against.
    make_agent_tree_root

    run_launcher /dev/null create --worktree
    if [[ "$LAUNCH_RC" -ne 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ok: create --worktree requires a git repository (rc=$LAUNCH_RC)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:rc")
        echo "  FAIL: create --worktree accepted a non-repository workspace"
    fi
    assert_launcher_output_contains "requires a git repository: $SD/ws"
    if [[ ! -e "$SD/repos/agent-trees/ws-dev" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: nothing was created for a non-repository workspace"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:created")
        echo "  FAIL: a worktree was created for a non-repository workspace"
    fi
}

t_create_both_actions() {
    # Several actions can be requested in one invocation; they run in the order
    # given, so the Dockerfile lands in the parent repository and the worktree
    # beside it. Each action resolves the effective workspace for itself, so the
    # worktree-child discovery runs once per action.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --dockerfile --worktree
    assert_docker "$CPARENTPS
$CPARENTPS"
    assert_rc 0 "$LAUNCH_RC" "create --dockerfile --worktree exits zero"

    if [[ -f "$SD/ws/ocdocker/Dockerfile.example" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: the --dockerfile action ran"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:dockerfile")
        echo "  FAIL: the --dockerfile action did not run"
    fi
    if [[ -f "$SD/repos/agent-trees/ws-dev/.git" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: the --worktree action ran"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:worktree")
        echo "  FAIL: the --worktree action did not run"
    fi
}

t_create_no_args() {
    # create has no default action: the required option names the action, and the
    # help follows the error so the options are discoverable. Nothing is resolved
    # before that error, so docker is never called.
    run_launcher /dev/null create
    if [[ "$LAUNCH_RC" -ne 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ok: create without an action exits non-zero (rc=$LAUNCH_RC)"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:rc")
        echo "  FAIL: create without an action exited zero"
    fi
    assert_docker ""
    assert_launcher_output_contains "requires an action (--dockerfile, --worktree)"
    assert_launcher_output_contains "--dockerfile"
    assert_launcher_output_contains "--worktree"
}

t_create_unknown_action() {
    # An unknown option is a usage error, and it names the option.
    run_launcher /dev/null create --unknown
    assert_rc 2 "$LAUNCH_RC" "create --unknown is a usage error"
    assert_launcher_output_contains "error: unknown option: --unknown"
}

t_create_non_git_repo() {
    # --dockerfile works without git at all: the sandbox workspace .git is not a
    # repository, and the action must not care.
    run_launcher /dev/null create --Dockerfile
    assert_rc 0 "$LAUNCH_RC" "create --Dockerfile exits zero"
    if [[ -f "$SD/ws/ocdocker/Dockerfile.example" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: the --Dockerfile alias scaffolds the workspace Dockerfile"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:dockerfile")
        echo "  FAIL: the --Dockerfile alias did not scaffold anything"
    fi
}

t_help() {
    run_launcher /dev/null help
    assert_launcher_output_contains "opencode launcher - manage the opencode container and sessions"
    assert_launcher_output_contains "Commands:"
    for cmd in start new up setup stop delete ls exec down run shell bg scaffold changes compose create help; do
        assert_launcher_output_contains "$cmd"
    done
}

t_help_cmd() {
    # help start prints the detailed start help.
    run_launcher /dev/null help start
    assert_launcher_output_contains "start [opencode args...]"
    assert_launcher_output_contains "(Re)create the opencode container"
}

t_help_create() {
    # help create documents every action and its options: the workspace
    # Dockerfile scaffold (what it writes and which exports the user has to add
    # to their environment) and the agent worktree, including the optional
    # branch name.
    run_launcher /dev/null help create
    assert_launcher_output_contains "ocdocker/Dockerfile.example"
    assert_launcher_output_contains "OPENCODE_DOCKERFILE"
    assert_launcher_output_contains "OPENCODE_CONTEXT"
    assert_launcher_output_contains "--worktree"
    assert_launcher_output_contains "branch"
}

t_help_env() {
    # The overview lists env, and the per-command help explains what it prints and
    # why a variable that is not exported is missing. 'env -h' reaches the same
    # help as 'help env'.
    run_launcher /dev/null help
    assert_launcher_output_contains "  env         Print the launcher variables exported in the environment"

    run_launcher /dev/null help env
    assert_launcher_output_contains "every SD_* and OPENCODE_* variable"
    assert_launcher_output_contains "Only exported variables appear"
    assert_docker ""

    run_launcher /dev/null env -h
    assert_launcher_output_contains "every SD_* and OPENCODE_* variable"
}

t_env() {
    # env lists the exported launcher variables and does nothing else: no
    # workspace is resolved, so the sandbox docker log stays empty.
    echo 'OPENCODE_TEST_ENV_MARKER=marker' >"$SD/env.env"
    run_launcher "$SD/env.env" env
    assert_launcher_output_contains "OPENCODE_TEST_ENV_MARKER=marker"
    assert_launcher_output_contains "SD_OPENCODE=$SD/compose"
    assert_launcher_output_lacks "Starting workspace:"
    assert_docker ""
    assert_rc 0 "$LAUNCH_RC" "env"
}

t_help_unknown() {
    # help <unknown> returns an error to stderr.
    local out
    out="$(cd "$SD/ws" && setsid env PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
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
    out="$(cd "$SD/ws" && setsid env PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
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

t_no_driver_on_path() {
    # Neither docker nor podman on PATH is fatal, and it fails on that alone.
    # The launcher exits while it is still being sourced, so the EXIT trap runs
    # the handlers registered so far; it used to follow the real error with
    # "_cleanup: command not found", because that function was defined hundreds
    # of lines further down and did not exist yet.
    # The launcher needs ordinary tools (mktemp) before it reaches the driver
    # check, so the PATH is rebuilt from symlinks to everything this host has,
    # minus docker and podman: no engine is reachable, and the launcher itself
    # still runs. Same trick as the tbin in run_launcher_no_host_opencode.
    local tbin="$SD/tbin"
    mkdir -p "$tbin"
    local dir name
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        for name in "$dir"/*; do
            [[ -x "$name" ]] || continue
            case "${name##*/}" in
                docker | podman) continue ;;
            esac
            [[ -e "$tbin/${name##*/}" ]] || ln -s "$name" "$tbin/${name##*/}"
        done
    done < <(tr ':' '\n' <<<"$PATH")
    local out rc=0
    out="$(cd "$SD/ws" && PATH="$tbin" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
        SD_YOLO=true "$tbin/setsid" "$tbin/bash" "$LAUNCHER" compose config --services \
        </dev/null 2>&1)" || rc=$?

    if [[ "$rc" -eq 1 ]] && [[ "$out" == *"found neither docker nor podman"* ]]; then
        PASS=$((PASS + 1))
        echo "  ok: no engine on PATH exits 1 with the driver diagnostic"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_driver")
        echo "  FAIL: expected rc=1 and the driver diagnostic, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi

    if [[ "$out" != *"command not found"* ]]; then
        PASS=$((PASS + 1))
        echo "  ok: the early exit leaves no stray cleanup error"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_cleanup_error")
        echo "  FAIL: the early exit reported a missing cleanup handler"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

t_no_docker() {
    # When the docker daemon is not reachable the launcher must fail loudly
    # rather than carry on: a fake docker that always fails stands in for an
    # unreachable daemon. There is no dedicated preflight probe any more, so the
    # contract asserted here is behavioural: a non-zero exit, a diagnostic on
    # stderr, and no compose/create command ever reaching docker.
    local fake_dir="$SD/fakebin"
    mkdir -p "$fake_dir"
    cat >"$fake_dir/docker" <<'FAKE'
#!/bin/bash
exit 1
FAKE
    chmod +x "$fake_dir/docker"
    local log="$SD/no-docker.log"
    : >"$log"
    local out rc=0
    out="$(cd "$SD/ws" && setsid env PATH="$fake_dir:$PATH" OPENCODE_TEST_DOCKER_LOG="$log" \
        SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" SD_YOLO=true \
        bash "$LAUNCHER" start </dev/null 2>&1)" || rc=$?

    if [[ "$rc" -ne 0 ]] && [[ -n "$out" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: no-docker run exits non-zero with a diagnostic"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_docker")
        echo "  FAIL: expected a non-zero exit and a diagnostic, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
    # Nothing that builds or starts a container may be attempted.
    if grep -Eq '^docker (compose|build|run|create) ' "$log"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:no_compose")
        echo "  FAIL: a container-creating command was attempted without docker"
        sed 's/^/    /' "$log"
    else
        PASS=$((PASS + 1))
        echo "  ok: no container-creating command attempted without docker"
    fi
}

t_outside_root_abort() {
    # With SD_YOLO=false and HOME pointing outside the workspace, a command must
    # prompt about the directory and abort (exit != 0) without reaching any
    # compose command. The prompt reads from /dev/tty, and run_launcher starts
    # the launcher with no controlling terminal (see the setsid note at the top
    # of this file), so the read fails and the default-abort path always runs
    # here. The dotfile's HOME is exported by run_launcher, so it is restored
    # afterwards to keep the rest of the suite on the caller's HOME.
    local dotfile="$SD/yolo-off.env"
    local saved_home="$HOME"
    mkdir -p "$SD/home"
    printf '%s\n' 'SD_YOLO=false' "HOME=$SD/home" >"$dotfile"
    run_launcher "$dotfile" up
    assert_docker ""
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
    export HOME="$saved_home"
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

# Contract: HOME itself, its subdirectories, and (for the "/" root shorthand)
# any non-root absolute path are valid; "/" is never a workspace root on its
# own, and a sibling/outside path is rejected. Trailing slashes are normalised
# into param 3.
norm=""; prev=""
_check_valid_within_root "$HOME/proj" "$HOME" norm prev || { echo "FAIL inside"; pass=0; }
[[ "$norm" == "$HOME/proj" ]] || { echo "FAIL norm=$norm"; pass=0; }
_check_valid_within_root "$HOME/proj/" "$HOME" norm prev || { echo "FAIL trailing"; pass=0; }
[[ "$norm" == "$HOME/proj" ]] || { echo "FAIL norm2=$norm"; pass=0; }
_check_valid_within_root "$HOME/sub" "$HOME" norm prev || { echo "FAIL deeper"; pass=0; }
_check_valid_within_root "$HOME" "$HOME" norm prev || { echo "FAIL home itself rejected"; pass=0; }
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

t_workspace_guard() {
    # Unit test for the _check_within_workspace contract behind the
    # OPENCODE_WORKSPACE guard: (starting_ws, eff_ws, has_parent). The workspace
    # is within reach when the environment workspace is unset, equals the
    # starting or effective workspace, or the worktree parent / starting path is
    # a valid root under it; a sibling is rejected. Sourcing the launcher reuses
    # the real function without docker or a terminal.
    cat >"$SD/guard.sh" <<'SCRIPT'
set +e
source "$LAUNCHER"
set +e
pass=1

env_ws="$SD_GUARD/env"
target_ws="$SD_GUARD/target"
parent_ws="$SD_GUARD/parent"
child_ws="$SD_GUARD/parent-wt"

# No environment workspace: no guard applies.
unset OPENCODE_WORKSPACE
_check_within_workspace "$target_ws" "$target_ws" "" || { echo "FAIL: unset env should be within"; pass=0; }

# Target equals the environment workspace -> within.
OPENCODE_WORKSPACE="$target_ws"
_check_within_workspace "$target_ws" "$target_ws" "" || { echo "FAIL: equal target rejected"; pass=0; }

# Target is a subdirectory of the environment workspace -> within.
_check_within_workspace "$target_ws/sub" "$target_ws/sub" "" || { echo "FAIL: subdirectory rejected"; pass=0; }
_check_within_workspace "$target_ws/sub/deep" "$target_ws/sub/deep" "" || { echo "FAIL: deep subdirectory rejected"; pass=0; }

# Target outside the environment workspace (a sibling) -> rejected.
_check_within_workspace "$env_ws" "$env_ws" "" && { echo "FAIL: sibling accepted"; pass=0; }

# Effective path changed (a child worktree opened from its parent): within while
# the environment workspace is the starting or the effective path.
OPENCODE_WORKSPACE="$target_ws"
_check_within_workspace "$target_ws" "$child_ws" "" || { echo "FAIL: started-in-env eff-change rejected"; pass=0; }
OPENCODE_WORKSPACE="$child_ws"
_check_within_workspace "$target_ws" "$child_ws" "" || { echo "FAIL: eff-equals-env rejected"; pass=0; }
OPENCODE_WORKSPACE="$env_ws"
_check_within_workspace "$target_ws" "$child_ws" "" && { echo "FAIL: unrelated eff-change accepted"; pass=0; }

# Going up a worktree (starting == effective, parent known): allowed when the
# parent or the starting workspace is within the environment workspace, rejected
# when neither is.
OPENCODE_WORKSPACE="$parent_ws"
_check_within_workspace "$child_ws" "$child_ws" "$parent_ws" || { echo "FAIL: worktree parent rejected"; pass=0; }
OPENCODE_WORKSPACE="$SD_GUARD"
_check_within_workspace "$child_ws" "$child_ws" "$parent_ws" || { echo "FAIL: worktree under env rejected"; pass=0; }
OPENCODE_WORKSPACE="$target_ws"
_check_within_workspace "$child_ws" "$child_ws" "$parent_ws" && { echo "FAIL: unrelated worktree parent accepted"; pass=0; }

((pass)) && echo "workspace_guard ok" || echo "workspace_guard FAIL"
SCRIPT
    local out
    out="$(PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" \
        SD_GUARD="$SD" bash "$SD/guard.sh")"
    if grep -Fq "workspace_guard ok" <<<"$out"; then
        PASS=$((PASS + 1))
        echo "  ok: OPENCODE_WORKSPACE guard contract"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:guard")
        echo "  FAIL: OPENCODE_WORKSPACE guard contract"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

t_labels_override() {
    # Unit test for the worktree-parent label override: the container label goes
    # on the opencode service (what the container discovery filters on), and the
    # network label - the key delete queries to reach a worktree's resources - is
    # merged into the extra-network, where compose adds it to the labels already
    # declared for the network in docker-compose.yml. Values are quoted, so a path
    # holding YAML-significant characters stays a single scalar, and a trailing
    # slash is normalised away. Sourcing the launcher reuses the real writer
    # without docker or a terminal.
    cat >"$SD/labels.sh" <<'SCRIPT'
set +e
source "$LAUNCHER"
set +e
pass=1

mkdir -p "$tmp_compose_dir"

check() {
    # check <description> <needle>
    if grep -Fq -- "$2" "$tmp_labels_file"; then
        echo "    ok: $1"
    else
        echo "    FAIL: $1 (missing: $2)"
        cat "$tmp_labels_file" | sed 's/^/    /'
        pass=0
    fi
}
check_lacks() {
    if grep -Fq -- "$2" "$tmp_labels_file"; then
        echo "    FAIL: $1 (unexpected: $2)"
        cat "$tmp_labels_file" | sed 's/^/    /'
        pass=0
    else
        echo "    ok: $1"
    fi
}

_write_labels_override '/home/other/repos/myproject'
check "service carries the container parent label" \
    '- "dev.snowdon.opencode.parent=/home/other/repos/myproject"'
check "network carries the workspace parent label" \
    'dev.snowdon.opencode.workspace_parent: "/home/other/repos/myproject"'
check "network section is the compose one" '  extra-network:'
# compose merges labels key by key, so the override must not repeat (and
# overwrite) the managed/workspace labels the compose file already declares
check_lacks "managed/workspace labels are left to docker-compose.yml" \
    'dev.snowdon.opencode.managed'
check_lacks "managed/workspace labels are left to docker-compose.yml" \
    'dev.snowdon.opencode.workspace:'

# A trailing slash is stripped, and YAML-significant characters in the path are
# escaped rather than ending the scalar early.
_write_labels_override '/home/other/re ird: repo/myproject/"\wt"#1'
check "path with YAML syntax is escaped and unslashed" \
    'dev.snowdon.opencode.workspace_parent: "/home/other/re ird: repo/myproject/\"\\wt\"#1"'

((pass)) && echo "labels_override ok" || echo "labels_override FAIL"
SCRIPT
    local out
    out="$(PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" bash "$SD/labels.sh")"
    # the checks run in the sourced script and report themselves, so the whole
    # contract is asserted in one go
    printf '%s\n' "$out"
    if grep -Fq "labels_override ok" <<<"$out"; then
        PASS=$((PASS + 1))
        echo "  ok: worktree-parent label override contract"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$CURRENT:labels")
        echo "  FAIL: worktree-parent label override contract"
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
