#!/usr/bin/env bats
# README group "Stop & inspect": opencode:stop, opencode:down,
# opencode:delete, opencode:ls — stop, remove and list managed containers
# (plus the label discovery/authoring they query).

load 'lib/helpers'

@test "stop" {
    # stop: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers (all workspaces by default), stops each.
    # --verbose is a global flag: main() strips it before dispatch, so it can
    # sit before the subcommand as well as after it (see "stop_quiet_by_default").
    run_launcher /dev/null --verbose stop
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_launcher_output_contains "Stopping existing opencode containers"
}

@test "stop_quiet_by_default" {
    # stop without --verbose: same discovery and the same docker stop, but the
    # status line stays home. --verbose puts it back (pinned by "stop").
    run_launcher /dev/null stop
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_launcher_output_lacks "Stopping existing opencode containers"
}

@test "stop_dry_run" {
    # stop --dry-run: read-only discovery still runs (so the report names the
    # real containers), but the destructive stop is only printed, never sent to
    # docker.
    run_launcher /dev/null stop --dry-run
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_launcher_output_contains "DRY RUN: docker stop c1"
    assert_docker_lacks "docker stop c1"
}

@test "stop_scope" {
    # stop scoped to a workspace stays an exact workspace-label match: worktree
    # containers (parent label) are deliberately NOT stopped.
    run_launcher /dev/null stop "$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
    # stop must not use the parent-worktree label filter
    assert_docker_lacks "filter label=dev.snowdon.opencode.parent=$SD/ws"
}

@test "down" {
    # down: compose down clears the project's networks/volumes, then stop is
    # called workspace-scoped to catch any remaining managed containers (TUI).
    run_launcher /dev/null down --verbose
    assert_docker_contains "$CBASE down"
    assert_docker_contains "docker ps -q --filter label=dev.snowdon.opencode.managed=true"
    assert_docker_contains "docker stop c1"
    assert_launcher_output_contains "Stopping opencode project: ws"
}

@test "down_refuses_other" {
    # down can only remove the current workspace's project, so the --other flag
    # (act on everything except the current workspace) has no coherent meaning
    # and is refused once opencode:down parses its flags. Only the docker probe
    # and worktree-child discovery run first; nothing may actually be downed.
    local dotfile="$SD/down-other.env"
    : >"$dotfile"
    run_launcher "$dotfile" down --other
    [[ "$LAUNCH_RC" -eq 2 ]] || fail "down --other should exit 2 (rc=$LAUNCH_RC)"
    assert_launcher_output_contains "error: --other,-o cannot be combined with down"
    # Nothing is downed: no compose down/stop reach docker.
    assert_docker "$CPARENTPS"
}

@test "down_dry_run" {
    # down --dry-run: neither the compose down nor the workspace-scoped stop of
    # remaining one-off containers reaches docker.
    run_launcher /dev/null down --dry-run
    assert_docker_contains "$CPS"
    assert_launcher_output_contains "DRY RUN: docker compose -p ws -f"
    assert_launcher_output_contains "DRY RUN: docker stop c1"
    assert_docker_lacks "$CBASE down"
    assert_docker_lacks "docker stop c1"
}

@test "delete" {
    # delete: dispatched before workspace resolution, discovers managed containers
    # via _select_managed_containers --stopped (includes -a for stopped containers),
    # force-removes each. Removal is silent on stdout, so the removal itself is
    # asserted through the docker call rather than a launcher message.
    run_launcher /dev/null delete
    assert_docker_contains "$CPS"
    assert_docker_contains "docker rm -f c1"
}

@test "delete_dry_run" {
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

@test "delete_all_no_resources" {
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

@test "delete_all_worktree" {
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

@test "delete_all_worktree_other_parent" {
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

@test "delete_all_other_worktree" {
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

@test "delete_other_worktree" {
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
    assert_docker_lacks "docker rm -f wt1"
    assert_docker_lacks "docker image rm img-wt"
    assert_docker_lacks "docker network rm net-wt"
}

@test "delete_this_ambiguous_children" {
    # From a repository with two worktree children running and no canonical
    # agent worktree, the effective workspace cannot be resolved and
    # _resolve_effective_workspace errors out. delete --this and delete --other
    # must surface that error: the diagnostic used to be written to stdout
    # inside the command substitution that resolves the workspace, so it was
    # captured into the variable and both commands failed silently with no
    # output at all.
    OPENCODE_TEST_WORKTREE_CHILD="wt1 wt2" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
        run_launcher /dev/null delete --this
    assert_rc 1 "$LAUNCH_RC" "delete --this fails when the workspace is ambiguous"
    assert_launcher_output_contains "number of children containers"
    # With no canonical worktree to prefer - a project can run several agent
    # worktrees - the candidates are named so there is something to choose
    # between, instead of only the container ids.
    assert_launcher_output_contains "  worktree: $SD/wt"
    assert_launcher_output_contains "pass its path as"

    OPENCODE_TEST_WORKTREE_CHILD="wt1 wt2" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
        run_launcher /dev/null delete --other
    assert_rc 1 "$LAUNCH_RC" "delete --other fails when the workspace is ambiguous"
    assert_launcher_output_contains "number of children containers"
}

@test "ls" {
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

@test "ls_stopped" {
    # A stopped container keeps its own State.Status ("exited"); a running
    # container is never probed for a backend process (docker exec is no longer
    # used for idle detection).
    OPENCODE_TEST_STATUS=exited run_launcher /dev/null ls
    assert_launcher_output_contains "c1"
    assert_launcher_output_contains "exited"
}

@test "ls_quiet" {
    # ls --quiet prints only the short container ids, one per line.
    run_launcher /dev/null ls --quiet
    [[ "$LAUNCH_OUT" == "c1" ]] || fail "ls --quiet should print only 'c1', got: $LAUNCH_OUT"
}

@test "ls_scope" {
    # A workspace argument scopes the listing with an extra label filter.
    run_launcher /dev/null ls "$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
    assert_docker_contains "$CPS"
}

@test "ls_scope_worktree" {
    # A workspace scope also lists containers launched from its git worktrees:
    # those are labelled dev.snowdon.opencode.parent=<scope>, so ls queries that
    # label in addition to the workspace label. stop/delete stay exact-match.
    run_launcher /dev/null ls "$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.workspace=$SD/ws"
    assert_docker_contains "filter label=dev.snowdon.opencode.parent=$SD/ws"
    assert_launcher_output_contains "c1"
}

@test "ls_no_containers" {
    # With no managed containers, ls prints a helpful message (and nothing with
    # --quiet).
    OPENCODE_TEST_NO_CONTAINER=1 run_launcher /dev/null ls
    assert_launcher_output_contains "No managed opencode containers"
}

@test "ls_all" {
    # --all also lists oneoff (throwaway 'compose run') containers: the docker ps
    # call must use -a and include no oneoff filtering.
    run_launcher /dev/null ls --all
    assert_docker_contains "$CPS"
    assert_launcher_output_contains "CONTAINER ID"
}

@test "ls_this_other_partition" {
    # `list --this` and `list --other` must partition the managed containers.
    # The worktree children of the current workspace belong to --this (they
    # carry the parent label), so --other must not list them a second time.
    #
    # The child's inspect record has an EMPTY tui column - only the tui service
    # carries dev.snowdon.opencode.tui - and splitting that record must not
    # collapse the empty column, or the parent label shifts into the tui field,
    # the '.' sentinel into the parent field, and the --other exclusion misses
    # the child entirely.
    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
        run_launcher /dev/null list --this
    assert_launcher_output_contains "$SD/wt"

    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
        run_launcher /dev/null list --other
    assert_launcher_output_lacks "$SD/wt"
    assert_launcher_output_contains "No managed opencode containers"

    # ...and a container of a genuinely different workspace must still be
    # listed by --other: the fix must not turn the exclusion into a blanket
    # "show nothing". CONFLICT=1 makes the generic container report a foreign
    # workspace.
    OPENCODE_TEST_CONFLICT=1 \
    OPENCODE_TEST_WORKTREE_CHILD="wt1" \
    OPENCODE_TEST_WORKTREE_CHILD_PATH="$SD/wt" \
        run_launcher /dev/null list --other
    assert_launcher_output_contains "/workspace/other"
    assert_launcher_output_lacks "$SD/wt"
}

@test "ls_batch" {
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
    if [[ "$inspect_count" -ne 1 ]]; then
        printf '%s\n' "$DOCKER_LOG" >&2
        fail "expected exactly 1 docker inspect, got $inspect_count"
    fi
}

@test "worktree_labels" {
    # A worktree workspace merges the worktree-parent label override in, right
    # after the main compose file, so compose applies the label to the container
    # (dev.snowdon.opencode.parent) and to the network labels declared in
    # docker-compose.yml (dev.snowdon.opencode.workspace_parent). The compose call
    # also carries WORKSPACE_PARENT, the env var behind the image's label.
    make_git_workspace
    git -C "$SD/ws" worktree add -q -b wt-branch "$SD/wt"

    LAUNCH_CWD="$SD/wt" run_launcher /dev/null up --verbose
    unset LAUNCH_CWD

    # A worktree resolves straight to itself (its parent is known from the .git
    # pointer), so there is no worktree-child probe: only the list afterwards
    # queries the parent label.
    assert_docker "docker compose -p wt -f $SD/compose/docker-compose.yml -f <tmp>/docker-compose.labels.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CIMG -f <tmp>/compose.rovols.yaml -f $SD/compose/compose/sys/docker-compose.port.yml up -d opencode [env WORKSPACE_PARENT=$SD/ws]
$CPS --filter label=dev.snowdon.opencode.workspace=$SD/wt
$CINFO
$CPS --filter label=dev.snowdon.opencode.parent=$SD/wt
$CINFO"
    assert_launcher_output_contains "read-only locking worktree parent: $SD/ws/.git"
}

@test "network_labels" {
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

@test "labels_override" {
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
    # the checks run in the sourced script and report themselves, so the whole
    # contract is asserted in one go
    PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" run bash "$SD/labels.sh"
    assert_output_contains "$output" "labels_override ok"
}
