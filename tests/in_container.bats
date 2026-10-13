#!/usr/bin/env bats
# README group "In the running container": opencode:run, opencode:exec,
# opencode:shell, opencode:compose — commands against the container that is
# already running (compose passes straight through).

load 'lib/helpers'

@test "exec" {
    # exec calls opencode:exec directly (ensure_up is commented out in the
    # launcher), which runs docker compose exec --user <uid>.
    run_launcher /dev/null exec --verbose sh -c 'echo hi'
    assert_docker "$CPARENTPS
$CBASE exec $CUSER -it opencode sh -c echo hi"
    assert_launcher_output_contains "Executing in opencode project: ws"
}

@test "run" {
    # Container already running -> task runs inside it via exec.
    run_launcher /dev/null run --verbose "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE exec -T $CUSER -w /workspace/project opencode npm install"
    assert_launcher_output_contains "Running in opencode project: ws"
}

@test "run_nocontainer" {
    # No running container -> throwaway `compose run` (no ports), removed on
    # exit. It runs the task with the service's own entrypoint, so the args
    # reach the command directly.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE run --rm -w /workspace/project opencode npm install"
}

@test "shell" {
    # shell is a convenience alias for 'exec sh ...' in main().
    run_launcher /dev/null shell -c 'echo hi'
    assert_docker "$CPARENTPS
$CBASE exec $CUSER -it opencode sh -c echo hi"
}

@test "compose" {
    run_launcher /dev/null compose --verbose config --services
    assert_docker "$CPARENTPS
$CBASE config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
}

@test "compose_no_readonly" {
    # SD_READ_ONLY=false disables the read-only .git mounts: none is printed
    # ("read-only locking dir:", once per .git dir it locks) and none enters
    # the read-only volume override - which is still merged, because the
    # component skill is always mounted through it. What proves the .git
    # locking in the default case is that printed line.
    # run_launcher sources the dotfile in the parent shell, so unset it again to
    # avoid leaking into later tests.
    local dotfile="$SD/readonly.env"
    echo 'SD_READ_ONLY=false' >"$dotfile"
    run_launcher "$dotfile" compose --verbose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/compose.rovols.yaml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
    assert_launcher_output_lacks "read-only locking dir:"
    assert_override_contains "/etc/opencode/skills/available-duck-tools:ro"
    assert_override_lacks ".git:"
    unset SD_READ_ONLY
}
