# opencode dev container

[![Docker Pulls](https://img.shields.io/docker/pulls/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Version](https://img.shields.io/docker/v/devsnowdon/opencode-docker?sort=semver)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![CI](https://github.com/snowdon-dev/opencode-docker/actions/workflows/ci.yaml/badge.svg)](https://github.com/snowdon-dev/opencode-docker/actions/workflows/ci.yaml)

A security and human-control oriented [opencode](https://opencode.ai) workflow
that runs in Docker containers. The current project bind-mounted at
`/workspace`, plus persistent caches for full language toolchains installed in
the image (Go, Rust, Node, Python). All features are security first with
convenience opts in.

This project has been designed for arm architecture devices like the [Raspberry
Pi](https://www.raspberrypi.com/). However, it should be compatible with x86.

The version of opencode is best-effort and updated periodically (weekly), feel
free to file an issue if it is out-of-date. See [Build](#build) section.

## Commands

Run commands through the launcher; the workspace defaults to the current
directory. Every command has its own help: `opencode:help <command>` or
`opencode:<command> -h`.

| Command | Alias | Purpose |
|---------|-------|---------|
| `opencode` (`start`) | `oc` | (Re)create the container and attach a TUI |
| `opencode:new` | `ocn` | Stop existing containers, then start a fresh session |
| `opencode:up` | `ocu` | Start the container in the background, running nothing |
| `opencode:setup <cmd>` | `ocset` | Start the container if needed, then run a command in it |
| `opencode:run <cmd>` | `ocr` | Run a task in the service, one-off container if not running |
| `opencode:exec <cmd>` | | Run a command interactively in the running container |
| `opencode:shell` | `ocsh` | `exec sh` |
| `opencode:repl` | | Interactive bash shell bound to the workspace |
| `opencode:compose <args>` | `occ` | Pass arguments straight through to `docker compose` |
| `opencode:stop` | `ocs` | Stop managed containers |
| `opencode:delete` | `ocdel` | Force-remove managed containers (`--all` also drops images and networks) |
| `opencode:down` | `ocd` | Remove this project's containers, networks and volumes |
| `opencode:ls` (`list`) | `ocl` | List managed containers in a ps-style table |
| `opencode:git <args>` | `ocg` | Run git on the host, in the workspace |
| `opencode:uptree` | `ocut` | Start a container for an existing agent worktree |
| `opencode:scaffold [path] <task>` | `ocsf` | Create a new project with opencode (task via stdin) |
| `opencode:bg [path] <task>` | `ocbg` | Run a one-off opencode task on an existing project |
| `opencode:changes [task]` | `occh` | Analyse the branch changes and propose a plan |
| `opencode:update` | `ocud` | Refresh the launcher repo and its images |
| `opencode:help [command]` | `och` | Show help, or help for one command |

`security` and `clone` are reserved but not implemented. `opencode:update` is
destructive: it stops and force-deletes every managed container (caches are
kept), then pulls the launcher repository and the `:empty`, `:duck` and `:full`
base images.

### Common options

Accepted by `stop`, `delete`, `ls` and `down` (each honours the subset that
applies to it):

| Option | Effect |
|--------|--------|
| `--all`, `-a` | Also act on one-off (`compose run`) containers |
| `--other`, `-o` | Act on everything except the current workspace and its worktrees |
| `--this`, `-t` | Act on the current workspace (the default when no path is given) |
| `--quiet`, `-q` | `ls` only: print just the container ids, one per line |
| `--dry-run`, `-n` | Print what would be done without touching anything (`down`, `stop`, `delete`) |
| `--` | Stop parsing options; everything after is a positional argument |

An optional positional argument is a workspace path, or a container-id prefix
(ambiguous prefixes are rejected). `--other` and `--this` are mutually exclusive,
and `down` refuses both: it only ever removes the current project.

### Examples

```shell
# a workspace argument overrides the current directory
opencode /home/other/somerepo
opencode:exec /home/other/somerepo sh
opencode:down /home/other/somerepo
opencode:delete "$(pwd)" --all
opencode:ls --quiet ~/somerepo
opencode:compose exec -it opencode sh

# long tasks, then work in the same container
opencode:run npm install
opencode:setup sh -c 'cd front-end && npm install' && opencode

# tasks, replacing the session or analysing the branch first
opencode -c --auto
opencode:changes "identify issues in these changes"
opencode:bg ./ "refactor this module"

# new projects, either with a real path or under $SD_REPO_HOME
opencode:scaffold /tmp/project < /tmp/sometask.md
opencode:scaffold --path gists/project-1 "Create basic hello world html project"

# run on another base image, or pin and cap the CPUs
OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:full" opencode
OPENCODE_CPUSET="2-3" OPENCODE_CPUS="2" opencode
```

## Features

- [x] Add --dry-run
- [x] Security: Prevent potential destructive actions by the agent
- [x] Security: Configure project isolated cache storage via environment
    variables
- [ ] Security: Add project specific OPENCODE_DATA_DIR and cache via argument
    flags
- [x] Security: Resolve worktree parent (via readonly mount) to allow isolate
    node_modules, while enabling git usage
- [x] Security: Path prompt check when outside `$HOME`, or `$SD_REPO_HOME` when
    `$SD_YOLO_HOME` equals true
- [x] Security: Defined per-workspace Docker networks with automatic subnet allocation
- [x] Security: Auto update. Pin tools to any security updates. Github workflow
- [x] [Docker](https://www.docker.com/) base container for opencode work
- [x] Convenience launcher script
- [x] [ohmyzsh](https://github.com/ohmyzsh/ohmyzsh/wiki/Customization) plugin
    ability
- [x] [Add github build - docker step by step guide](https://docs.docker.com/guides/gha/)
- [x] Prevent large arguments leaks and enable task via std
- [x] Allow easy mounting of the config dir
- [x] Worktree separate project helpers
- [x] Project level repl
- [x] Build image from a workspace path instead of the same /Dockerfile in the
    opencode root. Point at a folder for the workspace, and a context at the workspace
- [x] Layered containers - full(rust, go, c, node, python) - duck(node, python)
    empty.
- [ ] Layered containers - [development containers spec](https://containers.dev/implementors/spec/)
- [x] Layered containers - In the docker compose, use build. and add a docker
    that uses FROM image-full
- [x] Fix: Allow multiple port bindings to enable multiple running agents on
    multiple projects
- [x] Control of container + resources per workspace, including --other
- [ ] Project creation with scaffold extra context
- [ ] Control `--session` per workspace (blocked on opencode v1)
- [ ] Not running docker-compose from sd-opencode?
- [ ] Proper argument and option parsing
- [ ] Agent file needs to change per workspace includes
- [ ] Command that mounts the entire dir as readonly, and mounts a single file
  as writeable so you can plan and write to a file. then run on the plan.
  opencode:io --output /tmp/out.md < /tmp/create-task-plan.md
- [ ] Allow groups to pass a label and then filter for that label. So gists
  passed --group gists then at delete or stop, we can query for a --group gists

## Install

Clone the repository to `~/opencode`:

```shell
git clone https://github.com/snowdon-dev/opencode-docker.git ~/opencode
```

`scripts/launcher.sh` looks for the compose files in `~/opencode`, so link the
repository there. This also means a `.env` placed in the repository root is
picked up by plain `docker compose` runs.

Only one environment variable is required, `SD_OPENCODE`. The rest are for
custom configuration or custom profiles: the path variables are read by compose
([Compose variables](#compose-variables)), the launcher variables by the script
itself ([Launcher variables](#launcher-variables)).

## How a session starts

`opencode` (the `start` command) starts an `opencode serve` backend inside the
container, waits for it to become healthy, then attaches a TUI — a host
`opencode` binary when one is on the `PATH`, otherwise the one-off `tui`
service. The backend is published on a host port only in the first case;
otherwise it is reachable only on the compose network, so one project's backend
cannot be reached from another project's host processes. It is killed when the
TUI exits.

`run`, `changes` and `setup` use the running container when there is one and a
throwaway `compose run` container otherwise; `scaffold` and `bg` always use a
throwaway container.

## Security model

- The agent's `.git` directories are mounted read-only, so it cannot rewrite
  history; set `SD_READ_ONLY=false` to opt out.
- A worktree's parent repository `.git` is mounted read-only at its host path,
  which keeps git usable inside the container while isolating the workspace.
- `opencode/agent.md` and `opencode/tui.json` are mounted read-only into the
  config directory, so the agent cannot rewrite its own instructions.
- Each workspace gets its own Docker network, allocated a subnet from the
  managed range, keeping workspaces isolated from each other.
- Toolchain caches and other host mounts are opt-in (`OPENCODE_CACHE`).
- A workspace outside `$HOME` prompts before it is used, unless `SD_YOLO=true`.

## oh-my-zsh plugin

The launcher sets up the required environment variables, such as `WORKSPACE`,
so use it to launch the container. The `omz` plugin is very lightweight and not
required — you are encouraged to create your own profiles and environments
using whichever shell you prefer. To install it, link it as an oh-my-zsh custom
plugin:

```sh
mkdir -p "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/opencode"
ln -s ~/opencode/omz/opencode.zsh \
    "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/opencode/opencode.plugin.zsh"
```

Then enable it in `~/.zshrc` and point `$SD_OPENCODE` at the repository
(the aliases use it to find the repo):

```sh
export SD_OPENCODE="$HOME/opencode"
export SD_REPO_HOME="$HOME/repos"
plugins=(... opencode)
```

After restarting your shell (`exec zsh`), list the commands with
`alias | grep -E ^oc`. The plugin wraps the launcher in one alias per command
(`oc`, `ocs`, `ocu`, `ocn`, `ocsh`, `ocsetup`, `ocr`, `ocd`, `ocdel`, `ocl`,
`occ`, `occh`, `ocsf`, `ocbg`, `ocg`, `ocut`, `och`, `ocud`) — see
[`omz/opencode.zsh`](omz/opencode.zsh) for the exact list.

## Environment setup steps

- `SD_OPENCODE` must point at the repository (default `$HOME/opencode`).
- Docker is required [docker.io](https://www.docker.com/). For extra security
    use docker rootless. `SD_DRIVER` selects the engine, but only `docker` is
    implemented.
- A modern version of bash is required.
- The opencode binary from the shell path runs the TUI (`npm i -g
    opencode-ai`); without it the in-container `tui` service is used instead.
- CPUs are unrestricted by default; restrict them with `OPENCODE_CPUSET`
    (pinning) or `OPENCODE_CPUS` (limit).
- If you want something to build on every workspace without its own
  `OPENCODE_DOCKERFILE`, you can `cp "$SD_OPENCODE/Dockerfile.example"
  "$SD_OPENCODE/Dockerfile`, and that Dockerfile will be built if there is no
  `OPENCODE_DOCKERFILE` set.

### Creating the directories

The container runs as the `other` user (uid/gid `1000`), so every host
directory bind-mounted under `/home/other/...` (see
[`docker-compose.yml`](docker-compose.yml)) must exist and be writable by that
user. Three of them are always mounted, so create and hand them over with
default paths:

```sh
mkdir -p \
    "$HOME/.cache/opencode/cache" \
    "$HOME/.local/share/opencode" \
    "$HOME/.config/opencode"
chown -R 1000:1000 \
    "$HOME/.cache/opencode" \
    "$HOME/.local/share/opencode" \
    "$HOME/.config/opencode"
```

The toolchain caches (`OPENCODE_PIP_CACHE_DIR`, `OPENCODE_NPM_CACHE_DIR`,
`OPENCODE_GO_BUILD_CACHE_DIR`, `OPENCODE_GO_MOD_CACHE_DIR`,
`OPENCODE_CARGO_REGISTRY_DIR`, `OPENCODE_CARGO_GIT_DIR`, `OPENCODE_SCCACHE_DIR`)
are only mounted when you enable them with `OPENCODE_CACHE`, so create and
chown them only if you do. Each one defaults to the conventional path under
your home directory; see [Compose variables](#compose-variables).

Your project workspace also gets bind-mounted (at `/workspace`) and is written
to by the container, so it too must be owned by `1000:1000`:

```sh
chown -R 1000:1000 "$WORKSPACE"
```

> If you override any path via `.env` (e.g. `OPENCODE_SCCACHE_DIR`), create
> that directory instead and `chown -R 1000:1000` it. Do not run these commands
> with `sudo` unless the directories live outside your home directory.

## Environment variables

### Compose variables

All host-side paths are configured with environment variables. Substitution
happens on the host when `docker compose` runs, and every variable has a
default pointing at the conventional location under your home directory
(`.cache`, `.local`, `.npm`, etc.).

| Variable                   | Default                          | Mounted at (container)              |
|----------------------------|----------------------------------|-------------------------------------|
| `WORKSPACE`                | `$SD_OPENCODE` (repo root)       | `/workspace`                        |
| `OPENCODE_NETWORK`         | –                                | – (external network, see `compose/net/docker-compose.network.yml`) |
| `OPENCODE_CACHE_DIR`       | `$HOME/.cache/opencode/cache`    | `/home/other/.cache/opencode/cache` |
| `OPENCODE_DATA_DIR`        | `$HOME/.local/share/opencode`    | `/home/other/.local/share/opencode` |
| `OPENCODE_CONFIG_DIR`      | `$HOME/.config/opencode`         | `/home/other/.config/opencode`      |
| `OPENCODE_PIP_CACHE_DIR`   | `$HOME/.cache/pip`               | `/home/other/.cache/pip`            |
| `OPENCODE_NPM_CACHE_DIR`   | `$HOME/.npm`                     | `/home/other/.npm`                  |
| `OPENCODE_GO_BUILD_CACHE_DIR` | `$HOME/.cache/go-build`       | `/home/other/.cache/go-build`       |
| `OPENCODE_GO_MOD_CACHE_DIR`   | `$HOME/go/pkg/mod`            | `/home/other/go/pkg/mod`            |
| `OPENCODE_CARGO_REGISTRY_DIR` | `$HOME/.cargo/registry`       | `/home/other/.cargo/registry`       |
| `OPENCODE_CARGO_GIT_DIR`      | `$HOME/.cargo/git`            | `/home/other/.cargo/git`            |
| `OPENCODE_SCCACHE_DIR`        | `$HOME/.cache/sccache`        | `/home/other/.cache/sccache`        |

The container-side paths are fixed: they must match the user baked into the
image (`other`, uid/gid 1000, see the `opencode/Dockerfile.*` variants).

### Launcher variables

These variables are read by `scripts/launcher.sh` from the shell environment
(they are not compose path variables):

| Variable                   | Default                    | Effect                                              |
|----------------------------|----------------------------|-----------------------------------------------------|
| `SD_OPENCODE`              | `$HOME/opencode`           | The repository holding the launcher and compose files |
| `SD_REPO_HOME`             | `/home/$USER/repos`        | Root for `scaffold`/`bg` `--path` targets, and the `uptree` worktree root's parent |
| `SD_AGENT_TREE_ROOT`       | `$SD_REPO_HOME/agent-trees` | Root holding `uptree` agent worktrees |
| `SD_DRIVER`                | `auto`                     | Container engine: `auto`, `docker` or `podman`. Only `docker` is implemented; `podman` exits with an error |
| `OPENCODE_IMAGE_URL`       | `devsnowdon/opencode-docker:duck` | – (build arg: base image for the `opencode` service) |
| `OPENCODE_IMAGE_URL_TUI`   | `devsnowdon/opencode-docker:empty` | – (image for the `tui` service) |
| `OPENCODE_CONTEXT`         | `.`                        | Docker build context directory passed to the compose `build` section. Derived from `OPENCODE_DOCKERFILE`'s directory when that is a file path and this is unset |
| `OPENCODE_DOCKERFILE`      | `Dockerfile`               | Dockerfile path (relative to the context) passed to the compose `build` section |
| `OPENCODE_COMPOSE`         | –                          | Space-separated extra `docker compose` files, merged into the project via `-f` |
| `OPENCODE_WORKSPACE`       | –                          | The current opencode workspace context; launches targeting a directory outside it prompt before using its environment |
| `OPENCODE_CACHE`           | –                          | Toolchain cache mounts to enable: `false` (default) none, `all` every cache, or space-separated ids (`go`, `node`, `python`, `rust`). Also selects the base image variant (`:empty`, `:duck`, `:full`) unless `OPENCODE_IMAGE_URL` is set |
| `OPENCODE_BACKEND_ORIGIN`  | `http://opencode:4096`, else resolved from `compose port` | Backend URL used for the health check and TUI attach |
| `OPENCODE_CPUSET`          | –                          | CPU pinning (e.g. `2-3`); unset by default (Docker uses all CPUs) |
| `OPENCODE_CPUS`            | –                          | CPU limit (e.g. `2`); unset by default (no quota)    |
| `SD_YOLO`                  | –                          | `true` (case-insensitive) skips the outside-`HOME` workspace check |
| `SD_YOLO_HOME`             | –                          | `true` validates workspaces against `SD_REPO_HOME` instead of `$HOME` |
| `SD_READ_ONLY`             | –                          | `false` (case-insensitive) skips the read-only `.git` override file |
| `OPENCODE_NET_RANGE`       | `172.20.0.0/16`            | CIDR or bare prefix defining the managed IP range     |
| `OPENCODE_NET_SUBNET`      | `29`                       | Subnet mask for each workspace network               |
| `DOCKER_ARGS`              | –                          | – (extra args passed to all docker commands)         |
| `COMPOSE_ARGS`             | –                          | – (extra args passed to every `docker compose` command) |

### Network isolation

The launcher supports three network modes controlled by `OPENCODE_NETWORK`:

1. **Unset (default)** — no external network is attached; the container uses
    Docker's default bridge network.
2. **`@default` (recommended)** — the launcher automatically creates a
    workspace-scoped bridge network named `sd-<project>-default` and attaches
    it to both the `opencode` and `tui` services, with a subnet allocated from
    `OPENCODE_NET_RANGE`. The network is reused across restarts: the launcher
    looks for an existing network labelled with the workspace before creating
    one. Cleanup happens via `opencode:delete --all` or `docker network rm`.
3. **Named network** — pass any existing Docker network name to attach both
    services to it, sharing a network between workspaces or external services.

```sh
OPENCODE_NETWORK=@default opencode
OPENCODE_NETWORK="my-shared-net" opencode
```

#### Subnet allocation

The range is sliced by `OPENCODE_NET_SUBNET`, and the launcher walks the slices
from a random offset, stepping by an odd number so every slot is visited exactly
once, taking the first that no existing managed network uses. A subnet mask
smaller than the range mask is rejected, since it would overlap the other
slices; a `/16` range sliced with the default `/29` gives 8192 subnets (6 usable
hosts each), and with `/24` gives 256 subnets (254 usable hosts each). When
every slice is taken the launcher exits with an error.

### Setting variables

Launcher variables are read from the environment and should not be set in a
`.env` file. Compose variables are resolved in this order:

1. Shell environment (`export OPENCODE_CACHE_DIR=/big/disk/cache`)
2. A `.env` file next to your compose files (by default `~/opencode/.env`,
    which is the project directory `docker compose` reads from)
3. The inline defaults in `docker-compose.yml`

#### Env file example

Add a file like the following to `~/opencode/.env` (only the paths you want to
move; every other path variable keeps its default).

```sh
OPENCODE_CACHE_DIR=/mnt/usb2/storage/opencode/cache/opencode/opencode/cache
OPENCODE_DATA_DIR=/opt/opencode-data/home/other/.local/share/opencode
OPENCODE_SCCACHE_DIR=/mnt/usb2/storage/opencode/cache/rust/sccache
```

## Worktrees

A git worktree is a first-class workspace. Its `.git` is a file pointing into
the parent repository, so the launcher records the parent and mounts its `.git`
read-only (see [Security model](#security-model)): git stays usable inside the
container while the worktree itself stays isolated. Add one and work in it from
the parent repository:

```sh
cd ~/repos/myproject
git worktree add ../myproject-wt worktree-branch
opencode:up "$(realpath ../myproject-wt)"
opencode:git status   # runs in the worktree
```

Conversely, when run from a parent repository that has exactly one worktree
child, commands resolve to that child, so `opencode:up` from the parent starts
the worktree's container. More than one child is an error.

### Worktree sync

Commands that hand work to the agent (`opencode`, `run`, `scaffold`, `bg`)
assert the worktree is in sync with the parent branch first: when the parent is
ahead and the worktree is clean it is fast-forwarded to match, otherwise the
launcher reports the divergence and exits. The remaining commands (`up`,
`setup`, `exec`, `shell`, `compose`, `changes`, `new`, `down`, `uptree`,
`repl`) skip this check.

### Agent worktrees (uptree)

`opencode:uptree` starts a container for an agent worktree living under
`SD_AGENT_TREE_ROOT` (default `$SD_REPO_HOME/agent-trees`, which must exist),
named after the project with a `-dev` suffix. The worktree has to exist already:
when it does not, the command prints the `git worktree add` line to run.

```sh
git worktree add -B some-branch "$SD_REPO_HOME/agent-trees/myproject-dev"
opencode:uptree ~/repos/myproject
```

## Interactive shell (repl)

`opencode:repl` opens a real interactive bash bound to the workspace, where
every command is available as its bare name with normal argument passing — for
example `run npm install` or `list --all`. The shell prepares the compose
arguments once, on entry, and inherits your `PATH` and environment; bare names
are only aliased where they do not shadow a command on your `PATH` (bash
builtins such as `exec` and `help` are overridden deliberately). `git` and
`uptree` are not aliased: use `opencode:git` and `opencode:uptree`. `exit`
leaves the shell.

## Start extending with custom functions

The function is valid in a zsh shell:

```shell
gist() {
    if (( $# == 0 )); then
        echo "No arguments, requires [path] (task)"
        echo "Task can also be via standard in"
    fi

    local name=$1
    shift

    local tmp_path="$HOME/repos/gists/$name"
    cd "$tmp_path" || {
        local no_args=$(( $# == 0 ))
        local not_terminal=0
        [[ ! -t 0 ]] && not_terminal=1

        if (( no_args != not_terminal )); then
            printf 'Warning:\nDirectory does not exist\nNo scaffold description was provided.\n' >&2
            echo "mkdir: $tmp_path"
            mkdir "$tmp_path"
            echo "cd:    $tmp_path"
            cd "$tmp_path"
            echo 'run:   opencode:scaffold ./ "Your task"'
            return
        fi

        mkdir "$tmp_path"
        cd "$tmp_path" || return 1

        if which git > /dev/null; then
            git init
            echo "# $name" > README.md
            git add README.md
            git commit -m "Initial commit."
        fi

        # start fresh environment to prevent reusing a projects defaults
        env -i ZDOTDIR="$ZDOTDIR" zsh -ic 'opencode:scaffold ./ "$@"' zsh "$@"
    }
}
```

Please share your extensions in the discussions section.

## Build

The base image [devsnowdon/opencode-docker](https://hub.docker.com/r/devsnowdon/opencode-docker)
is prebuilt, and the workspace image is `FROM` it — extend the base with
`/Dockerfile`, or see the base image in `/opencode/Dockerfile.*`.

### Base Dockerfile

The base image is **layered** into three published variants, each a thin
`FROM` of the previous one so Docker Hub shares the common layers:

| Variant | Contents | Tags |
|---------|----------|------|
| `empty` | Minimal CLI base (`opencode` binary, `git`, `curl`, `bash`, `ripgrep`, `make`, user `other`) | `:empty` |
| `duck`  | `empty` + Node.js, npm, Python, pip | `:duck` |
| `full`  | `duck` + Go + Go tools (`gopls`, `dlv`, `swag`, `golangci-lint`), C toolchain, Rust (opt-in via `INSTALL_RUST`) | `:full`, `:latest` |

`Dockerfile.empty` pulls the `opencode` CLI binary from the latest published
`ghcr.io/anomalyco/opencode` release (refreshed weekly by the update workflow)
and installs a minimal Alpine runtime; `Dockerfile.duck` and `Dockerfile.full`
`FROM` the variant below them. Every package is constrained to a minimum version
(e.g. `git>=2.54`), so a build never silently downgrades below what opencode
relies on, and the Dockerfiles are multi-arch aware (`linux/amd64` +
`linux/arm64`).

The `opencode` service build defaults to `:duck` as its base image (deliberately
kept slim so the first build does not pull the full toolchains); set
`OPENCODE_IMAGE_URL` to a different tag (e.g. `:full` or `:empty`) to build the
compose layer on that base. The throwaway `tui` service defaults to `:empty`
(`OPENCODE_IMAGE_URL_TUI`).

#### Local builds (Makefile)

Build the layered images locally with the latest opencode version. Variants must
be built in order, each `FROM` the one below it:

```sh
make build            # native build of empty, duck, full (and :latest alias)
make build-arch       # buildx single arch, loaded (ARCH=amd64|arm64)
make build-amd64      # convenience: make build-arch ARCH=amd64
make build-arm64      # convenience: make build-arch ARCH=arm64
make build-multi      # buildx multi-arch manifests for all three variants, pushed
make pipeline         # native build + push all three variants to the registry
make builder          # create the docker-container buildx builder (once)
make build-empty      # only the :empty layer
make build-duck       # only the :duck layer
```

`make build` passes `--build-arg INSTALL_RUST=true` — set `RUST=false`
(`make build RUST=false`) to skip the Rust toolchain in the full image. The
image tag defaults to `registry.lan:5000/snowdon-dev/opencode`; override it
with `REGISTRY` (e.g. `make build REGISTRY=my.dev/opencode`). Multi-arch
manifest pushes need the container-driver builder (`make builder`).

## Testing

The launcher has a unit-test suite that runs it against **mocked** binaries
(`tests/mockbin/`) — `docker`, `curl` and `opencode` — so no Docker daemon is
required. The mock `docker` records the exact `docker ...` command each
subcommand would run, and the tests assert those commands.

```sh
make test                 # run the whole suite
./tests/run_tests.sh up   # run a single test by name (down, stop, exec, run, ...)
```

Each test builds a throwaway sandbox under `/tmp` and removes it afterwards;
`tests/run_tests.sh` documents the runner in more detail, including how to run
the launcher by hand with the mock on your `PATH`.

## Contributing

Changes are welcome as pull requests. By submitting, you agree your
contributions are licensed under the same license as the project
(GPL-3.0-or-later). Keep PRs focused; one logical change per request.

## License

Copyright © snowdon.dev (hello@snowdon.dev). Licensed under the [GNU General
Public License v3.0](LICENSE) or later.

Any redistributed modified version must be released under GPL-3.0 with its
full source code — if you share changes, send them back upstream so everyone
benefits.
