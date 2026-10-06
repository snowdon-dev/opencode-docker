#!/usr/bin/env bats
# README group "Ensure running": opencode:new, opencode:up, opencode:setup,
# opencode:uptree — get a container running (possibly running nothing).

load 'lib/helpers'

@test "up" {
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

@test "new" {
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

@test "setup" {
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

@test "setup_build_fail" {
    # setup when `compose up` fails (e.g. build failure) must abort and NOT run
    # the dispatch command.
    local rc=0
    OPENCODE_TEST_BUILD_FAIL=1 run_launcher /dev/null setup "npm install"
    rc=$LAUNCH_RC
    assert_launcher_output_contains "Failed to start the opencode container"
    [[ "$rc" -ne 0 ]] || fail "setup did not exit non-zero after build failure"
    # Must NOT have attempted the dispatch (no ps/exec) after the failed up.
    assert_docker_lacks "ps -q opencode"
}

@test "uptree_branch" {
    # uptree --branch <branch> starts the agent worktree made for that branch,
    # under its own <project>-<branch> compose project: from the repository it
    # belongs to, that is how a branch worktree is selected, since uptree
    # resolves the canonical -dev one without the option.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B feature/my-branch \
        "$SD/repos/agent-trees/ws-feature-my-branch"

    run_launcher /dev/null uptree --branch feature/my-branch
    assert_rc 0 "$LAUNCH_RC" "uptree --branch exits zero"
    assert_launcher_output_contains \
        "Using opencode workspace: $SD/repos/agent-trees/ws-feature-my-branch"
    assert_launcher_output_contains "Compose project: ws-feature-my-branch"
    assert_docker_contains "docker compose -p ws-feature-my-branch"
    assert_docker_contains "up -d opencode"
}

@test "uptree_branch_path_after_flag" {
    # The option is stripped before the workspace path is read, so the path can
    # follow it instead of having to come first, and a missing branch name is a
    # usage error rather than an option silently swallowed by compose.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B feature/my-branch \
        "$SD/repos/agent-trees/ws-feature-my-branch"

    run_launcher /dev/null uptree --branch feature/my-branch "$SD/ws"
    assert_rc 0 "$LAUNCH_RC" "uptree --branch <branch> <workspace> exits zero"
    assert_launcher_output_contains "Compose project: ws-feature-my-branch"

    run_launcher /dev/null uptree --branch
    assert_rc 2 "$LAUNCH_RC" "uptree --branch without a name is a usage error"
    assert_launcher_output_contains "error: --branch requires a branch name"
}

@test "uptree_branch_from_worktree" {
    # Run from a worktree of the repository, --branch still names a sibling
    # worktree of that repository: the lookup is anchored in the parent, not in
    # the worktree the command happens to be run from.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B feature/my-branch \
        "$SD/repos/agent-trees/ws-feature-my-branch"

    LAUNCH_CWD="$SD/repos/agent-trees/ws-feature-my-branch" \
        run_launcher /dev/null uptree --branch feature/my-branch
    unset LAUNCH_CWD
    assert_rc 0 "$LAUNCH_RC" "uptree --branch from a worktree exits zero"
    assert_launcher_output_contains \
        "Using opencode workspace: $SD/repos/agent-trees/ws-feature-my-branch"
    assert_launcher_output_contains "Compose project: ws-feature-my-branch"
}

@test "uptree_branch_missing" {
    # A branch worktree that does not exist is reported with the worktree it
    # looked for and the 'git worktree add' line to run (what the help
    # promises), rather than a bare "needs initialising". Nothing is prepared
    # for it, so docker is never called.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null uptree --branch feature/my-branch
    assert_rc 1 "$LAUNCH_RC" "uptree for a missing branch worktree fails"
    assert_launcher_output_contains \
        "Worktree does not exist, needs initialising: $SD/repos/agent-trees/ws-feature-my-branch"
    assert_launcher_output_contains \
        "git -C \"$SD/ws\" worktree add -B \"feature/my-branch\" \"$SD/repos/agent-trees/ws-feature-my-branch\""
    assert_launcher_output_contains "opencode:create --worktree feature/my-branch"
    assert_docker ""
}

@test "uptree_branch_dev_reserved" {
    # The branch worktree lookup is the other side of the same reservation:
    # <project>-dev is the canonical worktree, which carries its own branch, so
    # there is no worktree for a 'dev' branch to start. It fails instead of
    # quietly starting the canonical one, and it fails even when that worktree
    # exists.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B ws-dev "$SD/repos/agent-trees/ws-dev"

    run_launcher /dev/null uptree --branch dev
    assert_rc 1 "$LAUNCH_RC" "uptree --branch dev is rejected"
    assert_launcher_output_contains "reserved"
    assert_launcher_output_contains "$SD/repos/agent-trees/ws-dev"
    assert_docker ""
}

@test "uptree_missing" {
    # The same for the canonical worktree uptree expects by default: the name
    # it looked for and the command that creates it.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null uptree
    assert_rc 1 "$LAUNCH_RC" "uptree for a missing worktree fails"
    assert_launcher_output_contains \
        "Worktree does not exist, needs initialising: $SD/repos/agent-trees/ws-dev"
    assert_launcher_output_contains \
        "git -C \"$SD/ws\" worktree add -B \"ws-dev\" \"$SD/repos/agent-trees/ws-dev\""
}
