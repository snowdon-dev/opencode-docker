#!/usr/bin/env bats
# README group "In the running container": opencode:run, opencode:exec,
# opencode:shell, opencode:compose — commands against the container that is
# already running (compose passes straight through).

load 'lib/helpers'

@test "exec" {
    # exec calls opencode:exec directly (ensure_up is commented out in the
    # launcher), which runs docker compose exec -it.
    run_launcher /dev/null exec sh -c 'echo hi'
    assert_docker "$CPARENTPS
$CBASE exec -it opencode sh -c echo hi"
    assert_launcher_output_contains "Executing in opencode project: ws"
}

@test "run" {
    # Container already running -> task runs inside it via exec.
    run_launcher /dev/null run "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE exec -T -w /workspace/project opencode npm install"
    assert_launcher_output_contains "Running in opencode project: ws"
}

@test "run_nocontainer" {
    # No running container -> throwaway `compose run` (no ports), removed on exit.
    # Uses --entrypoint /bin/sh so the task args are exec'd by a real shell.
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null run "npm install"
    assert_docker "$CPARENTPS
$CBASE ps -q opencode
$CBASE run --rm -w /workspace/project --entrypoint /bin/sh opencode -c exec \"\$@\" sh npm install"
}

@test "shell" {
    # shell is a convenience alias for 'exec sh ...' in main().
    run_launcher /dev/null shell -c 'echo hi'
    assert_docker "$CPARENTPS
$CBASE exec -it opencode sh -c echo hi"
}

@test "compose" {
    run_launcher /dev/null compose config --services
    assert_docker "$CPARENTPS
$CBASE config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
}

@test "compose_no_readonly" {
    # SD_READ_ONLY=false disables the read-only .git mounts. With them gone
    # the launcher has no read-only volume overrides left to write, so the
    # docker-compose.git.yml override file is not merged at all. What proves
    # .git locking in the default case is the launcher's "read-only locking
    # dir:" line, printed once per .git dir it locks.
    # run_launcher sources the dotfile in the parent shell, so unset it again to
    # avoid leaking into later tests.
    local dotfile="$SD/readonly.env"
    echo 'SD_READ_ONLY=false' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    assert_launcher_output_contains "Running Docker Compose for project: ws"
    assert_launcher_output_lacks "read-only locking dir:"
    unset SD_READ_ONLY
}
