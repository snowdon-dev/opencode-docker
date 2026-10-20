#!/usr/bin/env bats
# README group "Start & one-off runs": opencode (start), opencode:scaffold,
# opencode:bg, opencode:changes, opencode:io, opencode:repl — attach a TUI or
# run a one-off agent task.

load 'lib/helpers'

@test "start" {
    # start: warn on other running workspaces -> ensure_up (up -d) -> resolve the
    # published backend port (compose port) -> backend health (mocked curl returns
    # skipped) -> TUI via scripts/v2/start-tui.sh, which runs the mocked
    # `opencode --server` against the resolved host port -> ps.
    # The default image layer is v2, so the health path is "/" and the TUI takes
    # the backend as a global flag; t_start_v1 pins v1 for the other branch.
    run_launcher /dev/null start --verbose --model gpt
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "$CBASE up -d opencode"
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode --server http://127.0.0.1:32768 --model gpt"
    assert_docker_contains "$CBASE ps -q -a opencode"
    assert_launcher_output_contains "Backend ready. Attaching..."
}

@test "start_v1" {
    # OPENCODE_IMAGE_VERSION=v1 pins the v1 layer: the health endpoint is
    # /api/health and the TUI comes from scripts/v1/start-tui.sh, which runs
    # `opencode attach <url>` because v1 has no global --server flag. v2 dropped
    # attach, so this also proves the version actually selects the script.
    OPENCODE_IMAGE_VERSION=v1 run_launcher /dev/null start --model gpt
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode attach http://127.0.0.1:32768 --model gpt"
    # The v2 entrypoint must not be used.
    assert_docker_lacks "opencode --server"
}

@test "start_v2" {
    # OPENCODE_IMAGE_VERSION=v2 selects the v2 layer (also the default): the
    # health endpoint is "/", and the TUI comes from scripts/v2/start-tui.sh,
    # which runs `opencode --server <url>` because v2 dropped `opencode attach`.
    # Everything else about the sequence is identical.
    OPENCODE_IMAGE_VERSION=v2 run_launcher /dev/null start --model gpt
    assert_docker_contains "$CBASE port opencode 4096"
    assert_docker_contains "curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "opencode --server http://127.0.0.1:32768 --model gpt"
    # The v1 entrypoint must not be used.
    assert_docker_lacks "opencode attach"
}

@test "start_v2_missing_script" {
    # A version whose scripts/<version>/start-tui.sh is not in the repository
    # must fail with a clear message instead of silently running nothing.
    OPENCODE_IMAGE_VERSION=v3 run_launcher /dev/null start --model gpt
    assert_launcher_output_contains "The TUI script for opencode v3 is missing"
    assert_docker_lacks "opencode attach"
}

@test "start_port_fail" {
    # If the backend port cannot be resolved (e.g. no port mapping), start must
    # abort with a helpful message rather than attach to a bogus address.
    local rc=0
    OPENCODE_TEST_PORT_FAIL=1 run_launcher /dev/null start --model gpt
    rc=$LAUNCH_RC
    assert_launcher_output_contains "Failed to resolve the published backend port"
    assert_launcher_output_contains "opencode:compose port opencode 4096"
    [[ "$rc" -ne 0 ]] || fail "start did not exit non-zero after port resolution failure"
    # Must NOT have attempted the health check or attach.
    assert_docker_lacks "opencode attach"
}

@test "start_other_workspace" {
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

@test "start_build_fail" {
    # start when `compose up` fails (e.g. build failure) must abort rather than
    # proceeding to the backend health check and attach.
    local rc=0
    OPENCODE_TEST_BUILD_FAIL=1 run_launcher /dev/null start --model gpt
    rc=$LAUNCH_RC
    assert_launcher_output_contains "Failed to start the opencode container"
    [[ "$rc" -ne 0 ]] || fail "start did not exit non-zero after build failure"
    # Must NOT have attempted the backend health check or attach (no exec/attach).
    assert_docker_lacks "opencode attach"
}

@test "start_no_host_tui" {
    # Without a host opencode CLI the throwaway `tui` service attaches to the
    # backend over the compose network: the port override is NOT merged, no host
    # port is published or resolved, and the backend health check runs from
    # inside the container (the host cannot reach the compose service name).
    # Inside the network the backend is on its private port, so the probe URL is
    # the service name and the container port (http://opencode:4096 + the v2
    # health path), never a published host port.
    # The service's command is `start-tui 0` (docker-compose.yml), so the
    # launcher only forwards the origin and the user's own arguments.
    run_launcher_no_host_opencode /dev/null start --verbose --model gpt

    # The compose args must NOT include the port override.
    local cbase_no_port="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/compose.rovols.yaml"
    assert_docker_contains "$cbase_no_port up -d opencode"
    assert_docker_contains "$cbase_no_port exec -T opencode curl -fsS --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:4096"
    assert_docker_contains "$cbase_no_port run --rm --remove-orphans -e BACKEND_ORIGIN=http://opencode:4096 tui --model gpt"
    assert_launcher_output_contains "Backend: http://opencode:4096"
    assert_docker_lacks "docker-compose.port.yml"
    assert_docker_lacks "port opencode 4096"
}

@test "start_waits_for_backend_in_container" {
    # Without a host opencode CLI there is no published port, so the wait runs
    # inside the container, where the compose service name resolves. The mocked
    # container's health probe fails, which is what drives start down the wait
    # path; the mocked `waitforserver` then succeeds. The TUI is then run as the
    # one-off `tui` service, whose command is the container-side start-tui.
    OPENCODE_TEST_HEALTH_FAIL=1 run_launcher_no_host_opencode /dev/null start --verbose --model gpt
    local cbase_no_port="docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/compose.rovols.yaml"
    assert_docker_contains "$cbase_no_port exec -d -w /workspace/project opencode /entrypoint.sh start-serve-backend"
    assert_docker_contains "$cbase_no_port exec -T -w /workspace/project opencode waitforserver http://127.0.0.1:4096"
    assert_docker_contains "$cbase_no_port run --rm --remove-orphans -e BACKEND_ORIGIN=http://opencode:4096 tui --model gpt"
    assert_launcher_output_contains "Waiting for the opencode backend to launch"
}

@test "waitforserver" {
    # scripts/waitforserver.sh on its own: the origin comes from the argument or
    # the environment, the wait is bounded, and a bad timeout is rejected.
    # Every capture is guarded (`|| rc=$?`) and rc reset first: Bats runs the
    # body under errexit, so a bare `out="$(...)"; rc=$?` would abort the test
    # on the sub-cases expected to exit non-zero before assert_rc sees the code.
    local out rc
    rc=0
    out="$(PATH="$MOCKBIN:$PATH" bash "$ROOT_DIR/scripts/waitforserver.sh" \
        http://127.0.0.1:32768 2>&1)" || rc=$?
    assert_rc 0 "$rc" "waitforserver succeeds once the backend answers"

    rc=0
    out="$(PATH="$MOCKBIN:$PATH" BACKEND_ORIGIN=http://opencode:4096 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" 2>&1)" || rc=$?
    assert_rc 0 "$rc" "waitforserver falls back to \$BACKEND_ORIGIN"

    # The mock curl counts its calls in a file, so the poll count survives
    # across the separate processes waitforserver spawns.
    : >"$SD/curl.count"
    rc=0
    out="$(PATH="$MOCKBIN:$PATH" OPENCODE_TEST_CURL_COUNT_FILE="$SD/curl.count" \
        OPENCODE_TEST_HEALTH_AFTER=1 WAITFORSERVER_TIMEOUT=5 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" http://127.0.0.1:32768 2>&1)" || rc=$?
    assert_rc 0 "$rc" "waitforserver polls until the backend answers"

    rc=0
    out="$(PATH="$MOCKBIN:$PATH" OPENCODE_TEST_HEALTH_FAIL=1 WAITFORSERVER_TIMEOUT=1 \
        bash "$ROOT_DIR/scripts/waitforserver.sh" http://127.0.0.1:32768 2>&1)" || rc=$?
    assert_rc 1 "$rc" "waitforserver times out when the backend never answers"
    assert_output_contains "$out" "(limit 1s) waiting for http://127.0.0.1:32768"

    rc=0
    out="$(PATH="$MOCKBIN:$PATH" bash "$ROOT_DIR/scripts/waitforserver.sh" \
        http://127.0.0.1:32768 soon 2>&1)" || rc=$?
    assert_rc 2 "$rc" "waitforserver rejects a non-numeric timeout"
    assert_output_contains "$out" "timeout must be a positive whole number of seconds"
}

@test "scaffold" {
    # scaffold expects an empty workspace; the sandbox ws is not empty, so use a
    # --path project name in the repo home, which is created (empty) for us.
    local name="proj-scaffold"
    mkdir -p "$SD/repos"
    run_launcher /dev/null scaffold --verbose --path "$name" "test task"
    # The one-off compose run uses the scaffold container name and --auto, then
    # the cleanup removes the container by name.
    assert_docker_contains "oc-scaffold-<pid> opencode opencode run --auto"
    assert_docker_contains "docker rm -f -v oc-scaffold-<pid>"
    assert_launcher_output_contains "Creating $SD/repos/proj-scaffold"
    assert_launcher_output_contains "Running on opencode project: proj-scaffold"
}

@test "scaffold_target" {
    # --target is a real path resolved against the cwd: './proj' scaffolds
    # (creates) $PWD/proj.
    run_launcher /dev/null scaffold --verbose --target ./proj-scaffold "test task"
    assert_docker_contains "oc-scaffold-<pid> opencode opencode run --auto"
    assert_docker_contains "docker rm -f -v oc-scaffold-<pid>"
    assert_launcher_output_contains "Creating $SD/ws/proj-scaffold"
    assert_launcher_output_contains "Running on opencode project: proj-scaffold"
}

@test "bg" {
    # bg runs against an existing (non-empty) workspace: unlike scaffold there is
    # no empty-directory requirement, so the sandbox ws (which has a .git dir) is
    # used directly via --target ./.
    run_launcher /dev/null bg --verbose --target ./ "test task"
    # The one-off compose run uses the bg container name and runs the
    # non-interactive agent, then the cleanup removes the container by name.
    assert_docker_contains "oc-bg-<pid> opencode opencode run --auto"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Using existing directory: $SD/ws"
    assert_launcher_output_contains "Running background task on opencode project: ws"
}

@test "bg_path" {
    # --path targets an existing project under SD_REPO_HOME. bg never creates the
    # directory (unlike scaffold), so it must already exist.
    mkdir -p "$SD/repos/proj-bg"
    run_launcher /dev/null bg --verbose --path proj-bg "test task"
    assert_docker_contains "oc-bg-<pid> opencode opencode run --auto"
    assert_docker_contains "docker rm -f -v oc-bg-<pid>"
    assert_launcher_output_contains "Using existing directory: $SD/repos/proj-bg"
    assert_launcher_output_contains "Running background task on opencode project: proj-bg"
}

@test "bg_missing" {
    # bg never creates its target: a missing directory aborts before any
    # container work (no docker command is issued at all).
    local rc=0
    run_launcher /dev/null bg --target ./missing "test task"
    rc=$LAUNCH_RC
    assert_launcher_output_contains "bg requires an existing directory: $SD/ws/missing"
    [[ "$rc" -ne 0 ]] || fail "bg did not exit non-zero for a missing directory"
    # No container was run or created.
    assert_docker_lacks "oc-bg-"
}

@test "changes" {
    # changes with a running container: git analysis via the container-side
    # git-changes helper (exec -T), then opencode run --agent plan --auto via
    # exec -T (non-interactive).
    run_launcher /dev/null changes --verbose
    assert_docker_contains "$CBASE ps -q opencode"
    assert_docker_contains "$CBASE exec -T -w /workspace/project opencode /entrypoint.sh git-changes"
    assert_docker_contains "$CBASE exec -T -w /workspace/project opencode /entrypoint.sh opencode run --agent plan --auto"
    assert_launcher_output_contains "Analyzing changes for project: ws"
}

@test "changes_nocontainer" {
    # No running container -> both steps use a throwaway `compose run`, run
    # with the service's own entrypoint so the helper and opencode are exec'd
    # directly.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null changes
    assert_docker_contains "$CBASE ps -q opencode"
    assert_docker_contains "$CBASE run --rm -w /workspace/project opencode git-changes"
    assert_docker_contains "$CBASE run --rm -w /workspace/project opencode opencode run --agent plan --auto"
}

@test "changes_output" {
    # changes --output switches the agent step to the io machinery: the git
    # changes are gathered first with the normal read-write mounts (no io
    # override may be on that command), then the plan agent runs on its own
    # one-off oc-changes container carrying the override, told it can only
    # write to the declared output.
    _io_plan_env "$SD/changes-plan.md"
    run_launcher "$SD/io.env" changes --output "$SD/changes-plan.md" "analyse and plan"

    # The gather composes from the plain args: the io override joins them only
    # afterwards, so no command carrying it may have been the gather.
    assert_docker_contains "$CBASE exec -T -w /workspace/project opencode /entrypoint.sh git-changes"
    assert_docker_lacks "$CBASE -f <tmp>/docker-compose.io.yml exec"
    # The agent step: the io override plus a one-off oc-changes container
    # running a plain `opencode run` - never the plan agent, which would refuse
    # to write the plan file itself, and never the running container's exec.
    assert_docker_contains "$CBASE -f <tmp>/docker-compose.io.yml run --rm -T --name oc-changes-<pid>"
    assert_docker_contains "opencode run --auto"
    assert_docker_lacks "opencode run --auto --agent plan"
    # The prompt carries the branch changes and the writable-surface rules.
    assert_docker_contains "stdin: <task-information>"
    assert_docker_contains "Branch changes:"
    assert_docker_contains "Write your output only to the writable paths listed above and nothing else."
    # The run wrote into the declared output, and the hand-off to bg is exact
    # for the single file output.
    assert_file_contains "$SD/changes-plan.md" "mocked io plan"
    assert_launcher_output_contains "Plan written to: $SD/changes-plan.md"
    assert_launcher_output_contains "Run it with: opencode:bg --target ./ < $SD/changes-plan.md"
    # ... all via the one-off container, never the running container's exec.
    assert_docker_lacks "exec -T -w /workspace/project opencode /entrypoint.sh opencode run"
    assert_rc 0 "$LAUNCH_RC" "changes --output"
}

@test "changes_output_empty" {
    # The run finished but wrote nothing into the output: the shared neutral
    # error, and a failure rather than an empty plan handed to bg.
    _io_plan_env ""
    run_launcher "$SD/io.env" changes --output "$SD/changes-plan.md" "analyse and plan"

    assert_launcher_output_contains "Error: the run wrote no output to: $SD/changes-plan.md"
    assert_rc 1 "$LAUNCH_RC" "changes --output with an empty output"
}

# Build a git repository in the sandbox workspace holding one change of every
# kind the git-changes report prints: a committed file (the upstream-relative
# diff), an unstaged edit of a tracked file, a staged file and an untracked
# file. With "with_upstream" the work happens on a branch tracking the initial
# one, which is the branch git-changes takes its upstream from; with
# "no_upstream" the changes stay on that branch. Sets CHANGES_BASE to the
# branch the upstream diff is taken against.
#   _changes_repo with_upstream|no_upstream
_changes_repo() {
    make_git_workspace
    CHANGES_BASE="$(git -C "$SD/ws" branch --show-current)"
    if [[ "$1" == with_upstream ]]; then
        git -C "$SD/ws" checkout -q -b feature
        git -C "$SD/ws" branch --set-upstream-to="$CHANGES_BASE" >/dev/null
    fi
    printf 'committed\n' >"$SD/ws/committed.txt"
    printf 'first\n' >"$SD/ws/tracked.txt"
    git -C "$SD/ws" add committed.txt tracked.txt
    git -C "$SD/ws" commit -q -m changes
    # Unstaged: tracked.txt is committed above and edited afterwards.
    printf 'second\n' >>"$SD/ws/tracked.txt"
    # Staged, and untracked (never added).
    printf 'staged\n' >"$SD/ws/staged.txt"
    git -C "$SD/ws" add staged.txt
    printf 'untracked\n' >"$SD/ws/untracked.txt"
}

# Run the container-side git-changes helper against the sandbox workspace.
#   _run_git_changes
_run_git_changes() {
    run sh -c 'cd "$1" && sh "$2"' sh "$SD/ws" "$ROOT_DIR/scripts/git-changes"
}

@test "git_changes_commands" {
    # The helper echoes every git command whose output it prints, right above
    # that output, so the report says which commands produced it - while the
    # counting helpers (numstat) stay out of it, their output is captured.
    _changes_repo with_upstream
    _run_git_changes

    assert_rc 0 "$status" "git-changes"
    assert_output_has_line "$output" "Branch: feature"
    # One echo per command that writes to stdout, in the order they run.
    assert_output_has_line "$output" "\$ git diff $CHANGES_BASE...HEAD"
    assert_output_has_line "$output" '$ git diff --cached'
    assert_output_has_line "$output" '$ git diff'
    assert_output_has_line "$output" '$ git ls-files --others --exclude-standard'
    # The counters are not echoed, and the output itself is still there.
    assert_output_lacks "$output" "--numstat"
    assert_output_contains "$output" "+++ b/committed.txt"
    assert_output_contains "$output" "untracked.txt"
}

@test "git_changes_commands_no_upstream" {
    # Without an upstream there is no upstream-relative diff to run (or echo);
    # the working tree and index diffs plus the untracked listing remain.
    _changes_repo no_upstream
    _run_git_changes

    assert_rc 0 "$status" "git-changes"
    assert_output_has_line "$output" "Branch: $CHANGES_BASE"
    assert_output_has_line "$output" '$ git diff --cached'
    assert_output_has_line "$output" '$ git diff'
    assert_output_has_line "$output" '$ git ls-files --others --exclude-standard'
    assert_output_lacks "$output" "...$CHANGES_BASE"
    assert_output_lacks "$output" "--numstat"
}

@test "git_changes_commands_stat" {
    # A change set over 500 added lines is summarised with --stat, so those
    # are the commands echoed instead of the full diffs.
    make_git_workspace
    CHANGES_BASE="$(git -C "$SD/ws" branch --show-current)"
    git -C "$SD/ws" checkout -q -b feature
    git -C "$SD/ws" branch --set-upstream-to="$CHANGES_BASE" >/dev/null
    seq 1 600 >"$SD/ws/bulk.txt"
    git -C "$SD/ws" add bulk.txt
    git -C "$SD/ws" commit -q -m bulk
    _run_git_changes

    assert_rc 0 "$status" "git-changes"
    assert_output_has_line "$output" "\$ git diff --stat $CHANGES_BASE...HEAD"
    assert_output_has_line "$output" '$ git diff --stat --cached'
    assert_output_has_line "$output" '$ git diff --stat'
    # Summarised only: the full diff commands must not be run at all.
    assert_output_lacks_line "$output" '$ git diff'
    assert_output_lacks "$output" "--numstat"
}

@test "io" {
    # io runs a task with the workspace mounted read-only: one throwaway
    # `compose run` (never the running container, whose mounts are fixed at
    # creation) carrying the io override, with the task passed on the command
    # line. The mock fills in the output, so io can report it.
    _io_plan_env "$SD/io-plan.md"
    run_launcher "$SD/io.env" io --verbose --output "$SD/io-plan.md" "plan the io feature"

    assert_docker_contains "$CBASE -f <tmp>/docker-compose.io.yml run --rm -T --name oc-io-<pid>"
    assert_docker_contains "opencode run --auto"
    assert_docker_contains "stdin: <task-information>"
    assert_docker_contains "plan the io feature"
    assert_file_contains "$SD/io-plan.md" "mocked io plan"
    assert_launcher_output_contains "Running task on opencode project: ws"
    assert_launcher_output_contains "Read-only workspace mount: $SD/ws -> /workspace/project"
    assert_launcher_output_contains "Writable output mount: $SD/io-plan.md -> $SD/io-plan.md"
    assert_launcher_output_contains "Output written to: $SD/io-plan.md"
    # `run --rm` drops the container when it exits, and a finished run clears
    # its name, so the exit cleanup has nothing left to remove: no rm of a
    # container that is already gone (and no warning about one).
    assert_docker_lacks "docker rm -f -v oc-io-"
    assert_rc 0 "$LAUNCH_RC" "io"
}

@test "io_stdin" {
    # The documented usage pipes the task in instead of passing it as an
    # argument: run_launcher feeds it to the launcher, io reads it, and the
    # container still receives the whole prompt (context + task) on its stdin.
    _io_plan_env "$SD/io-plan.md"
    printf '%s\n' "plan the module split from stdin" >"$SD/task.md"
    LAUNCH_STDIN_FILE="$SD/task.md" run_launcher "$SD/io.env" io --output "$SD/io-plan.md"

    assert_docker_contains "plan the module split from stdin"
    assert_file_contains "$SD/io-plan.md" "mocked io plan"
    assert_launcher_output_contains "Output written to: $SD/io-plan.md"
    assert_rc 0 "$LAUNCH_RC" "io with the task on stdin"
}

@test "io_in_workspace" {
    # An output file inside the workspace keeps its natural path in the
    # container: the read-write file mount then shadows the read-only
    # workspace mount at exactly that file, so the agent sees one file at its
    # normal workspace path instead of a second, host-shaped one.
    _io_plan_env "$SD/ws/plan.md"
    run_launcher "$SD/io.env" io --verbose --output ./plan.md "plan inside the workspace"

    assert_launcher_output_contains "Read-only workspace mount: $SD/ws -> /workspace/project"
    assert_launcher_output_contains "Writable output mount: $SD/ws/plan.md -> /workspace/project/plan.md"
    assert_docker_contains "$CBASE -f <tmp>/docker-compose.io.yml run --rm -T --name oc-io-<pid>"
    assert_file_contains "$SD/ws/plan.md" "mocked io plan"
    assert_rc 0 "$LAUNCH_RC" "io with an in-workspace output"
}

@test "io_multiple_outputs" {
    # Two files and a directory, all declared with --output: three writable
    # surfaces, each echoed as its own mount, each prepared before the run and
    # each filled by it (the mock writes a file inside the directory output).
    local out1="$SD/multi-a.md" out2="$SD/multi-b.md" outdir="$SD/multi-dir"
    mkdir -p "$outdir"
    _io_plan_env "$out1" "$out2" "$outdir"
    run_launcher "$SD/io.env" io --verbose \
        --output "$out1" --output "$out2" --output "$outdir" "write all outputs"

    assert_docker_contains "$CBASE -f <tmp>/docker-compose.io.yml run --rm -T --name oc-io-<pid>"
    assert_launcher_output_contains "Writable output mount: $out1 -> $out1"
    assert_launcher_output_contains "Writable output mount: $out2 -> $out2"
    assert_launcher_output_contains "Writable output mount: $outdir -> $outdir"
    assert_file_contains "$out1" "mocked io plan"
    assert_file_contains "$out2" "mocked io plan"
    assert_file_contains "$outdir/mock-output.md" "mocked io plan"
    assert_launcher_output_contains "Output written to: $out1"
    assert_launcher_output_contains "Output written to: $out2"
    assert_launcher_output_contains "Output written to: $outdir"
    assert_rc 0 "$LAUNCH_RC" "io with multiple outputs"
}

@test "io_output_dir" {
    # An existing directory output is mounted read-write as a directory and is
    # not emptied before the run: whatever the run writes inside it counts as
    # its output.
    local outdir="$SD/io-outdir"
    mkdir -p "$outdir"
    echo "pre-existing" >"$outdir/keep.md"
    _io_plan_env "$outdir"
    run_launcher "$SD/io.env" io --verbose --output "$outdir" "write into the directory"

    assert_docker_contains "$CBASE -f <tmp>/docker-compose.io.yml run --rm -T --name oc-io-<pid>"
    assert_launcher_output_contains "Writable output mount: $outdir -> $outdir"
    assert_file_contains "$outdir/keep.md" "pre-existing"
    assert_file_contains "$outdir/mock-output.md" "mocked io plan"
    assert_launcher_output_contains "Output written to: $outdir"
    assert_rc 0 "$LAUNCH_RC" "io with a directory output"
}

@test "io_output_dir_missing" {
    # A missing path ending in '/' is a directory the run may create: it is
    # mkdir'd before the run starts, so the agent finds a writable directory.
    local outdir="$SD/io-newdir"
    _io_plan_env "$outdir"
    run_launcher "$SD/io.env" io --output "$outdir/" "write into the new directory"

    [[ -d "$outdir" ]] || fail "io did not create the directory output"
    assert_file_contains "$outdir/mock-output.md" "mocked io plan"
    assert_launcher_output_contains "Output written to: $outdir"
    assert_rc 0 "$LAUNCH_RC" "io with a missing directory output"
}

@test "io_output_overlap" {
    # One output living inside another: the inner mount would shadow the outer
    # one's content of that subtree, so the pair is refused before anything is
    # created and before any container is run.
    local rc=0
    _io_plan_env "$SD/overlap/f.md"
    run_launcher "$SD/io.env" io --output "$SD/overlap/" --output "$SD/overlap/f.md" "task"
    rc=$LAUNCH_RC

    assert_launcher_output_contains "Error: output inside another output: $SD/overlap/f.md is inside $SD/overlap"
    assert_docker_lacks "oc-io-"
    [[ ! -e "$SD/overlap" ]] || fail "io created the outer output despite the overlap"
    [[ ! -e "$SD/overlap/f.md" ]] || fail "io created the inner output despite the overlap"
    [[ "$rc" -ne 0 ]] || fail "io did not exit non-zero for overlapping outputs"
}

@test "io_output_duplicate" {
    # The same path twice cannot be two surfaces: refused by name before
    # anything is created and before any container is run.
    local rc=0
    _io_plan_env "$SD/dup.md"
    run_launcher "$SD/io.env" io --output "$SD/dup.md" --output "$SD/dup.md" "task"
    rc=$LAUNCH_RC

    assert_launcher_output_contains "Error: duplicate output: $SD/dup.md"
    assert_docker_lacks "oc-io-"
    [[ ! -e "$SD/dup.md" ]] || fail "io created the duplicate output"
    [[ "$rc" -ne 0 ]] || fail "io did not exit non-zero for duplicate outputs"
}

@test "io_empty_output" {
    # The run finished but wrote nothing. The file was truncated before it, so
    # the empty result is this run's own: io fails rather than reporting output
    # that is not there (or a stale one from an earlier run).
    _io_plan_env ""
    run_launcher "$SD/io.env" io --output "$SD/io-plan.md" "plan the io feature"

    assert_docker_contains "oc-io-<pid>"
    assert_launcher_output_contains "Error: the run wrote no output to: $SD/io-plan.md"
    assert_rc 1 "$LAUNCH_RC" "io with an empty output"
}

@test "io_allow_empty" {
    # Same as io_empty_output, but --allow-empty accepts the run that wrote
    # nothing: the command succeeds and reports the output anyway.
    _io_plan_env ""
    run_launcher "$SD/io.env" io --allow-empty --output "$SD/io-plan.md" "plan the io feature"

    assert_docker_contains "oc-io-<pid>"
    assert_launcher_output_lacks "Error: the run wrote no output to"
    assert_launcher_output_contains "Output written to: $SD/io-plan.md"
    assert_rc 0 "$LAUNCH_RC" "io --allow-empty with an empty output"
}

@test "io_missing_output" {
    # Without --output there is no surface to mount writable, so io refuses
    # before any container work and shows its help instead.
    run_launcher /dev/null io "plan the io feature"

    assert_launcher_output_contains "Error: io requires at least one output (--output <path>)"
    assert_launcher_output_contains "io [--output <path>]... [--allow-empty] [task] [opencode args...]"
    assert_docker_lacks "oc-io-"
    assert_rc 1 "$LAUNCH_RC" "io without --output"
}

@test "io_missing_task" {
    # Neither a task argument nor stdin: io reports it without running anything,
    # and before the outputs are touched, so nothing is created or truncated.
    run_launcher /dev/null io --output "$SD/io-plan.md"

    assert_launcher_output_contains "Error: no task provided"
    assert_docker_lacks "oc-io-"
    [[ ! -e "$SD/io-plan.md" ]] || fail "io created the output file despite the missing task"
    assert_rc 1 "$LAUNCH_RC" "io without a task"
}

@test "io_helpers" {
    # Unit test for the helpers io (and changes --output) are built on, with
    # the launcher sourced so the real functions run without docker or a
    # terminal:
    #
    #   _opencode_parse_output_flags - repeatable --output appends, 
    #   --allow-empty sets the flag, everything else passes through in order
    #   with the task candidate first.
    #
    #   _io_outputs_prepare - file/directory mode handling, creation and
    #   truncation, the container target inside the workspace, and the
    #   duplicate/overlap rejections that leave the host untouched.
    #
    #   _write_io_override - the mount contract: the workspace re-mounted
    #   read-only at the target compose already mounts it at (volumes merge by
    #   target, the later file wins), every output on its own read-write
    #   target, and a path holding YAML-significant characters kept as one
    #   scalar.
    #
    #   _cleanup_io - only an interrupted run leaves anything to remove: with a
    #   container name set it force-removes it and drops the stream file, and
    #   with name and pid cleared (a finished run, which `run --rm` already
    #   cleaned up after) it must not touch docker at all.
    cat >"$SD/io.sh" <<'SCRIPT'
set +e
source "$LAUNCHER"
set +e
pass=1

check() {
    # check <description> <needle>
    if grep -Fq -- "$2" "$tmp_io_file"; then
        echo "    ok: $1"
    else
        echo "    FAIL: $1 (missing: $2)"
        cat "$tmp_io_file" | sed 's/^/    /'
        pass=0
    fi
}
check_lacks() {
    if grep -Fq -- "$2" "$tmp_io_file"; then
        echo "    FAIL: $1 (unexpected: $2)"
        cat "$tmp_io_file" | sed 's/^/    /'
        pass=0
    else
        echo "    ok: $1"
    fi
}
expect() {
    # expect <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        echo "    ok: $1"
    else
        echo "    FAIL: $1 (expected: [$2], got: [$3])"
        pass=0
    fi
}

# --- _opencode_parse_output_flags ----------------------------------------
# Repeatable --output appends in order, --allow-empty sets the flag, and
# everything else is kept in order with the task candidate first.
_opencode_parse_output_flags p_outs p_allow p_rest \
    --output /tmp/a.md --allow-empty doThing --output=/tmp/b.md --model gpt
expect "repeatable --output is collected in order" "/tmp/a.md /tmp/b.md" "${p_outs[*]}"
expect "--allow-empty sets the flag" "1" "$p_allow"
expect "rest keeps the task candidate first, order preserved" "doThing --model gpt" "${p_rest[*]}"

_opencode_parse_output_flags p_outs p_allow p_rest --agent x task
expect "--allow-empty defaults to 0" "0" "$p_allow"
expect "flags before the task pass through in order" "--agent x task" "${p_rest[*]}"
expect "no --output gives an empty outputs list" "0" "${#p_outs[@]}"

_opencode_parse_output_flags p_outs p_allow p_rest
expect "no args at all parse to nothing" "0 0 0" "${#p_outs[@]} $p_allow ${#p_rest[@]}"

p_rc=0
_opencode_parse_output_flags p_outs p_allow p_rest --output 2>/dev/null || p_rc=$?
expect "--output without a path is rejected" "1" "$p_rc"

# --- _io_outputs_prepare --------------------------------------------------
prep_root="$(mktemp -d)"
mkdir -p "$tmp_compose_dir" "$prep_root/prep-ws"
oc_workspace="$prep_root/prep-ws"

# A file output outside the workspace keeps its own path as the target; a
# relative one resolves against the workspace directory ($PWD).
pushd "$prep_root" >/dev/null || exit 1
_io_outputs_prepare p_hosts p_containers p_isdir prep-ws/rel.md "$prep_root/prep-abs.md" 2>/dev/null
popd >/dev/null || exit 1
expect "file outputs are prepared in order" \
    "$prep_root/prep-ws/rel.md $prep_root/prep-abs.md" "${p_hosts[*]}"
expect "an outside file keeps its absolute path in the container" \
    "$prep_root/prep-abs.md" "${p_containers[1]}"
expect "a missing file is created empty" "0" "$(stat -c %s "$prep_root/prep-ws/rel.md" 2>/dev/null)"
expect "file outputs are marked as files" "0 0" "${p_isdir[*]}"

# An in-workspace output gets its natural path below the container workspace
# root, so its read-write mount shadows the read-only workspace mount.
pushd "$prep_root" >/dev/null || exit 1
_io_outputs_prepare p_hosts p_containers p_isdir ./prep-ws/plan.md 2>/dev/null
popd >/dev/null || exit 1
expect "an in-workspace file targets its natural workspace path" \
    "/workspace/project/plan.md" "${p_containers[0]}"

# A file with content is truncated, so only what a run writes survives.
echo "stale content" >"$prep_root/prep-trunc.md"
_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-trunc.md" 2>/dev/null
expect "an existing file is truncated before the run" "0" "$(stat -c %s "$prep_root/prep-trunc.md")"

# An existing directory is a directory output, not truncated; a missing path
# with a trailing slash is one too, and is created.
mkdir -p "$prep_root/prep-dir"
echo "keep" >"$prep_root/prep-dir/keep.md"
_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-dir" 2>/dev/null
expect "an existing directory is a directory output" "1" "${p_isdir[0]}"
expect "a directory output is not truncated" "keep" "$(cat "$prep_root/prep-dir/keep.md")"
_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-newdir/" 2>/dev/null
expect "a missing directory (trailing slash) is created" "1" "$([[ -d "$prep_root/prep-newdir" ]] && echo 1 || echo 0)"

# A file whose parent does not exist is rejected before anything is created.
p_rc=0
(_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-no-parent/f.md") 2>/dev/null || p_rc=$?
expect "a missing parent directory is rejected" "1" "$p_rc"

# Duplicates and overlaps are rejected, naming the paths, with nothing
# created on either side.
p_rc=0
(_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-dup.md" "$prep_root/prep-dup.md") 2>/dev/null || p_rc=$?
expect "a duplicate host output is rejected" "1" "$p_rc"
expect "a duplicate output creates nothing" "0" "$([[ -e "$prep_root/prep-dup.md" ]] && echo 1 || echo 0)"
p_err="$(_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-dup.md" "$prep_root/prep-dup.md" 2>&1 >/dev/null || true)"
expect "the duplicate error names the path" "1" \
    "$([[ "$p_err" == *"duplicate output: $prep_root/prep-dup.md"* ]] && echo 1 || echo 0)"
p_rc=0
(_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-inside/" "$prep_root/prep-inside/f.md") 2>/dev/null || p_rc=$?
expect "an output inside another output is rejected" "1" "$p_rc"
expect "an overlapping output creates neither side" \
    "0 0" "$([[ -e "$prep_root/prep-inside" ]] && echo 1 || echo 0) $([[ -e "$prep_root/prep-inside/f.md" ]] && echo 1 || echo 0)"
p_err="$(_io_outputs_prepare p_hosts p_containers p_isdir "$prep_root/prep-inside/" "$prep_root/prep-inside/f.md" 2>&1 >/dev/null || true)"
expect "the overlap error names both paths" "1" \
    "$([[ "$p_err" == *"$prep_root/prep-inside/f.md is inside $prep_root/prep-inside"* ]] && echo 1 || echo 0)"
rm -rf -- "$prep_root"

# --- _write_io_override ---------------------------------------------------
mkdir -p "$tmp_compose_dir"

# One output outside the workspace: the container sees it at its own path.
mounts=('/tmp/out.md' '/tmp/out.md')
_write_io_override '/home/other/repos/myproject' mounts
check "mounts are volumes of the opencode service" '    volumes:'
check "the workspace is mounted read-only at the container workspace root" \
    '- "/home/other/repos/myproject:/workspace/project:ro"'
check "the output file is mounted read-write at its own path" \
    '- "/tmp/out.md:/tmp/out.md"'
check_lacks "the output file mount carries no read-only flag" \
    '/tmp/out.md:/tmp/out.md:ro'

# Several outputs: one read-only workspace line plus one read-write mount per
# pair, alternating host and container path.
mounts=('/tmp/out.md' '/tmp/out.md' \
    '/tmp/report' '/tmp/report' \
    '/home/other/repos/myproject/plan.md' '/workspace/project/plan.md')
_write_io_override '/home/other/repos/myproject' mounts
check "a second output is mounted read-write at its own path" \
    '- "/tmp/report:/tmp/report"'
expect "the workspace is the only read-only line" "1" \
    "$(grep -c -- ':ro"' "$tmp_io_file")"
expect "one volume line per mount, plus the read-only workspace" "4" \
    "$(grep -c -- '^      - "' "$tmp_io_file")"

# A path inside the workspace: its target is under the workspace root, so the
# read-write mount shadows the read-only workspace mount at exactly it.
mounts=('/home/other/repos/myproject/plan.md' '/workspace/project/plan.md')
_write_io_override '/home/other/repos/myproject' mounts
check "an in-workspace plan file is mounted under the workspace root" \
    '- "/home/other/repos/myproject/plan.md:/workspace/project/plan.md"'
check "the workspace still mounts read-only beside it" \
    '- "/home/other/repos/myproject:/workspace/project:ro"'

# YAML-significant characters in the path stay inside one quoted scalar rather
# than ending it early or starting a comment.
mounts=('/tmp/re ird: out#1.md' '/tmp/re ird: out#1.md')
_write_io_override '/home/other/repos/myproject' mounts
check "a path with YAML syntax is quoted" \
    '- "/tmp/re ird: out#1.md:/tmp/re ird: out#1.md"'

# An interrupted run: the container is still there, so it is force-removed and
# the streamed output file goes with it. The driver's output is silenced by the
# cleanup, so the mock's log is what shows the call happened.
_cleanup_log="$(mktemp)"
export OPENCODE_TEST_DOCKER_LOG="$_cleanup_log"
_cleanup_io_name="oc-io-99"
_cleanup_io_pid=""
_cleanup_io_outfile="$(mktemp)"
_cleanup_io
if grep -Fq "docker rm -f -v oc-io-99" "$_cleanup_log"; then
    echo "    ok: an in-flight container is force-removed"
else
    echo "    FAIL: an in-flight container is force-removed"
    cat "$_cleanup_log" | sed 's/^/    /'
    pass=0
fi
if [[ -e "$_cleanup_io_outfile" ]]; then
    echo "    FAIL: the stream file is removed"
    pass=0
else
    echo "    ok: the stream file is removed"
fi

# A finished run: name and pid are cleared, `run --rm` already dropped the
# container, so the cleanup must not call docker (and cannot warn about a
# container that is gone).
: >"$_cleanup_log"
_cleanup_io_name=""
_cleanup_io_pid=""
_cleanup_io_outfile=""
_cleanup_io
if [[ -s "$_cleanup_log" ]]; then
    echo "    FAIL: no docker call after a finished run"
    cat "$_cleanup_log" | sed 's/^/    /'
    pass=0
else
    echo "    ok: no docker call after a finished run"
fi
rm -f -- "$_cleanup_log"
unset OPENCODE_TEST_DOCKER_LOG

((pass)) && echo "io_helpers ok" || echo "io_helpers FAIL"
SCRIPT
    # OPENCODE_TEST_DOCKER_LOG starts empty, so a stray mock call would show up
    # on stdout rather than in a log file left behind by an earlier
    # run_launcher; the cleanup section points it at its own temp file instead.
    PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" OPENCODE_TEST_DOCKER_LOG= \
        run bash "$SD/io.sh"
    # the checks run in the sourced script and report themselves, so both
    # contracts are asserted in one go
    assert_output_contains "$output" "io_helpers ok"
}

@test "repl_worktree_parent_env" {
    # The interactive workspace shell (repl) prepares its compose args once at
    # start and every command runs against the environment its rcfile builds, so
    # the rcfile has to export WORKSPACE_PARENT too: it is the env var behind
    # the image's dev.snowdon.opencode.workspace_parent label (the compose build
    # file passes it as PROJECT_WORKSPACE_PARENT). Without it a build run from
    # inside the repl labels the worktree's image with no parent, and a delete
    # scoped to the repository never reaches that image after the container is
    # gone. 'up' inside the repl is driven through stdin, like the io test.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    local stdin_file="$SD/repl.in"
    printf 'up\nexit\n' >"$stdin_file"
    LAUNCH_CWD="$SD/wt" LAUNCH_STDIN_FILE="$stdin_file" run_launcher /dev/null repl
    unset LAUNCH_CWD
    assert_rc 0 "$LAUNCH_RC" "repl exits zero"
    assert_docker_contains "up -d opencode [env WORKSPACE_PARENT=$SD/ws]"
}
