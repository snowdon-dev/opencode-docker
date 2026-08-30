# opencode dev container

Runs [opencode](https://opencode.ai) in a Docker container with the current
project bind-mounted at `/workspace`, plus persistent caches for the language
toolchains installed in the image (Go, Rust, Node, Python).

This project has been desgined for arm archetecture devices like the [Raspberry
Pi](https://www.raspberrypi.com/). However, it should be compatible with x86.

Open opencode on the current project

```shell
opencode
opencode:exec
opencode:stop
opencode:compose
opencode:scaffold
opencode:help

opencode /home/other/somerepo

opencode:exec /home/other/somerepo sh

opencode:scaffold somefolder "Create basic hello world html project"
opencode:scaffold /home/pi/project-1 "Create basic hello world html project"
opencode:scaffold gists/html-hello "Create basic hello world html project"
opencode:scaffold gists/html-hello "$(cat /tmp/sometask.md)"
```


- [x] [Docker](https://www.docker.com/) base container for opencode work
- [x] Convenience launcher script
- [x] Security: prevent potential destructive actions by the agent
- [x] [ohmyzsh](https://github.com/ohmyzsh/ohmyzsh/wiki/Customization) plugin abillity
- [x] Security: configure project isolated cache storage via environment variables
- [ ] Security: Add project specific OPENCODE_DATA_DIR
- [x] [Add github build - docker step by step guide](https://docs.docker.com/guides/gha/)
- [ ] Build containers full(rust, go, c, node, python) - duck(node, python) - empty.
- [ ] In the docker compose, use build . and add a docker that uses FROM image-full
- [ ] Fix: Allow multiple port bindings to enable multiple running agents on mulitple projects
- [ ] Security: worktree helpers to isolate node_modules
- [ ] Image extensions - use environment variable to extend from the base - or [development containers spec](https://containers.dev/implementors/spec/)
- [ ] Project creation with scaffold extra context

## Install

Clone the repository to `~/opencode`:

```sh
git clone https://github.com/snowdon-dev/opencode-docker.git ~/opencode
```

`scripts/launcher.sh` looks for the compose files in `~/opencode`, so link the
repository there:

This also means a `.env` placed in the repository root is picked up by both
plain `docker compose` runs and the launcher. See [Environment
variables](#environment-variables).

## Container Usage

You should use the opencode launcher utility to launch the container. As it needs environment variables to (like WORKSPACE) init properly. See oh-my-zsh plugin.

```sh
docker compose up -d opencode
docker compose exec -w /workspace opencode opencode
```

## oh-my-zsh plugin

Instead of running the compose directly, install as a omz plugin for handy commands.

`omz/opencode.zsh` provides shell aliases (`opencode`, `oc`, `oc:s`,
`oc:u`, `oc:e`, `oc:c`, ...) wrapping the launcher. Link it as an oh-my-zsh
custom plugin:

```sh
mkdir -p "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/opencode"
ln -s ~/repos/dotfiles/omz/opencode.zsh \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/opencode/opencode.plugin.zsh"
```

Then enable it in `~/.zshrc` and point `$SD_OPENCODE` at the repository
(the aliases use it to find the repo):

```sh
export SD_OPENCODE="$HOME/opencode"
plugins=(... opencode)
```

After restarting your shell (`exec zsh`). View the avaliable commands by
running `alias | grep oc:` or `alias | grep opencode:`.

## Environment setup steps

- An environment variable for SD_OPENCODE should be set to tell the program
  the location of the repo
- If not otherwise specified the environment default will only use 2 cpus.

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

### Dockerfile

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

### Local builds (Makefile)

Build the image locally with the Makefile:

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
  The image defaults to `anomalyco/opencode`; override it with the
  `DOCKERHUB_IMAGE` repository variable. Main pushes are tagged `latest` +
  `git-<sha>`; version tags get `latest` + the version number.
- **Gitea Actions — `.gitea/workflows/build.yaml`**: pushes to `main` also
  trigger a Kaniko build to `registry.lan:5000/snowdon-dev/opencode`.

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

## License

Copyright © snowdon.dev (hello@snowdon.dev). Licensed under the [GNU General
Public License v3.0](LICENSE) or later.

Any redistributed modified version must be released under GPL-3.0 with its
full source code — if you share changes, send them back upstream so everyone
benefits.
