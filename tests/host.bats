#!/usr/bin/env bats
# README group "Host-side & meta": opencode:create, opencode:env,
# opencode:help, opencode:git, opencode:update — host-side assets and
# launcher metadata (no container work).

load 'lib/helpers'

@test "create" {
    # create: a host-side command dispatched before workspace resolution, so it
    # never prepares compose args: the only docker call is the worktree-child
    # discovery every command makes. With --dockerfile it scaffolds
    # <workspace>/ocdocker/Dockerfile from the launcher's own example
    # and prints the two exports that point the compose build at it.
    run_launcher /dev/null create --dockerfile
    assert_docker "$CPARENTPS"
    assert_rc 0 "$LAUNCH_RC" "create --dockerfile exits zero"

    local dockerfile="$SD/ws/ocdocker/Dockerfile"
    [[ -f "$dockerfile" ]] && cmp -s "$dockerfile" "$SD/compose/Dockerfile.example" \
        || fail "ocdocker/Dockerfile is not the launcher example"
    assert_launcher_output_contains "export OPENCODE_DOCKERFILE=\"$dockerfile\""
    assert_launcher_output_contains "export OPENCODE_CONTEXT=\"$SD/ws\""
}

@test "create_exists" {
    # create --dockerfile is idempotent: an existing ocdocker directory is
    # reported and left untouched (a hand-edited Dockerfile is never
    # overwritten), and the command still exits zero so it is safe to re-run in a
    # shell profile.
    mkdir -p "$SD/ws/ocdocker"
    echo 'FROM scratch' >"$SD/ws/ocdocker/Dockerfile"
    run_launcher /dev/null create --dockerfile
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "Docker folder already exists"
    assert_rc 0 "$LAUNCH_RC" "create exits zero when ocdocker exists"
    [[ "$(cat "$SD/ws/ocdocker/Dockerfile")" == 'FROM scratch' ]] \
        || fail "an existing ocdocker directory was overwritten"
}

@test "create_worktree" {
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
    [[ -f "$wstree/.git" ]] || fail "$wstree is not a worktree"
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" "worktree $wstree"
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" "branch refs/heads/ws-dev"
    # the hint has to name both the worktree and the command that uses it
    assert_launcher_output_contains "$wstree"
    assert_launcher_output_contains "opencode:uptree \"$wstree\""
}

@test "create_worktree_branch" {
    # The branch name is an optional positional argument of the action: it is
    # the branch the worktree sits on AND what the worktree is named
    # (<project>-<branch>), so a project can hold several agent worktrees side
    # by side instead of every branch fighting over the single -dev directory.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --worktree feature/my-branch
    assert_rc 0 "$LAUNCH_RC" "create --worktree <branch> exits zero"

    local wstree="$SD/repos/agent-trees/ws-feature-my-branch"
    local listed
    listed="$(git -C "$SD/ws" worktree list --porcelain)"
    assert_output_contains "$listed" "worktree $wstree"
    assert_output_contains "$listed" "branch refs/heads/feature/my-branch"
    # the hint starts the worktree that was just created, which is not the -dev
    # one here
    assert_launcher_output_contains "opencode:uptree \"$wstree\""
}

@test "create_worktree_branch_with_child" {
    # A running worktree-child container redirects the workspace to the
    # canonical agent worktree, which is itself named <project>-dev. The branch
    # worktree created for the repository is a sibling of it, named after the
    # repository (<project>-<branch>) so 'uptree --branch' finds it: naming it
    # after the effective workspace produced <project>-dev-<branch>, which
    # uptree never looks up.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B ws-dev "$SD/repos/agent-trees/ws-dev"

    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/repos/agent-trees/ws-dev" \
        run_launcher /dev/null create --worktree feature/my-branch
    assert_rc 0 "$LAUNCH_RC" "create --worktree <branch> with a child container exits zero"

    local wstree="$SD/repos/agent-trees/ws-feature-my-branch"
    local listed
    listed="$(git -C "$SD/ws" worktree list --porcelain)"
    assert_output_contains "$listed" "worktree $wstree"
    assert_output_contains "$listed" "branch refs/heads/feature/my-branch"
    # the hint has to start the worktree uptree --branch <branch> looks for
    assert_launcher_output_contains "opencode:uptree \"$wstree\""
    assert_launcher_output_lacks "$SD/repos/agent-trees/ws-dev-feature-my-branch"

    # The canonical worktree is named after the repository as well: the
    # effective workspace already carries the -dev suffix, so without the same
    # anchor it looked for <project>-dev-dev and created it.
    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/repos/agent-trees/ws-dev" \
        run_launcher /dev/null create --worktree
    assert_rc 0 "$LAUNCH_RC" "create --worktree with a child container exits zero"
    assert_launcher_output_contains "Worktree already exists: $SD/repos/agent-trees/ws-dev"
    assert_launcher_output_lacks "$SD/repos/agent-trees/ws-dev-dev"
}

@test "create_worktree_branch_from_worktree" {
    # The same anchor when the command is run from a worktree of the
    # repository: agent worktrees hang off the repository itself, so the lookup
    # runs against its parent (what 'uptree --branch' does, see
    # t_uptree_branch_from_worktree) instead of naming a worktree of a
    # worktree.
    make_git_workspace
    make_agent_tree_root
    git -C "$SD/ws" worktree add -q -B ws-dev "$SD/repos/agent-trees/ws-dev"

    LAUNCH_CWD="$SD/repos/agent-trees/ws-dev" \
        run_launcher /dev/null create --worktree feature/my-branch
    unset LAUNCH_CWD
    assert_rc 0 "$LAUNCH_RC" "create --worktree <branch> from a worktree exits zero"

    local wstree="$SD/repos/agent-trees/ws-feature-my-branch"
    assert_output_contains "$(git -C "$SD/ws" worktree list --porcelain)" \
        "worktree $wstree"
    assert_launcher_output_contains "opencode:uptree \"$wstree\""
    assert_launcher_output_lacks "$SD/repos/agent-trees/ws-dev-feature-my-branch"
}

@test "create_worktree_branch_dev_reserved" {
    # 'dev' is the suffix of the canonical agent worktree, so a branch of that
    # name cannot have a worktree of its own: creating one would claim the
    # canonical <project>-dev slot for a branch, after which every 'create
    # --worktree' and 'uptree' without a branch reports or starts that branch's
    # worktree instead. The reservation is checked before anything is created,
    # and after sanitising, so it does not depend on how the branch is spelled.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --worktree dev
    assert_rc 1 "$LAUNCH_RC" "create --worktree dev is rejected"
    assert_launcher_output_contains "reserved"
    assert_launcher_output_contains "$SD/repos/agent-trees/ws-dev"
    # nothing is created, and only the worktree-child discovery runs
    assert_docker "$CPARENTPS"
    [[ ! -e "$SD/repos/agent-trees/ws-dev" ]] \
        || fail "$SD/repos/agent-trees/ws-dev was created for branch 'dev'"

    run_launcher /dev/null create --worktree DEV
    assert_rc 1 "$LAUNCH_RC" "create --worktree DEV is rejected as well"
    assert_launcher_output_contains "reserved"
}

@test "create_worktree_multiple" {
    # One project can hold several agent worktrees: the canonical -dev one and
    # one per branch coexist under the tree root, each on its own branch, and
    # creating one leaves the others alone.
    make_git_workspace
    make_agent_tree_root

    run_launcher /dev/null create --worktree
    assert_rc 0 "$LAUNCH_RC" "create --worktree exits zero"
    run_launcher /dev/null create --worktree feature/one
    assert_rc 0 "$LAUNCH_RC" "create --worktree feature/one exits zero"
    run_launcher /dev/null create --worktree feature/two
    assert_rc 0 "$LAUNCH_RC" "create --worktree feature/two exits zero"

    local listed
    listed="$(git -C "$SD/ws" worktree list --porcelain)"
    assert_output_contains "$listed" "worktree $SD/repos/agent-trees/ws-dev"
    assert_output_contains "$listed" "worktree $SD/repos/agent-trees/ws-feature-one"
    assert_output_contains "$listed" "worktree $SD/repos/agent-trees/ws-feature-two"
    assert_output_contains "$listed" "branch refs/heads/ws-dev"
    assert_output_contains "$listed" "branch refs/heads/feature/one"
    assert_output_contains "$listed" "branch refs/heads/feature/two"
}

@test "create_worktree_exists" {
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

@test "create_worktree_exists_branch" {
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

@test "create_worktree_conflict" {
    # A path that exists but is not a worktree of this repository is an error:
    # the launcher never deletes or moves it.
    make_git_workspace
    make_agent_tree_root
    mkdir -p "$SD/repos/agent-trees/ws-dev"
    echo "keep" >"$SD/repos/agent-trees/ws-dev/keep"

    run_launcher /dev/null create --worktree
    [[ "$LAUNCH_RC" -ne 0 ]] || fail "create --worktree accepted a conflicting path"
    assert_launcher_output_contains "is not a worktree of $SD/ws"
    assert_output_contains "$(cat "$SD/repos/agent-trees/ws-dev/keep")" "keep"
}

@test "create_worktree_no_root" {
    # The worktree root is the agent-trees directory, which has to exist: the
    # launcher does not create it, since SD_AGENT_TREE_ROOT may point at shared
    # storage that is mounted per host.
    make_git_workspace

    run_launcher /dev/null create --worktree
    [[ "$LAUNCH_RC" -ne 0 ]] || fail "create --worktree succeeded without the worktree root"
    assert_launcher_output_contains "no directory at the worktree root: $SD/repos/agent-trees"
}

@test "create_worktree_not_git" {
    # A worktree needs a repository: the sandbox workspace carries a .git
    # directory, but not a repository, which is what this asserts against.
    make_agent_tree_root

    run_launcher /dev/null create --worktree
    [[ "$LAUNCH_RC" -ne 0 ]] || fail "create --worktree accepted a non-repository workspace"
    assert_launcher_output_contains "requires a git repository: $SD/ws"
    [[ ! -e "$SD/repos/agent-trees/ws-dev" ]] \
        || fail "a worktree was created for a non-repository workspace"
}

@test "create_both_actions" {
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

    [[ -f "$SD/ws/ocdocker/Dockerfile" ]] || fail "the --dockerfile action did not run"
    [[ -f "$SD/repos/agent-trees/ws-dev/.git" ]] || fail "the --worktree action did not run"
}

@test "create_no_args" {
    # create has no default action: the required option names the action, and the
    # help follows the error so the options are discoverable. Nothing is resolved
    # before that error, so docker is never called.
    run_launcher /dev/null create
    [[ "$LAUNCH_RC" -ne 0 ]] || fail "create without an action exited zero"
    assert_docker ""
    assert_launcher_output_contains "requires an action (--dockerfile, --worktree)"
    assert_launcher_output_contains "--dockerfile"
    assert_launcher_output_contains "--worktree"
}

@test "create_unknown_action" {
    # An unknown option is a usage error, and it names the option.
    run_launcher /dev/null create --unknown
    assert_rc 2 "$LAUNCH_RC" "create --unknown is a usage error"
    assert_launcher_output_contains "error: unknown option: --unknown"
}

@test "create_non_git_repo" {
    # --dockerfile works without git at all: the sandbox workspace .git is not a
    # repository, and the action must not care.
    run_launcher /dev/null create --Dockerfile
    assert_rc 0 "$LAUNCH_RC" "create --Dockerfile exits zero"
    [[ -f "$SD/ws/ocdocker/Dockerfile" ]] \
        || fail "the --Dockerfile alias did not scaffold anything"
}

@test "env" {
    # env lists the exported launcher variables and does nothing else: no
    # workspace is resolved, so the sandbox docker log stays empty.
    echo 'OPENCODE_TEST_ENV_MARKER=marker' >"$SD/env.env"
    run_launcher "$SD/env.env" env
    assert_launcher_output_contains "OPENCODE_TEST_ENV_MARKER=marker"
    assert_launcher_output_contains "SD_OPENCODE=$SD/compose"
    assert_launcher_output_lacks "Starting workspace:"
    assert_docker ""
    assert_rc 0 "$LAUNCH_RC" "env"

    run_launcher /dev/null env ws
    assert_launcher_output_contains "$SD/ws"
    assert_rc 0 "$LAUNCH_RC" "env ws"

    run_launcher /dev/null env workspace
    assert_launcher_output_contains "$SD/ws"
    assert_rc 0 "$LAUNCH_RC" "env workspace"
}

@test "help" {
    run_launcher /dev/null help
    assert_launcher_output_contains "opencode launcher - manage the opencode container and sessions"
    assert_launcher_output_contains "Commands:"
    for cmd in start new up setup stop delete ls exec down run shell bg scaffold changes compose create help; do
        assert_launcher_output_contains "$cmd"
    done
    # io's row is asserted by its description: the bare name matches anywhere.
    assert_launcher_output_contains "Run a task on a read-only workspace with N writable outputs"
}

@test "help_cmd" {
    # help start prints the detailed start help.
    run_launcher /dev/null help start
    assert_launcher_output_contains "start [opencode args...]"
    assert_launcher_output_contains "(Re)create the opencode container"
}

@test "help_create" {
    # help create documents every action and its options: the workspace
    # Dockerfile scaffold (what it writes and which exports the user has to add
    # to their environment) and the agent worktree, including the optional
    # branch name and the name reserved for the canonical worktree.
    run_launcher /dev/null help create
    assert_launcher_output_contains "ocdocker/Dockerfile"
    assert_launcher_output_contains "OPENCODE_DOCKERFILE"
    assert_launcher_output_contains "OPENCODE_CONTEXT"
    assert_launcher_output_contains "--worktree"
    assert_launcher_output_contains "branch"
    assert_launcher_output_contains "reserved"
}

@test "help_uptree" {
    # help uptree explains which worktree each form starts, and that a branch
    # named after the canonical worktree is refused instead of silently
    # starting that one.
    run_launcher /dev/null help uptree
    assert_launcher_output_contains "uptree [--branch <branch>] <workspace>"
    assert_launcher_output_contains "<project>-dev"
    assert_launcher_output_contains "reserved"
}

@test "help_io" {
    # help io documents the neutral io surface: the repeatable --output (file
    # or directory), --allow-empty, and the stdin task fallback.
    run_launcher /dev/null help io
    assert_launcher_output_contains "io [--output <path>]... [--allow-empty] [task] [opencode args...]"
    assert_launcher_output_contains "A writable output surface (required, repeatable)"
    assert_launcher_output_contains "Do not fail when an output is empty after the run"
    assert_launcher_output_contains "read from stdin when not given"
}

@test "help_changes" {
    # help changes documents the output mode: --output switches the plan agent
    # onto the io machinery (a plain run - the plan agent would refuse to
    # write) and hands the result to bg.
    run_launcher /dev/null help changes
    assert_launcher_output_contains "changes [--output <path>]... [--allow-empty] [task] [opencode args...]"
    assert_launcher_output_contains "the agent step switches to the io machinery"
    assert_launcher_output_contains "not the plan agent"
    assert_launcher_output_contains "refuse to write the plan file itself"
    assert_launcher_output_contains "Run it with:"
    assert_launcher_output_contains "Without --output the running container is reused"
}

@test "help_env" {
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

@test "help_unknown" {
    # help <unknown> returns an error to stderr. The launcher exits non-zero
    # here, so the capture is guarded: Bats runs the body under errexit (only
    # the message is asserted, so the status is discarded).
    local out
    out="$(cd "$SD/ws" && setsid env PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
        bash "$LAUNCHER" help nonexistent 2>&1)" || true
    assert_output_contains "$out" "No help available for command: nonexistent"
}

@test "unknown_command" {
    # An unknown command is rejected before anything runs; the direct setsid
    # invocation is guarded for errexit like help_unknown (the launcher exits
    # non-zero, and only the message is asserted).
    local out
    out="$(cd "$SD/ws" && setsid env PATH="$MOCKBIN:$PATH" SD_OPENCODE="$SD/compose" SD_REPO_HOME="$SD/repos" \
        SD_YOLO=true bash "$LAUNCHER" bogus 2>&1)" || true
    assert_output_contains "$out" "Unknown command: bogus"
}

@test "git" {
    skip "no launcher test for opencode:git yet (host-side git passthrough)"
}

@test "update" {
    skip "no launcher test for opencode:update yet (repo/image refresh)"
}
