#!/usr/bin/env bats
# Not a command: how the launcher prepares a launch - the compose command
# (build context, toolchain cache selection, cpu flags, the api-key secret
# merge) and the per-project config directory (template seeding, the
# component skill).

load 'lib/helpers'

@test "context_file_derive" {
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
    [[ "$out" == "$SD/ws/myBuild|$SD/ws/myBuild/Dockerfile.dev" ]] \
        || fail "expected '$SD/ws/myBuild|$SD/ws/myBuild/Dockerfile.dev', got: '$out'"
}

@test "context_must_be_file" {
    # OPENCODE_DOCKERFILE must name a regular file; a directory-valued variable
    # does NOT trigger derivation, so both keep the values they were given
    # (an unset OPENCODE_CONTEXT stays empty).
    mkdir -p "$SD/ws/myBuild"
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" OPENCODE_DOCKERFILE="myBuild" \
        bash -c 'unset OPENCODE_CONTEXT; source "$1"
            printf "%s|%s\n" "$OPENCODE_CONTEXT" "$OPENCODE_DOCKERFILE"' _ "$LAUNCHER")"
    [[ "$out" == "|myBuild" ]] || fail "expected '|myBuild', got: '$out'"
}

@test "context_explicit_wins" {
    # An explicitly set OPENCODE_CONTEXT is never overridden by derivation.
    local out
    out="$(cd "$SD/ws" && PATH="$MOCKBIN:$PATH" \
        OPENCODE_DOCKERFILE="myBuild/Dockerfile.dev" OPENCODE_CONTEXT="myCtx" \
        bash -c 'source "$1"
            printf "%s|%s\n" "$OPENCODE_CONTEXT" "$OPENCODE_DOCKERFILE"' _ "$LAUNCHER")"
    [[ "$out" == "myCtx|myBuild/Dockerfile.dev" ]] \
        || fail "expected 'myCtx|myBuild/Dockerfile.dev', got: '$out'"
}

@test "cache_all" {
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

@test "cache_all_bare_home" {
    # The cache tests must not lean on the toolchain cache dirs the host's home
    # happens to have: _cache_dirs (from make_sandbox) points the seven
    # toolchain cache overrides at existing sandbox dirs. What a fresh home
    # still lacks are the launcher's own three storage roots
    # (data/config/cache), and with OPENCODE_CACHE=all all ten are checked in
    # one pass. On a home that holds none of them the launcher names every
    # missing directory - then, because the suite runs with SD_YOLO=true,
    # creates them itself and carries on to the compose command. The assertion
    # set pins both halves of that: the run is not stopped by an incomplete
    # home, and the missing roots are really created rather than skipped.
    _cache_vol_files go rust python node
    local dotfile="$SD/cache.env"
    # make_sandbox points the launcher's three storage roots into the sandbox,
    # so a home is only bare once the dotfile points the roots back at their
    # $HOME defaults - the very paths this test pins.
    printf '%s\n' 'OPENCODE_CACHE=all' \
        'OPENCODE_CONFIG_ROOT=$HOME/.config/opencode-docker' \
        'OPENCODE_DATA_ROOT=$HOME/.local/share/opencode-docker' \
        'OPENCODE_CACHE_ROOT=$HOME/.cache/opencode-docker' >"$dotfile"
    local saved_home="$HOME"
    HOME="$SD/bare-home"
    export HOME
    mkdir -p "$HOME"
    run_launcher "$dotfile" compose config --services
    local bare_home="$HOME"
    HOME="$saved_home"
    export HOME
    unset OPENCODE_CACHE OPENCODE_CONFIG_ROOT OPENCODE_DATA_ROOT OPENCODE_CACHE_ROOT
    assert_docker "$CPARENTPS
docker compose -p ws -f $SD/compose/docker-compose.yml -f $SD/compose/compose/env/docker-compose.password.yml -f $CACHEVOL/docker-compose.cache.yml -f $CIMG -f <tmp>/docker-compose.git.yml -f $SD/compose/compose/sys/docker-compose.port.yml config --services"
    # The missing roots are named, not silently skipped...
    assert_launcher_output_contains "The following directories do not exist:"
    assert_launcher_output_contains "$bare_home/.local/share/opencode-docker"
    assert_launcher_output_contains "$bare_home/.config/opencode-docker"
    assert_launcher_output_contains "$bare_home/.cache/opencode-docker"
    # ...and SD_YOLO=true creates them and continues instead of refusing.
    assert_launcher_output_lacks "Not interactive: create them above and re-run."
    assert_rc 0 "$LAUNCH_RC" "a bare home with SD_YOLO=true still reaches compose"
    local dir
    for dir in \
        "$bare_home/.local/share/opencode-docker" \
        "$bare_home/.config/opencode-docker" \
        "$bare_home/.cache/opencode-docker"; do
        [[ -d "$dir" ]] || fail "SD_YOLO=true did not create $dir"
    done
}

@test "cache_dirs_missing_aborts" {
    # The launcher side of the contract _cache_dirs works around: a cache dir
    # that does not exist is named and, run without a terminal (as here, with
    # stdin closed), reported and refused instead of being created, before any
    # compose command is built. So no container starts against a cache path
    # docker would have to create as root, and a non-interactive run fails on
    # the real cause instead of on a question nobody was there to answer. The
    # suite therefore hands the launcher cache dirs that already exist.
    #
    # The refusal only applies when SD_YOLO is not true: yolo creates the
    # missing dirs itself (pinned by t_cache_all_bare_home), so this test opts
    # out of it. HOME moves into the sandbox for the same reason as
    # t_outside_root_abort's dotfile: outside HOME the launcher stops at the
    # workspace prompt instead and the cache-dir check is never reached.
    _cache_vol_files go rust python node
    _cache_dirs_absent
    local dotfile="$SD/cache.env"
    local saved_home="$HOME"
    printf '%s\n' 'OPENCODE_CACHE=all' 'SD_YOLO=false' "HOME=$SD" >"$dotfile"
    run_launcher "$dotfile" compose config --services
    HOME="$saved_home"
    export HOME
    # Restore the sandbox-provided dirs: the exports above outlive the test.
    _cache_dirs
    unset OPENCODE_CACHE
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "$SD/absent/go-mod"
    assert_launcher_output_contains "The following directories do not exist:"
    assert_launcher_output_contains "Not interactive: create them above and re-run."
    assert_rc 1 "$LAUNCH_RC" "a missing cache dir aborts before compose"
    # The refusal created nothing, yolo or not.
    [[ ! -d "$SD/absent/pip" && ! -d "$SD/.local/share/opencode-docker" ]] \
        || fail "refused run created directories anyway"
}

@test "cache_dirs_uppercase_ids" {
    # OPENCODE_CACHE is documented, and used by t_cache_ids, as
    # case-insensitive, so "PYTHON NODE" has to be checked for its cache dirs
    # exactly like "python node". The check matched the raw value, so an
    # upper-case request skipped it entirely: the launcher went on to build the
    # compose command and docker created ~/.cache/pip and ~/.npm itself, as
    # root, instead of the user being offered to create them first. The
    # yolo opt-out and HOME redirect are t_cache_dirs_missing_aborts': only the
    # upper-case request under test differs.
    _cache_vol_files python node
    _cache_dirs_absent
    local dotfile="$SD/cache.env"
    local saved_home="$HOME"
    printf '%s\n' 'OPENCODE_CACHE="PYTHON NODE"' 'SD_YOLO=false' "HOME=$SD" >"$dotfile"
    run_launcher "$dotfile" compose config --services
    HOME="$saved_home"
    export HOME
    _cache_dirs
    unset OPENCODE_CACHE
    assert_docker "$CPARENTPS"
    assert_launcher_output_contains "$SD/absent/npm"
    assert_launcher_output_contains "The following directories do not exist:"
    assert_rc 1 "$LAUNCH_RC" "an upper-case cache id is still checked"
}

@test "cache_ids" {
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

@test "cache_false" {
    # OPENCODE_CACHE=false mounts no toolchain caches.
    local dotfile="$SD/cache.env"
    echo 'OPENCODE_CACHE=false' >"$dotfile"
    run_launcher "$dotfile" compose config --services
    assert_docker "$CPARENTPS
$CBASE config --services"
    assert_launcher_output_contains "Running without toolchain cache"
    unset OPENCODE_CACHE
}

@test "cache_unknown" {
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

@test "cache_unknown_no_image_url" {
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

@test "cache_partial_unknown" {
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

@test "cpu_cpuset" {
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

@test "cpu_cpus" {
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

@test "cpu_both" {
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

@test "secret_key_file_merges" {
    # The api key is opt-in and file based: the launcher reads
    # $OPENCODE_KEY_FILE (~/.config/opencode-docker/opencode.key by default)
    # and merges the secret declaration only when a non-empty key was read
    # there. The compose file has to declare both halves - the top-level
    # secret and the opencode service's reference to it - for compose to
    # mount the host key file into the container at /run/secrets/api_key,
    # where start-serve-backend reads it. The key itself is never copied
    # into an override file or an environment variable, only its path is.
    local secret_yml="$ROOT_DIR/compose/secret/docker-compose.secret.yml"
    assert_file_contains "$secret_yml" \
        'file: ${OPENCODE_KEY_FILE:-./secrets/api_key}'
    assert_file_contains "$secret_yml" '- api_key'

    printf 'test-api-key-123\n' >"$SD/opencode.key"
    printf 'OPENCODE_KEY_FILE=%s\n' "$SD/opencode.key" >"$SD/key.env"
    run_launcher "$SD/key.env" up
    assert_rc 0 "$LAUNCH_RC" "up with a key file exits zero"
    assert_docker_contains \
        "-f $SD/compose/compose/secret/docker-compose.secret.yml"
    assert_launcher_output_contains "Using api key secret: $SD/opencode.key"
    # Not exported afterwards: a later launcher run outside run_launcher
    # (help, unknown command) must not inherit this test's key file.
    unset OPENCODE_KEY_FILE
}

@test "secret_no_key_file" {
    # A launch with no key file reads no key, so nothing is merged: no
    # secret mount and no "Using api key secret", and the backend therefore
    # starts without an api key (start-serve-backend exports nothing when
    # /run/secrets/api_key is absent). The sandbox key path is the
    # run_launcher default - a file that does not exist, which is what a
    # host without ~/.config/opencode-docker/opencode.key looks like.
    run_launcher /dev/null up
    assert_rc 0 "$LAUNCH_RC" "up without a key file exits zero"
    assert_docker_lacks "docker-compose.secret.yml"
    assert_launcher_output_lacks "Using api key secret"
}

@test "secret_empty_key_file" {
    # An existing key file with nothing in it is not a secret: the launcher
    # reads it, finds no key, and merges exactly as in the missing-file
    # case - an empty secret would only give the backend an empty key.
    : >"$SD/opencode.key"
    printf 'OPENCODE_KEY_FILE=%s\n' "$SD/opencode.key" >"$SD/key.env"
    run_launcher "$SD/key.env" up
    assert_rc 0 "$LAUNCH_RC" "up with an empty key file exits zero"
    assert_docker_lacks "docker-compose.secret.yml"
    assert_launcher_output_lacks "Using api key secret"
    unset OPENCODE_KEY_FILE
}

@test "secret_backend_api_key" {
    # Container side of the api key contract: start-serve-backend.sh does NOT
    # read the mounted secret. The launcher still merges the secret (see
    # t_secret_key_file_merges), so compose puts the key file in the container
    # at /run/secrets/api_key, but the backend runs `opencode serve` with
    # OPENCODE_API_KEY unset no matter what - the key stays out of the
    # container's environment entirely, secret file or not (OPENCODE_SECRET_FILE
    # points an alternate secret path at the script for the test). A stub
    # opencode on PATH records the environment the server was exec'd with.
    mkdir -p "$SD/stubbin"
    cat >"$SD/stubbin/opencode" <<'STUB'
#!/bin/bash
printf 'OPENCODE_API_KEY=%s\n' "${OPENCODE_API_KEY-<unset>}"
STUB
    chmod +x "$SD/stubbin/opencode"

    local backend="$ROOT_DIR/scripts/start-serve-backend.sh"
    local out

    # A secret file holding a key: still not exported.
    printf 'test-api-key-123\n' >"$SD/api_key"
    out="$(env -u OPENCODE_API_KEY PATH="$SD/stubbin:$PATH" \
        OPENCODE_SECRET_FILE="$SD/api_key" bash "$backend")"
    assert_output_contains "$out" "OPENCODE_API_KEY=<unset>"
    assert_output_lacks "$out" "test-api-key-123"

    # No secret file at all.
    out="$(env -u OPENCODE_API_KEY PATH="$SD/stubbin:$PATH" \
        OPENCODE_SECRET_FILE="$SD/absent-key" bash "$backend")"
    assert_output_contains "$out" "OPENCODE_API_KEY=<unset>"

    # An empty secret file.
    : >"$SD/empty-key"
    out="$(env -u OPENCODE_API_KEY PATH="$SD/stubbin:$PATH" \
        OPENCODE_SECRET_FILE="$SD/empty-key" bash "$backend")"
    assert_output_contains "$out" "OPENCODE_API_KEY=<unset>"
}

# --- workspace network (OPENCODE_NETWORK=@default) -----------------------
# Write the env file the @default network mode needs, plus the network
# override the launcher merges once it has picked a network.
_network_default_env() {
    echo 'services: { opencode: {} }' \
        >"$SD/compose/compose/net/docker-compose.network.yml"
    echo 'OPENCODE_NETWORK=@default' >"$SD/net.env"
}

@test "network_of_another_workspace" {
    # A workspace that moved (or was renamed) still owns its network: nothing
    # is labelled with the new path, so the launcher tries to create the
    # network again and docker refuses, a name being unique. It then looks the
    # name up, finds the network of the old path, and blames that instead of
    # leaving a bare create failure - naming the removal that clears it.
    _network_default_env
    OPENCODE_TEST_NETWORK_CREATE_FAIL=1 \
    OPENCODE_TEST_NETWORK_NAME_MAP="sd-ws-default=$SD/moved-from" \
        run_launcher "$SD/net.env" up
    unset OPENCODE_NETWORK

    assert_rc 1 "$LAUNCH_RC" "up fails while the stale network holds the name"
    assert_docker_contains "docker network create --driver bridge"
    assert_docker_contains "docker network inspect sd-ws-default --format"
    assert_launcher_output_contains "error: network 'sd-ws-default' already exists for another workspace: $SD/moved-from"
    assert_launcher_output_contains "this workspace is '$SD/ws', so it moved or was renamed"
    assert_launcher_output_contains "docker network rm sd-ws-default"
}

@test "network_of_no_workspace" {
    # The name can also be held by a network the launcher knows nothing about
    # (it carries no workspace label): say that the network is not ours rather
    # than blaming a moved path, and still name the removal.
    _network_default_env
    OPENCODE_TEST_NETWORK_CREATE_FAIL=1 \
    OPENCODE_TEST_NETWORK_NAME_MAP="sd-ws-default=" \
        run_launcher "$SD/net.env" up
    unset OPENCODE_NETWORK

    assert_rc 1 "$LAUNCH_RC" "up fails while a foreign network holds the name"
    assert_launcher_output_contains "error: a network named 'sd-ws-default' already exists, but not created by the launcher"
    assert_launcher_output_contains "docker network rm sd-ws-default"
    assert_launcher_output_lacks "moved or was renamed"
}

@test "network_create_failure_unexplained" {
    # When no network of that name exists the create failed for some other
    # reason: docker's own error stays on stderr (the launcher no longer
    # swallows it) and the plain report stands, without a workspace or a
    # removal hint it cannot back up.
    _network_default_env
    OPENCODE_TEST_NETWORK_CREATE_FAIL=1 \
        run_launcher "$SD/net.env" up
    unset OPENCODE_NETWORK

    assert_rc 1 "$LAUNCH_RC" "up fails when the create fails"
    assert_launcher_output_contains \
        "Error response from daemon: network with name sd-ws-default already exists"
    assert_launcher_output_contains "Network failed to create with name (sd-ws-default)"
    assert_launcher_output_lacks "docker network rm"
}

@test "network_create_race_uses_existing" {
    # Two launches of the same workspace racing to create the network: the
    # loser's create fails, but the network holding the name is its own (it
    # carries this workspace's label), so it is used as it stands and the
    # launch continues instead of failing on the duplicate it just lost.
    _network_default_env
    OPENCODE_TEST_NETWORK_CREATE_FAIL=1 \
    OPENCODE_TEST_NETWORK_NAME_MAP="sd-ws-default=$SD/ws" \
        run_launcher "$SD/net.env" up
    unset OPENCODE_NETWORK

    assert_rc 0 "$LAUNCH_RC" "up continues with the network the other launch created"
    assert_launcher_output_contains "Using network: sd-ws-default"
    assert_launcher_output_lacks "error: network 'sd-ws-default' already exists"
}

# --- project config (seeded once from the template) ----------------------
# Point the launcher's three storage roots into the sandbox - a test must be
# able to watch the per-project config directory without writing to the host's
# home - and drop a template into the config root for the first launch to seed
# the project config from.
#   _config_roots_env
_config_roots_env() {
    mkdir -p "$SD/config-root/template"
    printf '%s\n' \
        "OPENCODE_CONFIG_ROOT=$SD/config-root" \
        "OPENCODE_DATA_ROOT=$SD/data-root" \
        "OPENCODE_CACHE_ROOT=$SD/cache-root" >"$SD/config.env"
}

@test "config_seed_once" {
    # The first launch of a project seeds its config directory
    # (projects/<project>) from $OPENCODE_CONFIG_ROOT/template, saying where it
    # put it, and the template really lands there.
    _config_roots_env
    echo '{"seed":"template-v1"}' >"$SD/config-root/template/opencode.json"
    run_launcher "$SD/config.env" compose config --services
    assert_rc 0 "$LAUNCH_RC" "the seeding launch reaches compose"
    assert_launcher_output_contains \
        "Creating project config at: $SD/config-root/projects/ws"
    local seeded="$SD/config-root/projects/ws/opencode.json"
    [[ -f "$seeded" ]] || fail "template was not copied into the project config"
    assert_file_contains "$seeded" 'template-v1'
}

@test "config_no_template_propagation" {
    # Seeding happens only once. The project config directory is opencode's
    # own, so a later launch neither wipes it nor re-copies the template:
    # files written since survive, and a changed template does not propagate
    # (remove the directory to re-seed it). The wipe-and-recopy that used to
    # run on every launch lost both.
    _config_roots_env
    echo '{"seed":"template-v1"}' >"$SD/config-root/template/opencode.json"
    run_launcher "$SD/config.env" compose config --services
    assert_rc 0 "$LAUNCH_RC" "the seeding launch reaches compose"

    # A file the project wrote, then an upstream change to the template.
    echo 'project local' >"$SD/config-root/projects/ws/local.conf"
    echo '{"seed":"template-v2"}' >"$SD/config-root/template/opencode.json"

    run_launcher "$SD/config.env" compose config --services
    assert_rc 0 "$LAUNCH_RC" "the second launch reaches compose"
    assert_launcher_output_lacks "Creating project config at:"
    assert_file_contains "$SD/config-root/projects/ws/opencode.json" 'template-v1'
    [[ -f "$SD/config-root/projects/ws/local.conf" ]] \
        || fail "the existing project config was wiped on a second launch"
}

@test "skills_copied_into_config" {
    # The image component's skill (which toolchain the image ships) is copied
    # into the project config directory, which compose mounts at
    # ~/.config/opencode for every service. It is a skills/<name>/SKILL.md
    # directory, the layout opencode discovers - the flat file that used to
    # be bind-mounted was never loaded, and its mount target inside the
    # already-mounted config dir left root-owned 0-byte files behind on the
    # host. The copy itself never reaches the compose command, and a skill of
    # another component (a variant switch) is dropped, not left behind.
    local stale="$SD/config-root/projects/ws/skills/available-full-tools"
    mkdir -p "$stale"
    echo 'stale' >"$stale/SKILL.md"

    run_launcher /dev/null up
    assert_rc 0 "$LAUNCH_RC" "the skills injection launch reaches compose"

    local skill="$SD/config-root/projects/ws/skills/available-duck-tools/SKILL.md"
    [[ -f "$skill" ]] || fail "the component skill was not copied into the project config"
    cmp -s "$skill" "$SD/compose/opencode/skills/available-duck-tools/SKILL.md" \
        || fail "the copied skill differs from the source"
    [[ ! -e "$stale" ]] || fail "the previous component's skill was left behind"
    assert_docker_lacks "skills"
}
