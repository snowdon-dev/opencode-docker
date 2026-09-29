---
name: Available bash tools (full)
description: Bash tools available in the `full` container image, grouped by purpose, with the verified version flag for each
---

The `full` image is the `duck` base (which is itself the `empty` base) plus Go
and, when built with `INSTALL_RUST=true`, the Rust toolchain. All `duck` and
`empty` tools are present here too; see `available-empty-tools.md` for the
full system tool reference.

Core:
- `git --version` — version control
- `bash --version` — shell
- `curl --version` — HTTP transfers
- `make --version` — build automation
- `rg --version` — ripgrep, fast search

Text processing:
- `awk --version` — GNU Awk, text processing
- `diff --version` — GNU diffutils, file comparison

Editor:
- `nvim --version` — Neovim editor (set as `$EDITOR`/`$VISUAL`)

Shell tooling:
- `bats --version` — Bash Automated Testing System, test framework
- `shellcheck --version` — shell script linter

Search:
- `fd --version` — fast, user-friendly alternative to `find`

Structured data:
- `jq --version` — JSON processor
- `yq --version` — YAML/XML processor, `jq` for YAML
- `jo -v` — JSON generator from command-line args

Linting and CI:
- `yamllint --version` — YAML linter
- `actionlint --version` — GitHub Actions workflow linter

GitHub:
- `gh --version` — GitHub CLI

Python:
- `python3 --version`
- `pip3 --version`

Node.js:
- `node --version`
- `npm --version`

Go:
- `go version`
- `gopls version` — language server
- `dlv version` — Delve debugger
- `swag --version` — Swagger/OpenAPI
- `golangci-lint version` — Go linter

Rust (only when the image is built with `INSTALL_RUST=true`):
- `rustup --version`
- `rustc --version`
- `cargo --version`
- `sccache --version`
- `clang --version`, `cmake --version` — C/C++ build toolchain, installed
