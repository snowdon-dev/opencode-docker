#!/usr/bin/env bats
# Not a command: failures before any command runs — missing driver, missing
# daemon, and the HOME/workspace guards that refuse to run at all.

load 'lib/helpers'

@test "no_driver_on_path" {
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

    [[ "$rc" -eq 1 ]] || fail "expected rc=1, got rc=$rc"
    [[ "$out" == *"found neither docker nor podman"* ]] || {
        printf '%s\n' "$out" >&2
        fail "missing the driver diagnostic"
    }
    [[ "$out" != *"command not found"* ]] || {
        printf '%s\n' "$out" >&2
        fail "the early exit reported a missing cleanup handler"
    }
}

@test "no_docker" {
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

    [[ "$rc" -ne 0 && -n "$out" ]] || {
        printf '%s\n' "$out" >&2
        fail "expected a non-zero exit and a diagnostic, got rc=$rc"
    }
    # Nothing that builds or starts a container may be attempted.
    if grep -Eq '^docker (compose|build|run|create) ' "$log"; then
        sed 's/^/    /' "$log" >&2
        fail "a container-creating command was attempted without docker"
    fi
}

@test "outside_root_abort" {
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
    [[ "$LAUNCH_RC" -ne 0 ]] || fail "outside-root command did not abort"
    export HOME="$saved_home"
}

@test "outside_root_validate" {
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
    PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" HOME="$SD/home_home" \
        SD_OTHER="$SD/elsewhere" run bash "$SD/check.sh"
    assert_output_contains "$output" "outside_root_validate ok"
}

@test "workspace_guard" {
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
    PATH="$MOCKBIN:$PATH" LAUNCHER="$LAUNCHER" SD_GUARD="$SD" run bash "$SD/guard.sh"
    assert_output_contains "$output" "workspace_guard ok"
}
