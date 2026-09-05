# opencode dev container

[![Docker Pulls](https://img.shields.io/docker/pulls/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Version](https://img.shields.io/docker/v/devsnowdon/opencode-docker?sort=semver)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![.github/workflows/build-push.yaml](https://github.com/snowdon-dev/opencode-docker/actions/workflows/build-push.yaml/badge.svg)](https://github.com/snowdon-dev/opencode-docker/actions/workflows/build-push.yaml)

A security and human-control oriented [opencode](https://opencode.ai) workflow
that runs in a Docker container. The current project bind-mounted at
`/workspace`, plus persistent caches for full language toolchains installed in
the image (Go, Rust, Node, Python).

This project has been desgined for arm archetecture devices like the [Raspberry
Pi](https://www.raspberrypi.com/). However, it should be compatible with x86.

The version of opencode is best-effort and updated periodically, feel free to
file an issue if it is out-of-date. See [Build](#build) section.

## Usage

```shell
opencode:help
opencode
opencode:new
opencode:run "npm install"
opencode:up
opencode:setup "npm install"
opencode:stop
opencode:end
opencode:delete
opencode:exec sh
opencode:shell
opencode:compose exec -it opencode sh
opencode:changes "identify issues in these changes"
opencode:scaffold path "the task"
opencode:scaffold /tmp/project < /tmp/sometask.md

opencode -c --auto
opencode /home/other/somerepo
opencode:exec /home/other/somerepo sh
opencode:stop /home/other/somerepo
opencode:scaffold /home/pi/repos/gists/project-1 "Create basic hello world html project"
opencode:scaffold gists/project-1 "Create basic hello world html project"
opencode:scaffold project-2 "$(cat /tmp/sometask.md)"

mkdir "$HOME/repos/gists/gotester" && cd "$HOME/repos/gists/gotester"
oc:sf ./ "Create a hello world go project."
oc:sf ./newmodule "Create a golang package that exports a function that adds integers. No go.mod"

OPENCODE_IMAGE_URL="my-custom-image" opencode
OPENCODE_NETWORK="custom-network" opencode

# start the container already ready to go
cd ~/project
opencode:setup "npm intsall" && opencode
```

## Features

- [x] Security: Prevent potential destructive actions by the agent
- [x] Security: Configure project isolated cache storage via environment variables
- [ ] Security: Add project specific OPENCODE_DATA_DIR and cache via argument flags
- [ ] Security: Argument based worktree helpers to isolate node_modules or mount a tmp_dir
- [ ] Security: Auto update. Pin tools to any security updates. Github workflow
- [x] [Docker](https://www.docker.com/) base container for opencode work
- [x] Convenience launcher script
- [x] [ohmyzsh](https://github.com/ohmyzsh/ohmyzsh/wiki/Customization) plugin abillity
- [x] [Add github build - docker step by step guide](https://docs.docker.com/guides/gha/)
- [x] Prevent large arguments leaks and enable task via std
- [x] Allow easy mounting of the config dir
- [ ] Layered containers - full(rust, go, c, node, python) - duck(node, python) - empty.
- [ ] Layered containers - [development containers spec](https://containers.dev/implementors/spec/)
- [ ] Layered containers - In the docker compose, use build. and add a docker that uses FROM image-full
- [ ] Fix: Allow multiple port bindings to enable multiple running agents on mulitple projects
- [ ] Project creation with scaffold extra context

## Install

Clone the repository to `~/opencode`:

```shell
git clone https://github.com/snowdon-dev/opencode-docker.git ~/opencode
```

`scripts/launcher.sh` looks for the compose files in `~/opencode`, so link the
repository there:

This also means a `.env` placed in the repository root is picked up by both
plain `docker compose` runs and the launcher. See [Environment
variables](#environment-variables).

`docker-compose.yml` now has a `build:` section, so `docker compose up` builds
the local image from the repository `Dockerfile` (which layers on top of the
published [base image](https://hub.docker.com/r/devsnowdon/opencode-docker))
unless `OPENCODE_IMAGE_URL` points at a prebuilt image. Run `opencode:update`
(alias `oc:u`) or `docker compose pull && docker compose build` to refresh it
after a new release.

## Container Usage

You should use the opencode launcher utility to launch the container. As it needs environment variables to (like WORKSPACE) init properly. See oh-my-zsh plugin.

```sh
docker compose up -d opencode
docker compose exec -w /workspace opencode opencode
```

When `opencode` (the `start` command) runs, the launcher starts an
`opencode serve` backend inside the container on port `4096`, waits until it
is healthy, and then attaches a TUI to it — using a host `opencode` binary if
one is on the `PATH`, otherwise the one-off `tui` compose service. The old
backend is killed when the TUI exits.

## oh-my-zsh plugin

Instead of running the compose directly, install as a omz plugin for handy commands.

`omz/opencode.zsh` provides shell aliases (`opencode`, `oc`, `oc:s`,
`oc:u`, `oc:e`, `oc:c`, ...) wrapping the launcher. It also defines
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

After restarting your shell (`exec zsh`). View the avaliable commands by
running `alias | grep -E ^oc` or `alias | grep opencode`. Then try running
`opencode:help` to see the full help information.

## Environment setup steps

- An environment variable for `SD_OPENCODE` should be set to tell the program
  the location of the repo
- If not otherwise specified the environment default will only use 2 cpus.
- An environment `SD_REPO_HOME` variable sets the root location used when
  building non-absolute paths in the scaffold command.
- The opencode binary from the shell path to run the TUI (`npm i -g opencode-ao`) if one exists.
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

## Environment variables

All host-side paths are configured with environment variables. Substitution
happens on the host when `docker compose` runs, and every variable has a
default pointing at the conventional location under your home directory
(`.cache`, `.local`, `.npm`, etc.).

| Variable                   | Default                          | Mounted at (container)              |
|----------------------------|----------------------------------|-------------------------------------|
| `WORKSPACE`                | `.`                              | `/workspace`                        |
| `OPENCODE_CPUSET`          | `2-3`                            | – (CPU pinning)                     |
| `OPENCODE_NETWORK`         | –                                | – (external network, see `docker-compose.network.yml`) |
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
image (`other`, uid/gid 1000, see `opencode/Dockerfile`).

### Setting variables

Variables can be set in two ways, with the following precedence:

1. Shell environment (`export OPENCODE_CACHE_DIR=/big/disk/cache`)
2. A `.env` file placed next to `docker-compose.yml` (loaded automatically)
3. The inline defaults in `docker-compose.yml`

Example `.env`:

```sh
# .env — lives next to docker-compose.yml; do not commit it
OPENCODE_CACHE_DIR=/mnt/big-disk/opencode-cache
OPENCODE_SCCACHE_DIR=/mnt/big-disk/sccache
```

If you use `scripts/launcher.sh`, put the `.env` file next to your compose
files (by default `~/opencode/.env`), since that is the project directory
docker compose reads from — or simply export the variables in your shell rc.

### Env file example

Add a file like the following to `~/opencode/.env`.

```sh
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

## Build

The launcher has two image build stages. The base image
[devsnowdon/opencode-docker](https://hub.docker.com/r/devsnowdon/opencode-docker)
that is prebuilt and the user image that is `FROM` the base image. To extend
the base image see the Dockerfile `/Dockerfile`. To see the base image
`/opencode/Dockerfile`.

### Base Dockerfile

The image is built from `opencode/Dockerfile` as a multi-stage build:

1. **`opencode` stage** — pulls the `opencode` CLI binary from a pinned
   `ghcr.io/anomalyco/opencode` release.
2. **Runtime stage** — starts from a pinned Alpine release and installs the
   toolchains (Go, Node, Python) and CLI packages (git, curl, ripgrep, bash,
   ...). Every package is pinned to an exact version in the Dockerfile (apk
   packages, Go tools, Rust toolchain) so builds are reproducible, and the
   Dockerfile is multi-arch aware (`linux/amd64` + `linux/arm64`).
3. The full Rust toolchain (`clang`, `lld`, `mold`, rustup, sccache) is only
   installed when the `INSTALL_RUST=true` build argument is set.

#### Local builds (Makefile)

Build the image locally with the latest opencode version run the following:

```sh
make build              # native build, tagged registry.lan:5000/snowdon-dev/opencode
make build-amd64        # buildx: linux/amd64, loaded into the local daemon
make build-arm64        # buildx: linux/arm64, loaded into the local daemon
make build-multi        # buildx: linux/amd64 + linux/arm64 manifest list, pushed
make pipeline           # native build + push to the registry
make builder            # create the docker-container buildx builder (once)
```

Notes:

- `make build` passes `--build-arg INSTALL_RUST=true` — set `RUST=false`
  (`make build RUST=false`) to skip the Rust toolchain.
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
  and `linux/arm64` images and pushes a multi-arch manifest to Docker Hub.
  Requires the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets.

## Testing

The launcher has a small unit-test suite that runs it against a **mocked
`docker`** binary (`tests/mockbin/docker`), so no Docker daemon is required.

Instead of executing anything, the mock records the exact `docker ...` command
each subcommand would run. The tests (`tests/run_tests.sh`) assert those invoked
commands:

```sh
make test                 # run the whole suite
./tests/run_tests.sh up   # run a single test by name (stop, exec, run, ...)
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

## Notes

- Make sure host cache directories exist and are writable by the container:
  mounts targeting `/home/other/...` run as uid 1000, while `/root/...` targets
  (pip, npm) are written as root.
- `docker-compose.git.yml` mounts the workspace's `.git` directories read-only
  and `docker-compose.network.yml` attaches an external network
  (`OPENCODE_NETWORK`); both overlay the base file via `-f`.
- The compose file bind-mounts the host config directory
  (`OPENCODE_CONFIG_DIR`, default `$HOME/.config/opencode`) at
  `/home/other/.config`, and mounts this repository's `opencode/agent.md`
  read-only over the container's AGENTS.md
  (`/home/other/.config/opencode/AGENTS.md`). Edit the file to customise the
  system prompt the agents run under.

### Start extending with custom functions

```shell
gist() {
  local name=$1
  shift

  cd "$SD_HOME/gists/$name" || {
    if (( $# == 0 )); then
      printf 'Warning:\n gist Directory does not exist\nNo scaffold description was provided.\n' >&2
      return 1
    fi

    mkdir "gists/$name"

    if which git > /dev/null; then
      # Initialize git repository and create initial commit
      git init # assumed directory is empty
      echo "# $name" > README.md
      git add README.md
      git commit -m "Initial commit."
    fi

    opencode:scaffold "gists/$name" "$@"
  }
}
```

Please share your extensions in the discussions section.

## License

Copyright © snowdon.dev (hello@snowdon.dev). Licensed under the [GNU General
Public License v3.0](LICENSE) or later.

Any redistributed modified version must be released under GPL-3.0 with its
full source code — if you share changes, send them back upstream so everyone
benefits.
