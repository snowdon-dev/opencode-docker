#!/usr/bin/env bats
# Not a command: the labels `make build` and the launcher stamp onto images
# and the build file that carries them.

load 'lib/helpers'

@test "image_parent_label" {
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

@test "image_build_labels" {
    # The image carries its workspace labels from the compose build config
    # (build.labels), not from the workspace's Dockerfile: that file belongs to
    # the project and is often multi-stage, where an ARG not redeclared in the
    # final stage expands empty and bakes empty labels - hiding the image from
    # the label queries 'delete' scopes resources with (see _ws_resource_ls).
    # The label lines are asserted on the build file itself, and the build file
    # must be the one merged whenever the workspace builds an image.
    assert_file_contains "$ROOT_DIR/compose/image/docker-compose.build.yml" \
        'dev.snowdon.opencode.workspace: "${WORKSPACE}"'
    assert_file_contains "$ROOT_DIR/compose/image/docker-compose.build.yml" \
        'dev.snowdon.opencode.workspace_parent: "${WORKSPACE_PARENT:-}"'

    # A workspace with a root Dockerfile takes the build branch, so the labels
    # reach the image the launcher builds for it.
    cp "$SD/compose/Dockerfile.example" "$SD/compose/Dockerfile"
    run_launcher /dev/null up
    assert_rc 0 "$LAUNCH_RC" "up with a root Dockerfile exits zero"
    assert_docker_contains "-f $SD/compose/compose/image/docker-compose.build.yml"
}
