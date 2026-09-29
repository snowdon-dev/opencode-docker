---
name: Available bash tools (empty)
description: Bash tools available in the `empty` container image, grouped by purpose, with the verified version flag for each
---

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
  (note: `jo` has no `--version` flag; use `jo -v`, or `jo -V` for JSON)

Linting and CI:
- `yamllint --version` — YAML linter
- `actionlint --version` — GitHub Actions workflow linter

GitHub:
- `gh --version` — GitHub CLI
