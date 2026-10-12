#!/usr/bin/env bash
# Shared test helpers for scripts/launcher.sh, loaded by every Bats suite under
# tests/ with `load 'lib/helpers'`. It provides the sandbox makers, the launcher
# runners that drive the script against the mocked docker/curl/opencode
# binaries, the assertion layer, and the setup()/teardown() sandbox lifecycle.
#
# The mocks (tests/mockbin/) record what the launcher does, so the actual docker
# invocations are printed and asserted WITHOUT anything being executed. This
# lets you see exactly which docker commands the launcher would run for a given
# subcommand, and verifies they are correct. No Docker daemon is required.
set -u

# These globals are the library's interface with the suites that load it:
# CBASE/CPS/CPARENTPS/CMANAGED/CWSPS/CINFO hold the expected command strings,
# LAUNCH_RC/LAUNCH_OUT/DOCKER_LOG the last run's results, CACHEVOL the cache
# override dir. They are written here and read by the test files, which this
# tool cannot analyse, hence the file-wide SC2034 disable below.
# shellcheck disable=SC2034

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HELPERS_DIR/.." && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LAUNCHER="$ROOT_DIR/scripts/launcher.sh"
MOCKBIN="$TESTS_DIR/mockbin"

# The launcher prompts on /dev/tty when a workspace is outside $HOME (or outside
# $OPENCODE_WORKSPACE). It is therefore always run through `setsid`, which puts
# it in a new session with no controlling terminal: without that, an interactive
# `make test` hands the launcher the developer's terminal and the read blocks
# there (swallowing keystrokes) until Enter is pressed. Detached, /dev/tty
# cannot be opened, so the prompt always takes its default-abort path and the
# suite behaves the same from a terminal, a pipe or CI. util-linux and busybox
# both ship setsid. The runners below pair it with SD_YOLO=true, the launcher's
# "don't ask" flag, so the confirmations it can ask without a terminal are
# skipped as well.
if ! command -v setsid >/dev/null 2>&1; then
    echo "Error: setsid is required to run the tests (provided by util-linux or busybox)" >&2
    return 1
fi

# Boolean check for ad-hoc conditions that have no assertion of their own.
#   fail <message>
fail() {
    echo "FAIL: $1" >&2
    return 1
}

# --- sandbox makers -----------------------------------------------------

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
    # The launcher injects a per-component skill for the image it selected
    # (skills/available-<component>-tools/SKILL.md, with the component derived
    # for the default image tag too) by copying it into the project config
    # directory. It reads it from $SD_OPENCODE/opencode/skills, so the sandbox
    # carries the real skill files in their real layout: a launch with a
    # selected component would otherwise find no skill to copy.
    mkdir -p "$SD/compose/opencode" "$SD/compose/compose/env"
    cp -r "$ROOT_DIR/opencode/skills" "$SD/compose/opencode/"
    # The launcher's own storage roots (config/data/cache) default to paths
    # under $HOME, which are exactly what a running container's bind mounts
    # are built from - a suite run must never read, seed or create them, so
    # they point into the sandbox. Pre-created as well, so the missing-
    # directory prompt never fires for them: the tests that exercise that
    # prompt point the roots back at a bare home themselves.
    mkdir -p "$SD/config-root" "$SD/data-root" "$SD/cache-root"
    export OPENCODE_CONFIG_ROOT="$SD/config-root"
    export OPENCODE_DATA_ROOT="$SD/data-root"
    export OPENCODE_CACHE_ROOT="$SD/cache-root"
    # Set up env files for tests - password is included for v2 server mode
    cp "$ROOT_DIR/compose/env/docker-compose.password.yml" "$SD/compose/compose/env/" 2>/dev/null || echo 'services: { opencode: {} }' >"$SD/compose/compose/env/docker-compose.password.yml"
    # The api key secret declaration, merged only by the launches that read a
    # key file (see t_secret_key_file_merges): the sandbox needs it at the path
    # the launcher computes from SD_OPENCODE, or that merge aborts with
    # "not a regular file".
    mkdir -p "$SD/compose/compose/secret"
    cp "$ROOT_DIR/compose/secret/docker-compose.secret.yml" "$SD/compose/compose/secret/"
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
    # _opencode_args_prepare merges them: main file, [cache], image, read-only
    # volume mounts, port. The volume override lives in a mktemp dir and is
    # normalised to <tmp>.
    CBASE="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/compose.rovols.yaml -f $SD/compose/compose/sys/docker-compose.port.yml"
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
# mount of the container tests. The committer is configured in the repository
# itself, so tests adding commits do not have to repeat the -c overrides.
make_git_workspace() {
    rm -rf "$SD/ws/.git"
    git -C "$SD/ws" init -q
    git -C "$SD/ws" config user.email launcher@tests
    git -C "$SD/ws" config user.name launcher
    git -C "$SD/ws" commit -q --allow-empty -m init
}

# The agent worktree root that `create --worktree` and `uptree` agree on:
# $SD_REPO_HOME/agent-trees (SD_REPO_HOME is $SD/repos in the sandbox).
make_agent_tree_root() {
    mkdir -p "$SD/repos/agent-trees"
}

# --- sandbox lifecycle --------------------------------------------------
# Replaces the legacy runner's per-test make_sandbox / rm -rf pair.

setup() {
    make_sandbox
}

teardown() {
    rm -rf -- "$SD"
    SD=""
}

# --- launcher runners ---------------------------------------------------

# Run the launcher, capturing both the launcher's stdout/err and the mock
# docker log. Nondeterministic temp paths (compose.rovols.yaml) are
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
    # The api key file the launcher reads before composing, pointed at a path
    # that does not exist: a developer's real
    # ~/.config/opencode-docker/opencode.key must not merge the secret into the
    # expectations below. The secret tests override it through their dotfile.
    export OPENCODE_KEY_FILE="$SD/no-opencode.key"
    : >"$OPENCODE_TEST_DOCKER_LOG"
    # The compose files handed to docker are captured per invocation, too: the
    # launcher's generated overrides live in a mktemp dir it removes on exit,
    # so this is the only place a test can inspect them
    # (assert_override_contains / assert_override_lacks).
    export OPENCODE_TEST_OVERRIDE_LOG="$SD/override.log"
    : >"$OPENCODE_TEST_OVERRIDE_LOG"

    # Optional env overrides
    if [[ -f "$dotfile" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$dotfile"
        set +a
    fi

    local out
    # LAUNCH_STDIN_FILE, when set, is fed to the launcher's stdin instead of
    # /dev/null: io reads its task from stdin. Consumed by the call, so it
    # cannot reach the next one.
    local stdin_file="${LAUNCH_STDIN_FILE:-/dev/null}"
    unset LAUNCH_STDIN_FILE
    # A non-zero launcher exit is a result the tests assert on (assert_rc,
    # [[ "$LAUNCH_RC" -ne 0 ]]), not an error of this helper: record the code
    # and keep going, the way bats' `run` disables errexit around its command.
    # The legacy runner had no errexit; without this guard Bats aborts the
    # test right here before any assertion runs.
    LAUNCH_RC=0
    out="$(cd "${LAUNCH_CWD:-$SD/ws}" && setsid bash "$LAUNCHER" "$cmd" "$@" \
        <"$stdin_file" 2>&1)" || LAUNCH_RC=$?

    # Keep only the launcher's own output lines, dropping mock echoes. A command
    # whose entire output is mock echoes (delete) leaves grep with nothing to
    # print and a status of 1; `|| true` keeps the legacy semantics (an empty
    # LAUNCH_OUT, not a failed helper) under the tests' errexit.
    LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:' || true)"

    # Normalise the docker log: collapse the nondeterministic temp files the
    # launcher generates per run (the read-only volume override, the worktree
    # label override, the io mount override) and the scaffold/bg/io container
    # pids.
    DOCKER_LOG="$(sed -E \
        -e 's#-f [^ ]*compose\.rovols\.yaml#-f <tmp>/compose.rovols.yaml#g' \
        -e 's#-f [^ ]*docker-compose\.labels\.yml#-f <tmp>/docker-compose.labels.yml#g' \
        -e 's#-f [^ ]*docker-compose\.io\.yml#-f <tmp>/docker-compose.io.yml#g' \
        -e 's/oc-scaffold-[0-9]+/oc-scaffold-<pid>/g' \
        -e 's/oc-changes-[0-9]+/oc-changes-<pid>/g' \
        -e 's/oc-bg-[0-9]+/oc-bg-<pid>/g' \
        -e 's/oc-io-[0-9]+/oc-io-<pid>/g' \
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
    # Same image URL pinning as run_launcher: the overlay set (password file,
    # version layer, ...) a command composes is only deterministic when the
    # launcher sees a known tag. The legacy runner never set these here - its
    # long-lived shell carried run_launcher's exports over from earlier tests -
    # and Bats isolates every test, so the runner pins them itself.
    if [[ "${LAUNCH_NO_IMAGE_URL:-}" == 1 ]]; then
        unset OPENCODE_IMAGE_URL OPENCODE_IMAGE_URL_TUI
    else
        export OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:duck-v2"
        export OPENCODE_IMAGE_URL_TUI="devsnowdon/opencode-docker:empty-v2"
    fi
    export SD_OPENCODE="$SD/compose"
    export SD_REPO_HOME="$SD/repos"
    export SD_YOLO=true
    # Same default as run_launcher: no key file, so no secret is merged unless
    # a test points OPENCODE_KEY_FILE at one.
    export OPENCODE_KEY_FILE="$SD/no-opencode.key"
    : >"$OPENCODE_TEST_DOCKER_LOG"
    # The compose files handed to docker are captured per invocation, too: the
    # launcher's generated overrides live in a mktemp dir it removes on exit,
    # so this is the only place a test can inspect them
    # (assert_override_contains / assert_override_lacks).
    export OPENCODE_TEST_OVERRIDE_LOG="$SD/override.log"
    : >"$OPENCODE_TEST_OVERRIDE_LOG"

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
    # Same errexit guard as run_launcher: a non-zero launcher exit is a result
    # the tests assert on (assert_rc, [[ "$LAUNCH_RC" -ne 0 ]]), not an error
    # of this helper, so record the code and keep going instead of letting the
    # tests' errexit abort before any assertion runs.
    LAUNCH_RC=0
    out="$(cd "$SD/ws" && setsid env PATH="$tbin$new_path" \
        OPENCODE_TEST_NO_HOST_TUI=1 \
        OPENCODE_TEST_DOCKER_LOG="$SD/docker.log" \
        SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" SD_YOLO=true \
        bash "$LAUNCHER" "$cmd" "$@" </dev/null 2>&1)" || LAUNCH_RC=$?

    LAUNCH_OUT="$(printf '%s\n' "$out" | grep -v '^mocked:' || true)"
    DOCKER_LOG="$(sed -E \
        -e 's#-f [^ ]*compose\.rovols\.yaml#-f <tmp>/compose.rovols.yaml#g' \
        -e 's#-f [^ ]*docker-compose\.labels\.yml#-f <tmp>/docker-compose.labels.yml#g' \
        -e 's#-f [^ ]*docker-compose\.io\.yml#-f <tmp>/docker-compose.io.yml#g' \
        -e 's/oc-scaffold-[0-9]+/oc-scaffold-<pid>/g' \
        -e 's/oc-changes-[0-9]+/oc-changes-<pid>/g' \
        -e 's/oc-bg-[0-9]+/oc-bg-<pid>/g' \
        -e 's/oc-io-[0-9]+/oc-io-<pid>/g' \
        "$OPENCODE_TEST_DOCKER_LOG")"
}

# --- assertions ---------------------------------------------------------
# Same signatures and diagnostics as the legacy runner's, minus the PASS/FAIL
# bookkeeping: print nothing on success (Bats hides it anyway), print the
# diagnostics and return 1 on failure.

# Assert that docker was called (in order) exactly the given commands.
#   assert_docker <expected-multiline-string>
assert_docker() {
    local expected="$1"
    if [[ "$DOCKER_LOG" == "$expected" ]]; then
        return 0
    fi
    echo "FAIL: docker commands differ"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$DOCKER_LOG") | sed 's/^/    /'
    return 1
}

# Assert that the docker log contains at least the given line (in order).
#   assert_docker_contains <needle>
assert_docker_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$DOCKER_LOG"; then
        return 0
    fi
    echo "FAIL: docker log does not contain: $needle"
    echo "--- docker log ---"
    printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
    return 1
}

# Assert that docker was NOT called with the given line.
#   assert_docker_lacks <needle>
assert_docker_lacks() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$DOCKER_LOG"; then
        echo "FAIL: docker log unexpectedly contains: $needle"
        echo "--- docker log ---"
        printf '%s\n' "$DOCKER_LOG" | sed 's/^/    /'
        return 1
    fi
    return 0
}

# Assert that the compose files docker was handed contain / lack the given
# line. The mock records their contents at invocation (the launcher deletes
# its generated overrides on exit), so this is how a test inspects what an
# override actually merges - a mount, a label - rather than only the -f flag.
#   assert_override_contains <needle>
#   assert_override_lacks <needle>
assert_override_contains() {
    local needle="$1"
    if [[ -f "${OPENCODE_TEST_OVERRIDE_LOG:-}" ]] &&
        grep -Fq -- "$needle" "$OPENCODE_TEST_OVERRIDE_LOG"; then
        return 0
    fi
    echo "FAIL: compose file contents do not contain: $needle"
    _print_override_log
    return 1
}

assert_override_lacks() {
    local needle="$1"
    if [[ -f "${OPENCODE_TEST_OVERRIDE_LOG:-}" ]] &&
        grep -Fq -- "$needle" "$OPENCODE_TEST_OVERRIDE_LOG"; then
        echo "FAIL: compose file contents unexpectedly contain: $needle"
        _print_override_log
        return 1
    fi
    return 0
}

# Diagnostics for the override assertions: the recorded compose file contents,
# indented, or a note when nothing was recorded (a launcher run that never
# reached a compose command, e.g. an early abort).
_print_override_log() {
    echo "--- compose file contents ---"
    if [[ -f "${OPENCODE_TEST_OVERRIDE_LOG:-}" ]]; then
        sed 's/^/    /' "$OPENCODE_TEST_OVERRIDE_LOG"
    else
        echo "    (none recorded)"
    fi
    return 0
}

# Assert that the launcher's own output (stdout/stderr) contains the given text.
#   assert_launcher_output_contains <needle>
assert_launcher_output_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$LAUNCH_OUT"; then
        return 0
    fi
    echo "FAIL: launcher output does not contain: $needle"
    echo "--- launcher output ---"
    printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
    return 1
}

# Assert that the launcher's own output does NOT contain the given needle.
#   assert_launcher_output_lacks <needle>
assert_launcher_output_lacks() {
    local needle="$1"
    if grep -Fq -- "$needle" <<<"$LAUNCH_OUT"; then
        echo "FAIL: launcher output unexpectedly contains: $needle"
        echo "--- launcher output ---"
        printf '%s\n' "$LAUNCH_OUT" | sed 's/^/    /'
        return 1
    fi
    return 0
}

# Assert that a command exited with the given status.
#   assert_rc <expected-rc> <actual-rc> <description>
assert_rc() {
    local expected="$1"
    local actual="$2"
    local what="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        return 0
    fi
    echo "FAIL: $what (expected rc=$expected, got rc=$actual)"
    return 1
}

# Assert that the file contains the given needle.
#   assert_file_contains <path> <needle>
assert_file_contains() {
    local path="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$path"; then
        return 0
    fi
    echo "FAIL: $path does not contain: $needle"
    return 1
}

# Assert that the given text contains the given needle.
#   assert_output_contains <text> <needle>
assert_output_contains() {
    local text="$1"
    local needle="$2"
    if grep -Fq -- "$needle" <<<"$text"; then
        return 0
    fi
    echo "FAIL: output does not contain: $needle"
    printf '%s\n' "$text" | sed 's/^/    /'
    return 1
}

# Assert that the given text does NOT contain the given needle.
#   assert_output_lacks <text> <needle>
assert_output_lacks() {
    local text="$1"
    local needle="$2"
    if grep -Fq -- "$needle" <<<"$text"; then
        echo "FAIL: output unexpectedly contains: $needle"
        printf '%s\n' "$text" | sed 's/^/    /'
        return 1
    fi
    return 0
}

# Assert that the given text holds the given line, as a whole line (fixed
# string). Needed where a needle is a prefix of another line: git-changes
# echoes the commands it runs, and "$ git diff" must not be satisfied by
# "$ git diff --cached".
#   assert_output_has_line <text> <line>
assert_output_has_line() {
    local text="$1"
    local line="$2"
    if grep -Fxq -- "$line" <<<"$text"; then
        return 0
    fi
    echo "FAIL: output has no line: $line"
    printf '%s\n' "$text" | sed 's/^/    /'
    return 1
}

# Assert that the given text holds no such line.
#   assert_output_lacks_line <text> <line>
assert_output_lacks_line() {
    local text="$1"
    local line="$2"
    if grep -Fxq -- "$line" <<<"$text"; then
        echo "FAIL: output unexpectedly has the line: $line"
        printf '%s\n' "$text" | sed 's/^/    /'
        return 1
    fi
    return 0
}

# --- toolchain cache helpers -------------------------------------------

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

# --- command-specific test helpers --------------------------------------

# Write the env file the io and changes output tests hand to run_launcher: it
# points the mock at the output paths to fill in (OPENCODE_TEST_IO_OUTPUT, one
# per line - a directory output gets a file written inside it) and the content
# (OPENCODE_TEST_IO_PLAN, "mocked io plan" here as everywhere), standing in for
# the agent writing them. An empty first argument means "write nothing", which
# is how the empty-output tests run.
#   _io_plan_env <output>...
_io_plan_env() {
    local outputs=""
    local p
    for p in "$@"; do
        [[ -n "$p" ]] && outputs+="$p"$'\n'
    done
    printf 'OPENCODE_TEST_IO_OUTPUT=%q\nOPENCODE_TEST_IO_PLAN=%q\n' \
        "$outputs" "mocked io plan" >"$SD/io.env"
}
