.PHONY: build build-arch build-amd64 build-arm64 build-multi publish-multi pipeline builder tag-major tag-minor tag-patch test check check-pipeline syntax fmt-check format ci

REGISTRY ?= registry.lan:5000/snowdon-dev/opencode
ARCH ?= amd64
PLATFORMS ?= linux/amd64,linux/arm64
RUST ?= true
OPENCODE_VERSION ?= latest
DEVCONTAINER_VERSION ?= latest
BUILDER := snowdon-multiarch
SVU ?= svu

# Three toolchain bases (empty <- duck <- full), each shared by every opencode
# version layer and tagged <variant>-base. A base carries no opencode CLI, so it
# is not runnable on its own.
VARIANTS := empty duck full
# One thin layer per opencode version (Dockerfile.<version>), each built on top
# of all three bases, giving the published <variant>-<version> images.
VERSIONS := v1 v2
# The published image that also gets the :latest alias.
LATEST := $(lastword $(VARIANTS))-$(lastword $(VERSIONS))

BASE_BUILD_ARGS = \
	--build-arg DEVCONTAINER_VERSION=$(DEVCONTAINER_VERSION) \
	--build-arg USERNAME=other \
	--build-arg USER_UID=1000 \
	--build-arg USER_GID=1000
VERSION_BUILD_ARGS = \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
	--build-arg USERNAME=other

.PHONY: run
run:
	SD_OPENCODE="$(pwd)" bash scripts/launcher.sh $(ARGS)

# Engine invocations, one per build family. Only the prefix differs, the version
# loop below is shared. Bases must be tagged (and, for --push, published) before
# the version layers FROM them: the local image store resolves them for
# native/--load builds, the registry for --push.
NATIVE = docker build
SINGLE_ARCH = docker buildx build --platform linux/$(ARCH) --load
MULTI_ARCH = docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --push

# Build the version layer of every base: 6 images from the 3 shared bases, each
# through opencode/Dockerfile.<version> with BASE_TAG selecting the base.
# Identical version layers (v1 == v2 today) hit the build cache, so only the
# first one costs anything.
# $(1) engine prefix, $(2) extra engine flags.
define BUILD_VERSIONS
	@set -e; for base in $(VARIANTS); do \
		for version in $(VERSIONS); do \
			tag="$$base-$$version"; \
			tags="-t $(REGISTRY):$$tag"; \
			if [ "$$tag" = "$(LATEST)" ]; then tags="$$tags -t $(REGISTRY):latest"; fi; \
			$(1) $(2) $(VERSION_BUILD_ARGS) --progress=plain \
				--build-arg BASE_TAG=$$base-base \
				-f opencode/Dockerfile.$$version \
				$$tags .; \
		done; \
	done
endef

# One published image on its own, named build-<variant>-<version>, e.g.
# `make build-empty-v1` or `make build-full-v2`. The variant's base is built
# first, since the version layer FROMs it, so the target is self-sufficient.
# Generated from VARIANTS x VERSIONS, so a new version gets its own target too.
# $(1) variant, $(2) version, $(3) its base target, $(4) extra tags. The args are
# wrapped in $(strip) because the $(call) below spans several lines, and the
# line continuations would otherwise leak whitespace into the arguments.
define BUILD_ONE_VERSION
build-$(1)-$(2): $(strip $(3))
	$(NATIVE) $(VERSION_BUILD_ARGS) --progress=plain \
		--build-arg BASE_TAG=$(1)-base \
		-f opencode/Dockerfile.$(2) \
		-t $(REGISTRY):$(1)-$(2)$(if $(strip $(4)), $(strip $(4))) .
endef

$(foreach variant,$(VARIANTS),\
	$(foreach version,$(VERSIONS),\
		$(eval $(call BUILD_ONE_VERSION,$(variant),$(version),\
			build-base-$(variant),\
			$(if $(filter $(variant)-$(version),$(LATEST)),-t $(REGISTRY):latest,)))))

# ----------------------------------------------------------------------
# Bases
# ----------------------------------------------------------------------
build-base-empty:
	$(NATIVE) $(BASE_BUILD_ARGS) --progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty-base .

build-base-duck:
	$(NATIVE) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck-base .

build-base-full:
	$(NATIVE) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full-base .

build-bases: build-base-empty build-base-duck build-base-full

# ----------------------------------------------------------------------
# Native builds: 3 bases + 6 published images (and the :latest alias)
# ----------------------------------------------------------------------
.PHONY: build-versions
build-versions:
	$(call BUILD_VERSIONS,$(NATIVE),)

build: build-bases build-versions

# ----------------------------------------------------------------------
# Single-arch builds, loaded into the local docker daemon. Select the arch with
# the variable: make build-arch ARCH=arm64
# ----------------------------------------------------------------------
build-arch-base-empty:
	$(SINGLE_ARCH) $(BASE_BUILD_ARGS) --progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty-base .

build-arch-base-duck:
	$(SINGLE_ARCH) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck-base .

build-arch-base-full:
	$(SINGLE_ARCH) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full-base .

.PHONY: build-arch-bases
build-arch-bases: build-arch-base-empty build-arch-base-duck build-arch-base-full

.PHONY: build-arch-versions
build-arch-versions:
	$(call BUILD_VERSIONS,$(SINGLE_ARCH),)

build-arch: build-arch-bases build-arch-versions

build-amd64:
	$(MAKE) build-arch ARCH=amd64

build-arm64:
	$(MAKE) build-arch ARCH=arm64

# ----------------------------------------------------------------------
# Multi-arch builds: 3 base manifests + 6 published manifests, pushed. The duck
# and full bases pull the just-pushed parent manifest, and the version layers
# pull the just-pushed bases, so the order matters.
# Requires the buildx builder created by `make builder`.
# ----------------------------------------------------------------------
build-multi-base-empty:
	$(MULTI_ARCH) $(BASE_BUILD_ARGS) --progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty-base .

build-multi-base-duck:
	$(MULTI_ARCH) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck-base .

build-multi-base-full:
	$(MULTI_ARCH) $(BASE_BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full-base .

.PHONY: build-multi-bases
build-multi-bases: build-multi-base-empty build-multi-base-duck build-multi-base-full

.PHONY: build-multi-versions
build-multi-versions:
	$(call BUILD_VERSIONS,$(MULTI_ARCH),)

build-multi: build-multi-bases build-multi-versions

publish-multi: build-multi

pipeline: build
	@set -e; for variant in $(VARIANTS); do for version in $(VERSIONS); do \
		docker push $(REGISTRY):$$variant-$$version; \
	done; done; \
	docker push $(REGISTRY):latest

# Ensure the docker-container builder used for multi-arch builds exists.
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER) --driver docker-container --bootstrap --use

# Run the launcher unit tests against a mocked docker (no docker required).
test:
	./tests/run_tests.sh

.PHONY: check
check:
	shellcheck scripts/launcher.sh \
		scripts/waitforserver.sh \
		scripts/start-serve-backend.sh \
		scripts/v1/start-tui.sh \
		scripts/v2/start-tui.sh

# In-place formatting for local dev. The read-only `check` target is what CI
# runs; the pipeline never rewrites the tree.
.PHONY: format
format:
	shfmt -i 4 -w scripts/launcher.sh

# Bash syntax-check every shell script (parse errors, not semantics). bin/ holds
# the helpers the update and build workflows run; they are parse-checked here
# rather than unit-tested, since tests/ covers the launcher.
.PHONY: syntax
syntax:
	bash -n scripts/launcher.sh scripts/setup.sh scripts/waitforserver.sh \
		scripts/v1/start-tui.sh scripts/v2/start-tui.sh \
		bin/resolve-opencode-version.sh bin/compare-opencode-version.sh \
		tests/run_tests.sh tests/mockbin/docker tests/mockbin/opencode \
		tests/mockbin/curl

# Formatting test against .editorconfig. The checker binary is installed as
# `editorconfig-checker` by `go install` but as `ec` by the Alpine package, so
# accept either. The config file is passed explicitly because config
# auto-discovery differs by version (`ec` 3.0.x looks for .ecrc, newer
# releases for .editorconfig-checker.json), and the scan path is passed
# explicitly because `ec` 3.0.x silently checks nothing when no path is given.
# See .editorconfig-checker.json for the remaining exclusions.
.PHONY: fmt-check
fmt-check:
	@[ -n "$(EC_BIN)" ] || { echo "Error: editorconfig-checker (or ec) is not installed" >&2; exit 1; }
	$(EC_BIN) -config .editorconfig-checker.json .

# Locate the editorconfig-checker binary under either installed name.
EC_BIN := $(shell command -v editorconfig-checker 2>/dev/null || command -v ec 2>/dev/null)

# Complete local/CI routine: bash syntax, shell checks, formatting, tests.
.PHONY: ci
ci: syntax check fmt-check test

.PHONY: check-pipeline
check-pipeline: check test

# Semantic version tagging. Requires svu (install with:
#   go install github.com/caarlos0/svu@latest
# or check your package manager). Each target bumps the latest v* tag, creates
# a git tag and pushes it; the pushed tag triggers the CI build/push workflow.
tag-major:
	@command -v $(SVU) >/dev/null || (echo "Error: svu is not installed (go install github.com/caarlos0/svu@latest)" >&2 && exit 1)
	git tag "$$($(SVU) major)"
	git push --tags

tag-minor:
	@command -v $(SVU) >/dev/null || (echo "Error: svu is not installed (go install github.com/caarlos0/svu@latest)" >&2 && exit 1)
	git tag "$$($(SVU) minor)"
	git push --tags

tag-patch:
	@command -v $(SVU) >/dev/null || (echo "Error: svu is not installed (go install github.com/caarlos0/svu@latest)" >&2 && exit 1)
	git tag "$$($(SVU) patch)"
	git push --tags
