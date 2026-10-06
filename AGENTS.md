# AGENTS.md

## What this is

- A bash launcher plus Docker Compose config that runs OpenCode agents in containers. Almost all logic lives in one file: `scripts/launcher.sh` (every command, help text, compose merge order). No compiled code.
- `README.md` is the user-facing manual; the launcher's `help` text and this file are the sources of truth.

## Verify before finishing

- `make ci` — the full gate, run in CI order (`.github/workflows/ci.yaml`): `syntax` -> `check` (shellcheck) -> `fmt-check` -> `test`.
- `make syntax` / `make check` lint **explicit file lists** in the `Makefile`: a new file under `scripts/` or `bin/` is never checked until you add it there (`check` only covers 5 named scripts).
- `make format` rewrites only `scripts/launcher.sh` (`shfmt -i 4 -w`); `fmt-check` enforces `.editorconfig` (4-space indent, tabs only in `Makefile`) repo-wide via `editorconfig-checker` (binary `ec` also works).
- Tooling: shellcheck, shfmt, editorconfig-checker; tests additionally need `setsid` (util-linux/busybox). `make build*` needs Docker and is expensive — bases must build before version layers.

## Tests

- `make test`, or one test by name: `bats --filter <name> tests/`. Tests are
  Bats `@test` cases in `tests/<suite>.bats`, one suite per README command
  group (`launch`, `ensure_running`, `in_container`, `control`, `host`) plus
  `compose_args`, `image` and `guards`. No registration list: a new `@test`
  in the suite of its command runs with the suite.
- Shared setup lives in `tests/lib/helpers.bash` (sandbox, `run_launcher`,
  `assert_docker`, ...): `load 'lib/helpers'` at the top of a suite provides
  `setup`/`teardown` (fresh `/tmp` sandbox per test). `make_sandbox` pins
  every path the launcher defaults to `$HOME` (compose dir, workspace, toolchain
  caches, api key file, the three storage roots) inside that sandbox, so a
  suite run never reads, seeds or creates the defaults a running container's
  bind mounts are built from.
- No Docker daemon needed: `tests/mockbin/` stands in for `docker`, `curl`
  and `opencode`, and the mock `docker` records the exact command lines.
- `assert_docker` compares the **exact** command line, including the `-f`
  override merge order built in `make_sandbox`. Changing compose override
  merging, labels, or launcher flags almost always means updating those
  expectations (temp paths are normalised by the helpers:
  `<tmp>/docker-compose.git.yml`, `oc-*-<pid>`).
- The launcher always runs under `setsid` with `SD_YOLO=true` so `/dev/tty`
  prompts take their default-abort path.

## Architecture notes

- Adding a user-facing command touches four places: subcommand + `help` output in `scripts/launcher.sh`, alias in `omz/opencode.zsh`, the command table in `README.md`, and a test.
- Compose config = root `docker-compose.yml` + overrides merged by the launcher from `compose/{env,vol,sys,image,net,secret}/`. The merge order is part of the tested contract; the api key is a compose *secret* (`compose/secret/`), never an env var.
- Images are layered: toolchain bases `opencode/Dockerfile.{empty,duck,full}` (each `FROM` the previous) then version layers `opencode/Dockerfile.{v1,v2}`. `VARIANTS`, `VERSIONS`, `LATEST` in the `Makefile` generate every build target, so a new version = a `Dockerfile.vN` plus a `VERSIONS` entry. Default `REGISTRY` is `registry.lan:5000/...`, not Docker Hub.
- v1/v2 pick different TUI scripts (`scripts/v{1,2}/start-tui.sh`) and endpoints via `OPENCODE_IMAGE_VERSION`; both branches are pinned by the `start_v1` / `start_v2` tests (`tests/launch.bats`).
- The workspace `.git` is mounted read-only inside the container by default (`SD_READ_ONLY`), so git writes fail there; only read-only git commands are safe.

## Internals (intentionally not in the README)

The README is written for a CLI user: what to run, not how it is done.
Reference tables and long explanations live in its `<details>` blocks (hidden,
so they do not count as clutter) or here.

### Session startup

- `opencode` (`start`) runs `opencode serve` in the container, waits via
  `scripts/waitforserver.sh` polling the health endpoint (`/api/health` on v1,
  `/global/health` on v2) from whichever side can reach it (host when a host
  `opencode` binary drives the TUI, inside the container where only the
  service name resolves otherwise), then starts a TUI (`scripts/v{1,2}/start-tui.sh`).
  The backend is killed when the TUI exits.
- The backend is published on a host port only when the host binary runs the
  TUI; otherwise it is reachable only on the compose network, so one project's
  backend cannot be reached from another project's host processes.
- Container use per command: `run`, `changes`, `setup` use the running
  container, else a throwaway `compose run` container; `scaffold` and `bg`
  always use a throwaway one; `io` and `changes --output` always run on their
  own with the workspace mounted read-only.

### Config, data and cache

- The container runs as `other` uid/gid `1000`; bind mounts under
  `/home/other/...` must exist and be writable by it: config
  `/home/other/.config/opencode`, data `/home/other/.local/share/opencode`,
  cache `/home/other/.cache/opencode/cache`. The project name (per-project
  subdirectory, compose project) is the workspace directory name.
- Roots are validated at every launch (exist, be a directory, writable;
  missing ones are offered — created silently by `SD_YOLO=true`, listed and
  aborted in a non-interactive run otherwise).
- `$OPENCODE_CONFIG_ROOT/template` is copied into `projects/<project>` once
  (first launch only); later launches neither wipe nor re-copy it. Delete the
  project directory to re-seed.
- The image component's skill (`opencode/skills/available-<variant>-tools/SKILL.md`)
  is copied into the project config's `skills/` on every launch, replacing a
  stale skill of another component: the config dir is the one place every
  service and the host TUI read, and opencode only discovers
  `skills/<name>/SKILL.md` directories.
- `OPENCODE_{CONFIG,DATA,CACHE}_DIR` bypass the root entirely (no per-project
  subdir, no template). They are launcher variables: in a `.env` file compose
  would mount a directory the launcher never checked or created.
- Variable resolution: compose path variables from shell env → `.env` next to
  the compose files → inline defaults in `docker-compose.yml`; launcher
  variables only from the shell environment.

### API key

- `OPENCODE_KEY_FILE` (default `~/.config/opencode-docker/opencode.key`) is
  read on every launch; non-empty merges `compose/secret/docker-compose.secret.yml`,
  which mounts the file itself at `/run/secrets/api_key`.
  Nothing exports the key: opencode reads the mounted file through the
  `{file:/run/secrets/api_key}` reference in the project's `opencode.json`
  (README, "API key secret"), and `scripts/start-serve-backend.sh` runs
  `opencode serve` with the environment untouched (pinned by the
  `secret_backend_api_key` test). Only the path reaches
  compose/docker, so the value stays out of `docker inspect` and
  `docker compose config`.
- Missing/unreadable/empty file → nothing merged, no variable exported, the
  backend starts without a key. The container user must be able to read the
  file. The compose fallback `./secrets/api_key` (gitignored) is for
  launcher-less use.

### Network

- `OPENCODE_NETWORK` modes: unset = default bridge; `@default` =
  workspace-scoped `sd-<project>-default` bridge, labelled with the workspace
  and reused across restarts (name follows the project, not the path; a stale
  network is diagnosed with the `docker network rm` fix; cleanup via
  `delete --all`); any other value = attach both services to that existing
  network.
- Subnets are carved from `OPENCODE_NET_RANGE` (default `172.20.0.0/16`) by
  `OPENCODE_NET_SUBNET` (default `/29`); a subnet mask >= the range mask is
  rejected, a `/16` at `/29` gives 8192 slices, exhaustion errors out.

### Worktrees

- A worktree's `.git` is a file pointing into the parent repository; the
  launcher records the parent and mounts its `.git` read-only.
- Resolution: an explicit path always wins; a parent with one worktree child
  resolves to that child; with multiple running children the canonical
  `SD_AGENT_TREE_ROOT` worktree is preferred, otherwise candidates are listed
  and the launcher stops; an explicit parent path is never redirected to a
  child.
- Sync (before handing work to the agent: `opencode`, `run`, `scaffold`,
  `bg`): parent ahead + clean worktree → fast-forward; otherwise report
  divergence and exit.
- `create --worktree` runs `git worktree add -B <branch>` from the current
  HEAD and prints the `uptree` line to run next; re-running reports an
  existing worktree of the repository untouched. `dev` is reserved for the
  canonical `<project>-dev`, so branches sanitising to it are refused; a
  worktree's compose project is globally unique by basename (why a worktree
  is never named after the parent repository).

### Build

- Variant contents: `empty` = git, curl, make, bash, ripgrep, neovim, user
  `other`; `duck` = `empty` + node, npm, python, pip; `full` = `duck` + go,
  gopls, dlv, swag, golangci-lint, C toolchain, Rust (opt-in via
  `INSTALL_RUST`, skipped by `make build RUST=false`). Published as
  `devsnowdon/opencode-docker` on Docker Hub, `<variant>-<v1|v2>`, with
  `full-v2` also tagged `:latest`.
- Makefile: bases must build before the version layers (each version layer
  `FROM`s its base, so a single-image target builds its own base first). `make
  build` = 3 bases + 6 images native with `:latest`; `build-arch ARCH=...`,
  `build-multi`, `pipeline`, `builder` (buildx container driver, required for
  multi-arch push; `-base` tags are pushed too), plus `build-bases`,
  `build-base-<variant>`, `build-versions`, `build-<variant>-<version>`,
  `build-arch-versions`, `build-multi-versions`. `VARIANTS`, `VERSIONS`,
  `LATEST` generate every target; `REGISTRY` defaults to
  `registry.lan:5000/...`.

## README

- Update `README.md` in the same change as any user-visible behaviour (commands, aliases, env vars, Makefile targets, compose files) — nothing else keeps it in sync.
- Keep it concise: the README carries only what a user of the program needs to run it — what to run, which file to edit, which variable to set — never technical details. Link to `opencode:help <command>`, the `Makefile`, or a script instead of restating them.
- Implementation detail ("how it gets done") belongs in `opencode:help`, a `<details>` block (hidden, so free of clutter), or the Internals section above — not in the visible prose. Version-specific config schemas, internal paths and mount mechanics live here, not there.
