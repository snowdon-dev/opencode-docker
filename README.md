# opencode dev container

[![CI](https://github.com/snowdon-dev/opencode-docker/actions/workflows/ci.yaml/badge.svg)](https://github.com/snowdon-dev/opencode-docker/actions/workflows/ci.yaml)
[![Docker Pulls](https://img.shields.io/docker/pulls/devsnowdon/opencode-docker)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![Docker Image Version](https://img.shields.io/docker/v/devsnowdon/opencode-docker?sort=semver)](https://hub.docker.com/r/devsnowdon/opencode-docker)
[![License](https://img.shields.io/github/license/snowdon-dev/opencode-docker)](https://github.com/snowdon-dev/opencode-docker/blob/main/LICENSE)

| Version | Empty | Duck | Full |
|---|---|---|---|
| v2 | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/empty-v2) | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/duck-v2) | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/full-v2) |
| v1 | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/empty-v1) | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/duck-v1) | ![size](https://img.shields.io/docker/image-size/devsnowdon/opencode-docker/full-v1) |

OpenCode doesn’t impose an opinion on the sandbox its agents run in. A
sandboxed launcher gives you a secure, controlled environment that still lets
agents work with the permissions they need.

Snowdon Dev's `opencode-docker` is a security- and human-control-oriented
[OpenCode](https://opencode.ai) workflow that runs inside Docker containers.
It lets you manage multiple agents, including sub-agents, across distinct
worktrees of your repository library, all through a simple CLI. Your project
is available in the container at `/workspace/project`, and toolchain caches
(Go, Rust, Node.js, Python) persist between runs.

Every feature is security-first, and convenience features are opt-in. Built
for arm devices like the [Raspberry Pi](https://www.raspberrypi.com/) but
compatible with x86 and others — please report any issues you find. The
opencode version is updated weekly, best-effort; file an issue if yours is out
of date. See [Build](#build).

## Commands

<details>
<summary>View command list</summary>
Run commands through the launcher; the workspace defaults to the current
directory. Every command has its own help: `opencode:help <command>` or
`opencode:<command> -h`.

Every command is quiet by default: errors, warnings, results and prompts
still print, but the launcher's status lines (which container or workspace it
picked, what it is waiting for) do not. Pass the global flag `--verbose`
(before or after the subcommand) to see them; `opencode:help` documents the
behaviour.

| Command | Alias | Purpose |
|---------|-------|---------|
| **Start & one-off runs** | | |
| `opencode` (`start`) | `oc` | (Re)create the container and attach a TUI |
| `opencode:scaffold [--target <path>] <task>` | `ocsf` | Create a new project with opencode (task via stdin) |
| `opencode:bg [--target <path>] <task>` | `ocbg` | Run a one-off opencode task (an opencode run in the service) on an existing project |
| `opencode:changes [--output <path>]... [task]` | `occh` | Analyse the branch changes and propose a plan, optionally into a writable output (`--output`, workspace read-only), then run it with `opencode:bg` |
| `opencode:io --output <path>... [task]` | `ocio` | Run a task against a read-only workspace with N writable outputs (`--output` file or directory, repeatable; `--allow-empty`) |
| `opencode:repl` | `ocrepl` | Interactive bash shell bound to the workspace |
|<hr>|<hr>|<hr>|
| **Ensure running** | | |
| `opencode:new` | `ocn` | Stop existing containers, then start a fresh session |
| `opencode:up` | `ocu` | Start the container in the background, running nothing |
| `opencode:setup <cmd>` | `ocset` | Start the container if needed, then run a command in it |
| `opencode:uptree` | `ocut` | Start a container for an existing agent worktree (`--branch <branch>` picks the worktree of a branch) |
|<hr>|<hr>|<hr>|
| **In the running container** | | |
| `opencode:run <cmd>` | `ocr` | Run a task (docker task, docker run) in the service, one-off container if not running |
| `opencode:exec <cmd>` | `oce` | Run a command interactively in the running container |
| `opencode:shell` | `ocsh` | `exec sh` |
| `opencode:compose <args>` | `occ` | Pass arguments straight through to `docker compose` |
|<hr>|<hr>|<hr>|
| **Stop & inspect** | | |
| `opencode:stop` | `ocs` | Stop managed containers |
| `opencode:down` | `ocd` | Remove this project's containers, networks and volumes |
| `opencode:delete` | `ocdel` | Force-remove managed containers (`--all` also drops images and networks) |
| `opencode:ls` (`list`) | `ocl` | List managed containers in a ps-style table |
|<hr>|<hr>|<hr>|
| **Host-side & meta** | | |
| `opencode:git <args>` | `ocg` | Run git on the host, in the workspace |
| `opencode:env [ws\|workspace]` | `ocenv` | Print launcher variables, or the effective workspace path |
| `opencode:create <action>` | `occre` | Create a workspace asset on the host (`--dockerfile`, `--worktree`) |
| `opencode:update` | `ocud` | Refresh the launcher repo and its images |
| `opencode:help [command]` | `och` | Show help, or help for one command |

</details>

<details>
<summary>View command directory cli options</summary>

### Common directory options

Accepted by `stop`, `delete`, `ls` and `down` (each honours the subset that
applies to it):

| Option | Effect |
|--------|--------|
| `--all`, `-a` | Also act on one-off (`compose run`) containers and resources (images, networks) |
| `--other`, `-o` | Act on everything except the current workspace and its worktrees |
| `--this`, `-t` | Act on the current workspace (the default when no path is given) |
| `--quiet`, `-q` | `ls` only: print just the container ids, one per line |
| `--dry-run`, `-n` | Print what would be done without touching anything (`down`, `stop`, `delete`) |
| `--` | Stop parsing options; everything after is a positional argument |

An optional positional argument is a workspace path, or a container-id prefix
(ambiguous prefixes are rejected). `--other` and `--this` are mutually exclusive,
and `down` refuses both: it only ever removes the current project.

Images and networks are labelled with the workspace that created them, which for
a worktree is the worktree's own path, plus the worktree's parent repository.
`delete --all` scoped to a repository therefore covers the repository's worktrees
as well, and `--other` preserves them with the repository.

</details>

<details>
<summary>View create options</summary>

### Create options

`opencode:create` (`occre`) creates a workspace asset on the host. Every action
is requested by its own option — there is no default action, so a bare
`opencode:create` lists them — and several can be combined in one invocation,
running in the order given:

| Option | Effect |
|--------|--------|
| `--dockerfile`, `--Dockerfile`, `-df` | Copy `Dockerfile.example` to `<workspace>/ocdocker/` and print the exports that build the workspace image from it |
| `--worktree`, `--wt`, `-w` | Create an agent worktree `opencode:uptree` starts, at `$SD_AGENT_TREE_ROOT/<project>-dev` (or `$SD_AGENT_TREE_ROOT/<project>-<branch>` when a branch is given) |
| `[branch]` (positional) | The branch to create for `--worktree` (default: `<project>-dev`, created from the current HEAD); it also names the worktree, so several agent worktrees of one project coexist (`dev` is reserved for the canonical one) |

</details>

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
opencode:bg --target ./ "refactor this module"

# plan with the workspace read-only (only --output is writable), then run the
# plan with bg; changes --output plans the branch changes the same way
opencode:changes --output /tmp/plan.md
opencode:io --output /tmp/out.md < /tmp/create-task-plan.md
opencode:bg --target ./ < /tmp/out.md

# new projects, either with a real path or under $SD_REPO_HOME
opencode:scaffold --target /tmp/project < /tmp/sometask.md
opencode:scaffold --path gists/project-1 "Create basic hello world html project"

# workspace assets, and an agent worktree to run in
opencode:create --dockerfile
opencode:create --worktree feature/my-branch
opencode:create --dockerfile --worktree && opencode:uptree

# run on another base image, or pin and cap the CPUs
OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:full-v1" opencode
OPENCODE_CPUSET="2-3" OPENCODE_CPUS="2" opencode

# using opencode v2
OPENCODE_IMAGE_URL="devsnowdon/opencode-docker:empty-v2" \
OPENCODE_IMAGE_URL_TUI="devsnowdon/opencode-docker:empty-v2" opencode
```

## Install

Clone the repository to `~/opencode` (the launcher looks for its files there,
and a `.env` in the repository root is read by plain `docker compose` runs):

```shell
git clone https://github.com/snowdon-dev/opencode-docker.git ~/opencode
```

Only `SD_OPENCODE` is required; the rest is optional: [Compose
variables](#compose-variables) move toolchain cache paths, [Launcher
variables](#launcher-variables) configure the launcher itself.

### oh-my-zsh plugin

<details>
<summary>View install via oh-my-zsh details</summary>
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
(`oc`, `ocs`, `ocu`, `ocn`, `ocsh`, `ocset`, `ocr`, `ocd`, `ocdel`, `ocl`,
`occ`, `occh`, `ocsf`, `ocbg`, `ocio`, `ocg`, `ocenv`, `ocut`, `och`, `ocud`,
`ocrepl`, `occre`)
— see [`omz/opencode.zsh`](omz/opencode.zsh) for the exact list.
</details>

### Environment setup steps

- `SD_OPENCODE` must point at the repository (default `$HOME/opencode`).
- Docker is required ([docker.io](https://www.docker.com/)); rootless Docker
    works for extra security.
- A modern version of bash is required.
- The `opencode` binary on your shell path runs the TUI (`npm i -g
    opencode-ai`); without it an in-container TUI is used instead.
- CPUs are unrestricted by default; limit them with `OPENCODE_CPUSET`
    (pinning) or `OPENCODE_CPUS` (count).
- To apply a custom Dockerfile to every workspace without setting
    `OPENCODE_DOCKERFILE`, copy `Dockerfile.example` to
    `$SD_OPENCODE/Dockerfile`.
- It is recommended to use the [API key file method](#api-key-secret) and
  configure a provider in the project configuration template to read the key
  from the file. See [Config, data and cache
  directories](#config-data-and-cache-directories) below.

### config, data and cache directories

opencode's config, data and cache live on the host under three roots —
`OPENCODE_CONFIG_ROOT` (`~/.config/opencode-docker`), `OPENCODE_DATA_ROOT`
(`~/.local/share/opencode-docker`) and `OPENCODE_CACHE_ROOT`
(`~/.cache/opencode-docker`) — with a per-project directory created under each
one automatically at launch. Each root must exist, be a directory and be
writable; the launcher offers to create what is missing (`SD_YOLO=true` does
it without asking). If your user is not uid/gid `1000`, `chown -R 1000:1000`
the roots instead.

The first launch of a project copies `$OPENCODE_CONFIG_ROOT/template` into the
project's config; later launches leave it alone, so your changes survive.
Delete the project's config directory to re-seed it from the template.

A simple root template for opencode v2 could could be 
(~/.config/opencode-docker/template/opencode.jsonc):
```
{
  "$schema": "https://opencode.ai/config.json",

  // Default model for all sessions.
  //"model": "opencode/big-pickle",
  //"model": "opencode-go/gpt-5.6-luna",
  //"model": "opencode-go/gpt-6-luna",
  "model": "opencode-go/mimo-v2.6-flash",
  "providers": {
    "opencode-go": {
      "settings": {
        "apiKey": "{file:/var/run/secrets/api_key}"
       }
     }
   },
  "variant": "low"
}
```

Set `OPENCODE_CONFIG_DIR`, `OPENCODE_DATA_DIR` or `OPENCODE_CACHE_DIR` to use
one exact directory instead of a root. They are launcher variables: export
them in the shell, not in a `.env` file.

Toolchain caches (`OPENCODE_PIP_CACHE_DIR`, `OPENCODE_NPM_CACHE_DIR`,
`OPENCODE_GO_BUILD_CACHE_DIR`, `OPENCODE_GO_MOD_CACHE_DIR`,
`OPENCODE_CARGO_REGISTRY_DIR`, `OPENCODE_CARGO_GIT_DIR`,
`OPENCODE_SCCACHE_DIR`) are only mounted when enabled with `OPENCODE_CACHE`;
see [Compose variables](#compose-variables). Create and chown them only if you
enable them.

The container also writes to your workspace, so if something fails on
permissions make sure it is owned by the container user:

```sh
chown -R 1000:1000 "$WORKSPACE"
```

## Environment variables

### Compose variables

Toolchain cache and workspace host paths are configured with environment
variables; every one has a default under your home directory.

<details>
<summary>View the compose variables</summary>

| Variable                   | Default                          | Mounted at (container)              |
|----------------------------|----------------------------------|-------------------------------------|
| `WORKSPACE`                | `$SD_OPENCODE` (repo root)       | `/workspace`                        |
| `OPENCODE_NETWORK`         | –                                | – (external network, see `compose/net/docker-compose.network.yml`) |
| `OPENCODE_PIP_CACHE_DIR`   | `$HOME/.cache/pip`               | `/home/other/.cache/pip`            |
| `OPENCODE_NPM_CACHE_DIR`   | `$HOME/.npm`                     | `/home/other/.npm`                  |
| `OPENCODE_GO_BUILD_CACHE_DIR` | `$HOME/.cache/go-build`       | `/home/other/.cache/go-build`       |
| `OPENCODE_GO_MOD_CACHE_DIR`   | `$HOME/go/pkg/mod`            | `/home/other/go/pkg/mod`            |
| `OPENCODE_CARGO_REGISTRY_DIR` | `$HOME/.cargo/registry`       | `/home/other/.cargo/registry`       |
| `OPENCODE_CARGO_GIT_DIR`      | `$HOME/.cargo/git`            | `/home/other/.cargo/git`            |
| `OPENCODE_SCCACHE_DIR`        | `$HOME/.cache/sccache`        | `/home/other/.cache/sccache`        |

The container-side paths are fixed: they must match the user baked into the
image (`other`, uid/gid 1000, see the `opencode/Dockerfile.*` variants).

</details>

### Launcher variables

These variables are read by the launcher from the shell environment:

<details>
<summary>View the launcher variables</summary>

| Variable                   | Default                    | Effect                                              |
|----------------------------|----------------------------|-----------------------------------------------------|
| `SD_OPENCODE`              | `$HOME/opencode`           | The repository holding the launcher and compose files |
| `SD_REPO_HOME`             | `/home/$USER/repos`        | Root for `scaffold`/`bg` `--path` targets, and the parent of the default agent worktree root |
| `SD_AGENT_TREE_ROOT`       | `$SD_REPO_HOME/agent-trees` | Root holding the agent worktrees `uptree` starts and `create --worktree` creates; it must exist |
| `SD_DRIVER`                | `auto`                     | Container engine: `auto`, `docker` or `podman`. Only `docker` is implemented; `podman` exits with an error |
| `OPENCODE_IMAGE_URL`       | `devsnowdon/opencode-docker:duck-v1` | – (build arg: base image for the `opencode` service) |
| `OPENCODE_IMAGE_URL_TUI`   | `devsnowdon/opencode-docker:empty-v1` | – (image for the `tui` service) |
| `OPENCODE_IMAGE_VERSION`   | `v1`                       | Version layer (`v1`, `v2`) of the published images the launcher pulls; the tag defaults above are built from it |
| `OPENCODE_CONTEXT`         | `.`                        | Docker build context directory passed to the compose `build` section. Derived from `OPENCODE_DOCKERFILE`'s directory when that is a file path and this is unset |
| `OPENCODE_DOCKERFILE`      | `Dockerfile`               | Dockerfile path (relative to the context) passed to the compose `build` section |
| `OPENCODE_COMPOSE`         | –                          | Space-separated extra `docker compose` files, merged into the project via `-f` |
| `OPENCODE_WORKSPACE`       | –                          | The current opencode workspace context; launches targeting a directory outside it prompt before using its environment |
| `OPENCODE_CACHE`           | –                          | Toolchain cache mounts to enable: `false` (default) none, `all` every cache, or space-separated ids (`go`, `node`, `python`, `rust`); any other id is rejected before the container is composed. Also selects the base image variant (`:empty-v1`, `:duck-v1`, `:full-v1`) unless `OPENCODE_IMAGE_URL` is set |
| `OPENCODE_CONFIG_ROOT`     | `$HOME/.config/opencode-docker` | Root holding the `template/` config seeded once per project into `projects/<project>`, see [Config, data and cache directories](#config-data-and-cache-directories) |
| `OPENCODE_DATA_ROOT`       | `$HOME/.local/share/opencode-docker` | Root of the per-project data directories, created under it at launch |
| `OPENCODE_CACHE_ROOT`      | `$HOME/.cache/opencode-docker` | Root of the per-project cache directories, created under it at launch |
| `OPENCODE_CONFIG_DIR`      | – (derived from the root)  | Exact directory mounted as the container's config; when set, `OPENCODE_CONFIG_ROOT` is not used |
| `OPENCODE_DATA_DIR`        | – (derived from the root)  | Exact directory mounted as the container's data; when set, `OPENCODE_DATA_ROOT` is not used |
| `OPENCODE_CACHE_DIR`       | – (derived from the root)  | Exact directory mounted as the container's cache; when set, `OPENCODE_CACHE_ROOT` is not used |
| `OPENCODE_BACKEND_ORIGIN`  | `http://opencode:4096`, else resolved from `compose port` | Backend URL used for the TUI connection |
| `OPENCODE_SERVER_PASSWORD` | –                          | Password for the backend's basic auth, passed to both the `opencode` and `tui` services. Unset leaves the backend open inside the compose network; the health endpoint the launcher probes stays reachable either way |
| `OPENCODE_CPUSET`          | –                          | CPU pinning (e.g. `2-3`); unset by default (Docker uses all CPUs) |
| `OPENCODE_CPUS`            | –                          | CPU limit (e.g. `2`); unset by default (no quota)    |
| `SD_YOLO`                  | –                          | `true` (case-insensitive) skips the outside-`HOME` workspace check |
| `SD_YOLO_HOME`             | –                          | `true` validates workspaces against `SD_REPO_HOME` instead of `$HOME` |
| `SD_READ_ONLY`             | –                          | `false` (case-insensitive) skips the read-only `.git` mounts |
| `OPENCODE_NET_RANGE`       | `172.20.0.0/16`            | CIDR or bare prefix defining the managed IP range     |
| `OPENCODE_NET_SUBNET`      | `29`                       | Subnet mask for each workspace network               |
| `OPENCODE_KEY_FILE`       | `~/.config/opencode-docker/opencode.key` | Host file the api key is read from before every launch: a non-empty one merges `compose/secret/docker-compose.secret.yml`, which mounts the file into the container at `/run/secrets/api_key` |
| `DOCKER_ARGS`              | –                          | – (extra args passed to all docker commands)         |
| `COMPOSE_ARGS`             | –                          | – (extra args passed to every `docker compose` command) |

</details>

## How a session starts

`opencode` (the `start` command) starts a backend inside the container, waits
for it to become healthy, then attaches a TUI — your host `opencode` binary
when one is on `PATH`, otherwise a one-off in-container `tui` service. The
backend is stopped when the TUI exits.

`run`, `changes` and `setup` use the running container when there is one, a
throwaway container otherwise; `scaffold` and `bg` always use a throwaway one.
`io` (and `changes --output`) always run on their own, with the workspace
mounted read-only (see `opencode:help io`).

## Security model

- Workspace `.git` directories are mounted read-only, so history cannot be
    rewritten and commands cannot be injected; `SD_READ_ONLY=false` opts out.
- `opencode:io` and `opencode:changes --output` mount the whole workspace
    read-only; only the declared `--output` paths are writable.
- A worktree's parent repository `.git` is mounted read-only, keeping git
    usable while the worktree stays isolated.
- Each workspace gets its own Docker network, isolated from other workspaces.
- Toolchain caches and other host mounts are opt-in (`OPENCODE_CACHE`).
- The api key travels as a file, never an environment variable.
- A workspace outside `$HOME` prompts before it is used, unless `SD_YOLO=true`.

### API key secret

Put your api key in `OPENCODE_KEY_FILE` (default
`~/.config/opencode-docker/opencode.key`); a non-empty file is mounted into
the container at `/run/secrets/api_key` and stays out of the container's
environment, `docker inspect` and `docker compose config`. When the file is
missing or empty the backend starts without a key. The container user must
be able to read the file.

opencode reads the key from that path only when your config says so: add the
reference to the provider in the `opencode.json` of your config template
(`$OPENCODE_CONFIG_ROOT/template`, see [config, data and cache
directories](#config-data-and-cache-directories)). On the v2 images it goes
into `providers.<id>.settings.apiKey`:

```json
{
    "providers": {
        "opencode-go": {
            "settings": {
                "apiKey": "{file:/run/secrets/api_key}"
            }
        }
    }
}
```

On the v1 images the same `{file:/run/secrets/api_key}` reference goes into
`provider.<id>.options.apiKey` instead.

### Network isolation

`OPENCODE_NETWORK` picks one of three modes:

1. **Unset (default)** — Docker's default bridge network.
2. **`@default` (recommended)** — a bridge network created for this workspace
    on first use and reused across restarts; clean up with `opencode:delete
    --all`.
3. **Named network** — any existing Docker network, shared between workspaces
    or external services.

```sh
OPENCODE_NETWORK=@default opencode
OPENCODE_NETWORK="my-shared-net" opencode
```

Each workspace network gets its own subnet, carved from `OPENCODE_NET_RANGE`
(default `172.20.0.0/16`) at `OPENCODE_NET_SUBNET` (default `/29`).

### Setting variables

Launcher variables are read from the shell environment, not from a `.env`
file. Compose variables resolve in this order: shell environment, a `.env`
file next to the compose files (`~/opencode/.env`), then the defaults in
`docker-compose.yml`.

`opencode:env` (`ocenv`) prints the exported `SD_*` and `OPENCODE_*`
variables the launcher sees — useful for checking a shell profile before
launching anything. Only exported variables appear:

```sh
opencode:env | grep '^SD_'
opencode:env | grep '^OPENCODE_CACHE'
```

`opencode:env ws` prints the effective workspace path.

#### Env file example

Add a file like the following to `~/opencode/.env` (only the toolchain cache
paths you want to move; every other path variable keeps its default):

```sh
OPENCODE_PIP_CACHE_DIR=/mnt/usb2/storage/opencode/cache/pip
OPENCODE_SCCACHE_DIR=/mnt/usb2/storage/opencode/cache/rust/sccache
```

The launcher-managed roots are launcher variables and belong in the shell
environment instead — a `.env` file never reaches the launcher:

```sh
export OPENCODE_CONFIG_ROOT=/mnt/usb2/storage/opencode/config
export OPENCODE_DATA_ROOT=/mnt/usb2/storage/opencode/data
export OPENCODE_CACHE_ROOT=/mnt/usb2/storage/opencode/cache
```

## Worktrees

A git worktree is a first-class workspace: its `.git` is a file pointing into
the parent repository, which the launcher mounts read-only (see [Security
model](#security-model)) so git stays usable inside the container while the
worktree stays isolated. Add one and work in it from the parent repository:

```sh
cd ~/repos/myproject
git worktree add ../myproject-wt worktree-branch
opencode:up "$(realpath ../myproject-wt)"
opencode:git status   # runs in the worktree
```

From a parent repository whose worktree child exists, commands resolve to that
child. When several worktrees could be meant, the launcher lists them and
stops — run the command from the worktree you mean, or pass its path
explicitly:

```sh
opencode "$PWD/w1"
opencode "$PWD/w2"
```

### Worktree sync

Commands that hand work to the agent (`opencode`, `run`, `scaffold`, `bg`)
sync the worktree with its parent branch first: a clean worktree whose parent
is ahead is fast-forwarded, otherwise the launcher reports the divergence and
stops. Every other command skips the check.

### Agent worktrees (uptree)

`opencode:uptree` starts a container for an agent worktree living under
`SD_AGENT_TREE_ROOT` (default `$SD_REPO_HOME/agent-trees`; create it once
yourself). `opencode:create --worktree` creates them, one per branch, so a
project can hold several agent worktrees side by side:

```sh
mkdir -p "$SD_AGENT_TREE_ROOT"          # once, it is not created for you

cd ~/repos/myproject
opencode:create --worktree              # the canonical <project>-dev worktree
opencode:uptree "$PWD"                  # start its container

# or a branch of your own choosing, then start that worktree
opencode:create --worktree feature/my-branch
opencode:uptree --branch feature/my-branch "$PWD"
```

Each worktree is its own workspace with its own container, named after the
project and branch; `<project>-dev` is the canonical one and the name `dev` is
reserved for it, so a branch sanitising to `dev` (`DEV`, `dev.`) is refused.
Creating is safe to re-run: an existing worktree is reported and left alone —
`git worktree remove` it first if you want it recreated on another branch.
`uptree` never creates the worktree itself; when it is missing it prints the
`git worktree add` line to run.

## Start extending with custom functions

The function is valid in a zsh shell:

```shell
gist() {
    if (( $# == 0 )); then
        echo "No arguments, requires <name> (task)"
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
            echo 'run:   opencode:scaffold --target ./ "Your task"'
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
        env -i ZDOTDIR="$ZDOTDIR" zsh -ic 'opencode:scaffold --target ./ "$@"' zsh "$@"
    }
}
```

Please share your extensions in the discussions section.

## Build

The base image [devsnowdon/opencode-docker](https://hub.docker.com/r/devsnowdon/opencode-docker)
is prebuilt: variants `empty` (minimal CLI toolset), `duck` (adds Node.js and
Python) and `full` (adds Go, C and Rust), each published for v1 and v2. Your
workspace image builds on top of it — extend the base with `/Dockerfile`, or
pick a variant with `OPENCODE_IMAGE_URL`.

Images can also be built locally from the Makefile: `make build` for
everything, or the per-variant and per-architecture targets listed there.

## Testing

The launcher's test suite runs against mocked `docker`, `curl` and `opencode`
binaries, so no Docker daemon is needed:

```sh
make test                  # run the whole suite
bats --filter up tests/    # run one test by name (up, stop, create, ...)
bats -t tests/control.bats # one suite, TAP output on stdout
```

## Contributing

Changes are welcome as pull requests. By submitting, you agree your
contributions are licensed under the same license as the project
(GPL-3.0-or-later). Keep PRs focused; one logical change per request.

## License

Copyright © snowdon.dev (hello@snowdon.dev). Licensed under the [GNU General
Public License v3.0](LICENSE) or later.

Any redistributed modified version must be released under GPL-3.0 with its
full source code — if you share changes, send them back upstream so everyone
can benefit.
