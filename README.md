# opencode dev container

[![Docker Pulls](https://img.shields.io/docker/pulls/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Version](https://img.shields.io/docker/v/devsnowdon/opencode-docker?sort=semver)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)

A security and human-control oriented [opencode](https://opencode.ai) workflow
that runs in a Docker container. The current project bind-mounted at
`/workspace`, plus persistent caches for full language toolchains installed in
the image (Go, Rust, Node, Python). All features are security first with
convenience opts in.

This project has been designed for arm architecture devices like the [Raspberry
Pi](https://www.raspberrypi.com/). However, it should be compatible with x86.

The version of opencode is best-effort and updated periodically (weekly), feel
free to file an issue if it is out-of-date. See [Build](#build) section.

## Usage

```shell
opencode:help
opencode
opencode:new
opencode:run npm install
opencode:up
opencode:setup npm install
opencode:down
opencode:stop
opencode:stop --all
opencode:delete
opencode:delete --all
opencode:ls
opencode:ls --all
opencode:ls --quiet ~/somerepo
opencode:exec sh
opencode:shell
opencode:compose exec -it opencode sh
opencode:changes "identify issues in these changes"
opencode:scaffold path "the task"
opencode:scaffold /tmp/project < /tmp/sometask.md
opencode:bg path "the task"
opencode:bg ./ "refactor this module"

opencode -c --auto
opencode /home/other/somerepo
opencode:exec /home/other/somerepo sh
opencode:down /home/other/somerepo
opencode:scaffold /home/pi/repos/gists/project-1 "Create basic hello world html project"
opencode:scaffold gists/project-1 "Create basic hello world html project"
opencode:scaffold project-2 "$(cat /tmp/sometask.md)"

mkdir "$HOME/repos/gists/gotester" && cd "$HOME/repos/gists/gotester"
oc:sf ./ "Create a hello world go project."
oc:sf ./newmodule "Create a golang package that exports a function that adds integers. No go.mod"

OPENCODE_IMAGE_URL="my-custom-image:latest" opencode
OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:duck" opencode
OPENCODE_NETWORK="custom-network" opencode
OPENCODE_NETWORK="@default" opencode

# start the container already ready to go
cd ~/project
opencode:setup sh -c 'cd front-end && npm install' && opencode
```

## Features

- [x] Security: Prevent potential destructive actions by the agent
- [x] Security: Configure project isolated cache storage via environment
  variables
- [ ] Security: Add project specific OPENCODE_DATA_DIR and cache via argument
  flags
- [ ] Security: Argument based worktree helpers to isolate node_modules or
  mount a tmp_dir
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
- [ ] Build image from a workspace path instead of the same /Dockerfile in the
  opencode root. Point at a folder for the workspace, and a context at the workspace
- [x] Layered containers - full(rust, go, c, node, python) - duck(node, python)
  empty.
- [ ] Layered containers - [development containers spec](https://containers.dev/implementors/spec/)
- [x] Layered containers - In the docker compose, use build. and add a docker
  that uses FROM image-full
- [x] Fix: Allow multiple port bindings to enable multiple running agents on
  multiple projects
- [ ] Project creation with scaffold extra context
- [ ] /Dockerfile should only be added if a Dockerfile exists. Otherwise use
  image - Then image does not have a workspace

## Install

Clone the repository to `~/opencode`:

```shell
git clone https://github.com/snowdon-dev/opencode-docker.git ~/opencode
```

`scripts/launcher.sh` looks for the compose files in `~/opencode`, so link the
repository there:

This also means a `.env` placed in the repository root is picked up by both
plain `docker compose` runs. See [Environment
variables](#environment-variables). The launcher also requires seperate
variables, see [Launcher variables](#launcher-variables) sections. However,
only one environment variable is actually required. The reset are avaliable for
custom configuration or custom profiles.

`docker-compose.yml` now has a `build:` section, so `docker compose up` builds
the local image from the repository `Dockerfile` (which layers on top of the
published [base image](https://hub.docker.com/r/devsnowdon/opencode-docker))
unless `OPENCODE_IMAGE_URL` points at a prebuilt image. Run `opencode:update`
(alias `oc:u`).

When `opencode` (the `start` command) runs, the launcher starts an `opencode
serve` backend inside the container, waits until it is healthy, and then
attaches a TUI to it — using a host `opencode` binary if one is on the `PATH`,
otherwise the one-off `tui` compose service. The old backend is killed when the
TUI exits. Run, changes, setup, bg commands create a onoff container.

## oh-my-zsh plugin

You should use the `opencode` launcher utility to launch the container, as it
sets up several required environment variables, such as `WORKSPACE`, during
initialization.

The `omz` plugin is very lightweight and is not required. You can—and are
encouraged to—create your own profiles and environments using whichever shell
you prefer.

Instead of running the compose directly, install as an omz plugin for handy
commands.

`omz/opencode.zsh` provides shell aliases (`opencode`, `oc`, `oc:s`,
`oc:u`, `oc:d`, `oc:del`, `oc:c`, ...) wrapping the launcher. It also defines
`opencode:update` (alias `oc:u`), which pulls the base image and rebuilds the
local image layered on top of it. Link it as an oh-my-zsh custom plugin:

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

After restarting your shell (`exec zsh`). View the available commands by
running `alias | grep -E ^oc` or `alias | grep opencode`. Then try running
`opencode:help` to see the full help information.

## Environment setup steps

- An environment variable for `SD_OPENCODE` should be set to tell the program
  the location of the repo
- If not otherwise specified the environment default will only use 2 cpus.
- An environment `SD_REPO_HOME` variable sets the root location used when
  building non-absolute paths in the scaffold command.
- The opencode binary from the shell path to run the TUI (`npm i -g
  opencode-ai`) if one exists.
- Docker is required [docker.io](https://www.docker.com/)

### Creating the directories

The container runs as the `other` user (uid/gid `1000`), so every host
directory bind-mounted under `/home/other/...` (see
[`docker-compose.yml`](docker-compose.yml)) must exist and be writable by that
user. With default paths, create them like this:

```sh
mkdir -p \
  "$HOME/.cache/opencode/cache" \
  "$HOME/.local/share/opencode" \
  "$HOME/.config/opencode" \
  "$HOME/.cache/pip" \
  "$HOME/.npm" \
  "$HOME/.cache/go-build" \
  "$HOME/go/pkg/mod" \
  "$HOME/.cargo/registry" \
  "$HOME/.cargo/git" \
  "$HOME/.cache/sccache"
```

Then hand them over to user `1000:1000`:

```sh
chown -R 1000:1000 \
  "$HOME/.cache/opencode" \
  "$HOME/.local/share/opencode" \
  "$HOME/.config/opencode" \
  "$HOME/.cache/pip" \
  "$HOME/.npm" \
  "$HOME/.cache/go-build" \
  "$HOME/go/pkg/mod" \
  "$HOME/.cargo/registry" \
  "$HOME/.cargo/git" \
  "$HOME/.cache/sccache"
```

Your project workspace also gets bind-mounted (at `/workspace`) and is written
to by the container, so it too must be owned by `1000:1000`:

```sh
chown -R 1000:1000 "$WORKSPACE"
```

> If you override any path via `.env` (e.g. `OPENCODE_SCCACHE_DIR`), create
> that directory instead and `chown -R 1000:1000` it. Do not run these commands
> with `sudo` unless the directories live outside your home directory.

> The toolchain cache directories (`pip`, `npm`, `go`, `rust`/`sccache`) are
> only mounted when you enable them with `OPENCODE_CACHE` (they are opt-in for
> security). If you leave `OPENCODE_CACHE` unset you can skip creating and
> chowning those directories.

## Environment variables

### Compose variables

All host-side paths are configured with environment variables. Substitution
happens on the host when `docker compose` runs, and every variable has a
default pointing at the conventional location under your home directory
(`.cache`, `.local`, `.npm`, etc.).

| Variable                   | Default                          | Mounted at (container)              |
|----------------------------|----------------------------------|-------------------------------------|
| `OPENCODE_IMAGE_URL`       | `devsnowdon/opencode-docker:full` | – (build arg: base image for the `opencode` service) |
| `OPENCODE_IMAGE_URL_TUI`   | `devsnowdon/opencode-docker:empty` | – (image for the `tui` service) |
| `WORKSPACE`                | `.`                              | `/workspace`                        |
| `OPENCODE_CPUSET`          | `2-3`                            | – (CPU pinning)                     |
| `OPENCODE_NETWORK`         | –                                | – (external network, see `compose-net/docker-compose.network.yml`) |
| `OPENCODE_CACHE_DIR`       | `$HOME/.cache/opencode/cache`    | `/home/other/.cache/opencode/cache` |
| `OPENCODE_DATA_DIR`        | `$HOME/.local/share/opencode`    | `/home/other/.local/share/opencode` |
| `OPENCODE_CONFIG_DIR`      | `$HOME/.config/opencode`         | `/home/other/.config`               |
| `OPENCODE_PIP_CACHE_DIR`   | `$HOME/.cache/pip`               | `/home/other/.cache/pip`            |
| `OPENCODE_NPM_CACHE_DIR`   | `$HOME/.npm`                     | `/home/other/.npm`                  |
| `OPENCODE_GO_BUILD_CACHE_DIR` | `$HOME/.cache/go-build`       | `/home/other/.cache/go-build`       |
| `OPENCODE_GO_MOD_CACHE_DIR`   | `$HOME/go/pkg/mod`            | `/home/other/go/pkg/mod`            |
| `OPENCODE_CARGO_REGISTRY_DIR` | `$HOME/.cargo/registry`       | `/home/other/.cargo/registry`       |
| `OPENCODE_CARGO_GIT_DIR`      | `$HOME/.cargo/git`            | `/home/other/.cargo/git`            |
| `OPENCODE_SCCACHE_DIR`        | `$HOME/.cache/sccache`        | `/home/other/.cache/sccache`        |

The container-side paths are fixed: they must match the user baked into the
image (`other`, uid/gid 1000, see the `opencode/Dockerfile.*` variants).

The toolchain cache mounts (`OPENCODE_PIP_CACHE_DIR`, `OPENCODE_NPM_CACHE_DIR`,
`OPENCODE_GO_BUILD_CACHE_DIR`, `OPENCODE_GO_MOD_CACHE_DIR`,
`OPENCODE_CARGO_REGISTRY_DIR`, `OPENCODE_CARGO_GIT_DIR`,
`OPENCODE_SCCACHE_DIR`) are **not** mounted by default. They are defined in the
dedicated override files `compose-vol/docker-compose.python.yml`,
`compose-vol/docker-compose.node.yml`, `compose-vol/docker-compose.go.yml`,
`compose-vol/docker-compose.rust.yml` (and the combined
`compose-vol/docker-compose.cache.yml`), which the launcher only merges in when
`OPENCODE_CACHE` is set — see below. This is a deliberate, security-first
breaking change: toolchain caches hold executable artifacts that get run inside
the container, so they are no longer mounted unconditionally. Opt into exactly
the toolchains you need.

### Launcher variables

These variables are read by `scripts/launcher.sh` from the shell environment
(they are not compose path variables):

| Variable                   | Default                    | Effect                                              |
|----------------------------|----------------------------|-----------------------------------------------------|
| `OPENCODE_COMPOSE`         | –                          | Space-separated extra `docker compose` files, merged into the project via `-f` |
| `OPENCODE_CACHE`           | –                          | Toolchain cache mounts to enable: `false` (default) none, `all` every cache, or space-separated ids (`go`, `node`, `python`, `rust`) |
| `OPENCODE_BACKEND_ORIGIN`  | resolved from `compose port` | Backend URL used for the health check and TUI attach |
| `SD_YOLO`                  | –                          | `true` (case-insensitive) skips the outside-`HOME` workspace check |
| `SD_YOLO_HOME`             | –                          | `true` validates workspaces against `SD_REPO_HOME` instead of `$HOME` |
| `SD_READ_ONLY`             | –                          | `false` (case-insensitive) skips the read-only `.git` override file |
| `OPENCODE_NET_RANGE`       | `172.20.0.0/16`                  | – (IP range for managed networks)  |
| `OPENCODE_NET_SUBNET`      | `24`                             | – (subnet mask for individual networks) |
| `DOCKER_ARGS`              | –                                | – (extra args passed to all docker commands) |

Details:

- `OPENCODE_COMPOSE` — each entry must be a regular file with a `.yml` or
  `.yaml` extension; anything else aborts the launcher. The files are passed
  to `docker compose -f` alongside the base and (optional) network/git
  override files.
- `OPENCODE_CACHE` — controls which host toolchain cache directories are
  mounted into the container. Unset or `false` mounts none (the security-first
  default). `all` mounts every toolchain cache via
  `compose-vol/docker-compose.cache.yml`.
  A space-separated list of case-insensitive ids mounts only those, each
  defined in a dedicated override file: `python`
  (`compose-vol/docker-compose.python.yml`,
  pip cache), `node` (`compose-vol/docker-compose.node.yml`, npm cache), `go`
  (`compose-vol/docker-compose.go.yml`, go build + module cache), `rust`
  (`compose-vol/docker-compose.rust.yml`, cargo registry + git + sccache). Any unknown id
  aborts the launcher. This is a breaking change: the toolchain caches used to
  be mounted by default and are now opt-in, because cached toolchain artifacts
  are executed inside the container. Example:
  `export OPENCODE_CACHE="go rust"`.
- `OPENCODE_BACKEND_ORIGIN` — `docker-compose.yml` publishes the backend on a
  random host port (`"0:4096"`). The launcher resolves the assigned mapping with
  `opencode:compose port opencode 4096` and uses `http://127.0.0.1:<that port>`
  for the health check and TUI attach; setting this variable overrides the whole
  origin. The throwaway `tui` container instead uses `http://opencode:4096`, the
  in-network service name and port.
- `SD_YOLO` / `SD_YOLO_HOME` — without these the launcher requires the
  workspace to be a subdirectory of `$HOME` (or of `SD_REPO_HOME` when
  `SD_YOLO_HOME` is `true`) and prompts for confirmation otherwise. `SD_YOLO`
  disables that check entirely. If you like extra security, this is a good
  option to set.
- `SD_READ_ONLY` — by default the launcher finds every `.git` directory inside
  the workspace and mounts it read-only (`:ro`) via a generated compose
  override file, so opencode can read git state but not corrupt it. Setting
  `SD_READ_ONLY=false` (case-insensitive) disables this: the `.git` lookup and
  override file are skipped and the workspace is mounted without the
  read-only overlay. Useful when you need the container to be able to write
  to `.git` (e.g. running your own git commands) or when the workspace sits on
  a filesystem that does not support read-only bind mounts.

### Network isolation

The launcher supports three network modes controlled by `OPENCODE_NETWORK`:

1. **Unset (default)** — no external network is attached; the container uses
   Docker's default bridge network.
2. **`@default` (recommended)** — the launcher automatically creates a
   workspace-scoped bridge network named `sd-<project>-default` and attaches
   it to both the `opencode` and `tui` services. The subnet is allocated from
   the managed IP range, ensuring each workspace is isolated by default.

   ```sh
   OPENCODE_NETWORK="@default" opencode
   OPENCODE_NETWORK=@default
   ```

   The network is reused across restarts: the launcher checks for an existing
   network labeled with the workspace before creating a new one. Cleanup
   happens via `opencode:delete --all` or `docker network rm`.

3. **Named network** — pass any existing Docker network name to attach both
   services to that network. Useful when you want multiple workspaces (or
   external services) to share a network:

   ```sh
   OPENCODE_NETWORK="my-shared-net" opencode
   ```

#### Subnet allocation

When using `@default`, the launcher allocates subnets from a configurable IP
range. Two variables control allocation:

| Variable               | Default           | Effect                                                  |
|------------------------|-------------------|---------------------------------------------------------|
| `OPENCODE_NET_RANGE`   | `172.20.0.0/16`   | CIDR or bare prefix defining the managed IP range       |
| `OPENCODE_NET_SUBNET`  | `24`              | Subnet mask for each workspace network                  |

`OPENCODE_NET_RANGE` accepts both full CIDR notation (`172.20.0.0/16`) and
shorthand prefixes (`172.20` — the mask is inferred as 8 bits per octet, capped
at `/24`). A `/16` range provides 256 non-overlapping `/24` subnets (each
yielding 254 usable host addresses).

The launcher iterates through the sliced subnets and selects the first one not
already in use by any existing Docker network. If all subnets are occupied, the
launcher exits with an error.

```sh
# Use a different range
OPENCODE_NET_RANGE="10.10.0.0/16" OPENCODE_NET_SUBNET="24" opencode

# Use a smaller slice inside the default range
OPENCODE_NET_RANGE="172.20.0.0/16" OPENCODE_NET_SUBNET="28" opencode
```

### Setting variables

Launcher variables are taken from the environment, and used when launching.
Should not be set in the `.env.` file.
Compose variables can be set in two ways, with the following precedence:

1. Shell environment (`export OPENCODE_CACHE_DIR=/big/disk/cache`)
2. A `.env` file placed next to `docker-compose.yml` (loaded automatically)
3. The inline defaults in `docker-compose.yml`

Example `.env`:

```sh
# .env — lives next to docker-compose.yml; do not commit it
OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:duck
OPENCODE_IMAGE_URL_TUI=devsnowdon/opencode-docker:empty
OPENCODE_CACHE_DIR=/mnt/big-disk/opencode-cache
OPENCODE_SCCACHE_DIR=/mnt/big-disk/sccache
```

If you use `scripts/launcher.sh`, put the `.env` file next to your compose
files (by default `~/opencode/.env`), since that is the project directory
docker compose reads from — or simply export the variables in your shell rc.

### Env file example

Add a file like the following to `~/opencode/.env`.

```sh
OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:full
OPENCODE_IMAGE_URL_TUI=devsnowdon/opencode-docker:empty
OPENCODE_CACHE_DIR=/mnt/usb2/storage/opencode/cache/opencode/opencode/cache
OPENCODE_DATA_DIR=/opt/opencode-data/home/other/.local/share/opencode
OPENCODE_PIP_CACHE_DIR=/mnt/usb2/storage/opencode/cache/python/pip
OPENCODE_NPM_CACHE_DIR=/mnt/usb2/storage/opencode/cache/node/npm
OPENCODE_GO_BUILD_CACHE_DIR=/mnt/usb2/storage/opencode/cache/go/go-build
OPENCODE_GO_MOD_CACHE_DIR=/mnt/usb2/storage/opencode/cache/go/go-pkg-mod
OPENCODE_CARGO_REGISTRY_DIR=/mnt/usb2/storage/opencode/cache/rust/crate-registry
OPENCODE_CARGO_GIT_DIR=/mnt/usb2/storage/opencode/cache/rust/cargo-git
OPENCODE_SCCACHE_DIR=/mnt/usb2/storage/opencode/cache/rust/sccache
```

## Start extending with custom functions

```shell
gist() {
  local name=$1
  shift

  local tmp_path="$HOME/repos/gists/$name"
  cd "$tmp_path" || {
    if (( $# == 0 )); then
      printf 'Warning:\nDirectory does not exist\nNo scaffold description was provided.\n' >&2
      echo "mkdir: $tmp_path"
      mkdir "$tmp_path"
      echo "cd:    $tmp_path"
      cd "$tmp_path"
      echo 'run:   opencode:scaffold ./ "Your task"'
      return
    fi

    mkdir "$tmp_path"
    cd "$tmp_path" || exit 1

    if which git > /dev/null; then
      git init
      echo "# $name" > README.md
      git add README.md
      git commit -m "Initial commit."
    fi

    opencode:scaffold ./ "$@"
  }
}
```

Please share your extensions in the discussions section.

## Build

The launcher has two image build stages. The base image
[devsnowdon/opencode-docker](https://hub.docker.com/r/devsnowdon/opencode-docker)
that is prebuilt and the user image that is `FROM` the base image. To extend
the base image see the Dockerfile `/Dockerfile`. To see the base image
`/opencode/Dockerfile.*`.

### Base Dockerfile

The base image is **layered** into three published variants, each a thin
`FROM` of the previous one so Docker Hub shares the common layers:

| Variant | Contents | Tags |
|---------|----------|------|
| `empty` | Minimal CLI base (`opencode` binary, `git`, `curl`, `bash`, `ripgrep`, `make`, user `other`) | `:empty` |
| `duck`  | `empty` + Node.js, npm, Python, pip | `:duck` |
| `full`  | `duck` + Go + Go tools (`gopls`, `dlv`, `swag`, `golangci-lint`), C toolchain, Rust (opt-in via `INSTALL_RUST`) | `:full`, `:latest` |

The default base image for both the `opencode` service build and the `tui`
service is `:full` (`:latest` is an alias for back-compat). Set
`OPENCODE_IMAGE_URL` to a different tag (e.g. `:duck`) to build the compose
layer on a slimmer base.

The image is built from the `opencode/` Dockerfiles as a multi-stage build:

1. `opencode/Dockerfile.empty` — pulls the `opencode` CLI binary from a pinned
   `ghcr.io/anomalyco/opencode` release, installs a minimal Alpine runtime and
   creates the unprivileged `other` user.
2. `opencode/Dockerfile.duck` — `FROM ${OPENCODE_BASE_URL}:empty`, adds Node.js
   and Python runtimes.
3. `opencode/Dockerfile.full` — `FROM ${OPENCODE_BASE_URL}:duck`, adds Go, Go
   tools, the C/C++ build toolchain, and (when `INSTALL_RUST=true`) the Rust
   toolchain with rustup, rustfmt, clippy, sccache and the mold linker.

Every package is pinned to an exact version in the Dockerfiles so builds are
reproducible, and the Dockerfiles are multi-arch aware (`linux/amd64` +
`linux/arm64`).

#### Local builds (Makefile)

Build the layered images locally with the latest opencode version:

```sh
make build            # native build of empty, duck, full (and :latest alias)
make build-arch       # buildx single arch, loaded (see ARCH= below)
make build-amd64      # convenience: make build-arch ARCH=amd64
make build-arm64      # convenience: make build-arch ARCH=arm64
make build-multi      # buildx multi-arch manifests for all three variants, pushed
make pipeline         # native build + push all three variants to the registry
make builder          # create the docker-container buildx builder (once)
```

To build a single variant only:

```sh
make build-empty      # only the :empty layer
make build-duck       # only the :duck layer (requires :empty to exist)
make build            # builds empty + duck + full in order
```

Notes:

- `make build` passes `--build-arg INSTALL_RUST=true` — set `RUST=false`
  (`make build RUST=false`) to skip the Rust toolchain in the full image.
- Single-arch and multi-arch builds use `docker buildx`. Multi-arch manifest
  pushes need the container-driver builder, created once with `make builder`.
- The image tag is hardcoded to `registry.lan:5000/snowdon-dev/opencode`.
  Override it with a variable, e.g. `make build REGISTRY=my.dev/opencode`.

### Versioning (svu)

Tags are bumped with [svu](https://github.com/caarlos0/svu) (Semantic Version
Utility), which computes the next version from the latest `v*` tag:

```sh
go install github.com/caarlos0/svu@latest

make tag-patch   # v1.2.3 -> v1.2.4
make tag-minor   # v1.2.3 -> v1.3.0
make tag-major   # v1.2.3 -> v2.0.0
```

Each target creates `git tag $(svu <level>)` and runs `git push --tags`.
Pushing a `v*` tag triggers the CI build (see below).

### Continuous integration

- **GitHub Actions — `.github/workflows/build-push.yaml`**: on pushes to
  `main`, pushes of a `v*` tag, or manual dispatch, builds the `linux/amd64`
  and `linux/arm64` variants (`empty`, `duck`, `full`) in order and pushes the
  multi-arch manifests to Docker Hub.
  Requires the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets.

## Testing

The launcher has a small unit-test suite that runs it against **mocked**
binaries (`tests/mockbin/`) — `docker`, `curl`, and `opencode` — so no Docker
daemon is required.

Instead of executing anything, the mock `docker` records the exact `docker ...`
command each subcommand would run. The tests (`tests/run_tests.sh`) assert those
invoked commands. The mock `curl` lets the backend health-check path succeed
(used by `start`), and the mock `opencode` captures the attach invocation.

Each test builds a throwaway sandbox under `/tmp` (never inside the repo) and
removes it afterwards:

```sh
make test                 # run the whole suite
./tests/run_tests.sh up   # run a single test by name (down, stop, exec, run, ...)
```

To see exactly which docker commands the launcher would issue for a given
subcommand (e.g. `up`), run it directly with the mock on your `PATH`:

```sh
export PATH="$PWD/tests/mockbin:$PATH"
export SD_OPENCODE="$PWD" WORKSPACE="$PWD"
./scripts/launcher.sh up ./some/workspace
# MOCK DOCKER: docker compose -p ... up -d opencode
```

## Contributing

Changes are welcome — please submit them back to this repository as pull
requests (or emailed patches) rather than keeping modified versions private.
By submitting, you agree your contributions are licensed under the same
license as the project (GPL-3.0-or-later). Keep PRs focused; one logical
change per request.

## License

Copyright © snowdon.dev (hello@snowdon.dev). Licensed under the [GNU General
Public License v3.0](LICENSE) or later.

Any redistributed modified version must be released under GPL-3.0 with its
full source code — if you share changes, send them back upstream so everyone
benefits.
