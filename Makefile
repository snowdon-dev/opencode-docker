.PHONY: build build-arch build-amd64 build-arm64 build-multi publish-multi pipeline builder tag-major tag-minor tag-patch test check check-pipeline

REGISTRY ?= registry.lan:5000/snowdon-dev/opencode
ARCH ?= amd64
PLATFORMS ?= linux/amd64,linux/arm64
RUST ?= true
OPENCODE_VERSION ?= latest
DEVCONTAINER_VERSION ?= latest
BUILDER := snowdon-multiarch
SVU ?= svu

BUILD_ARGS = \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg DEVCONTAINER_VERSION=$(DEVCONTAINER_VERSION)

# Build and push the layered base variants in order: each variant's Dockerfile
# uses FROM ${OPENCODE_BASE_URL}:<parent>, so the parent image must already be
# built/tagged where docker resolves it (local image store for native loads, the
# registry for --push). Keep empty -> duck -> full ordering.
build-empty:
	docker build \
		$(BUILD_ARGS) \
		--progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty .

build-duck:
	docker build \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck .

# Native build: empty + duck first, then the full image tagged as :full and :latest.
build: build-empty build-duck
	docker build \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full \
		-t $(REGISTRY):latest .

# Build the full image for a single architecture and load it into the local
# docker daemon. Select the arch with the variable: make build-arch ARCH=arm64
build-arch: build-arch-empty build-arch-duck build-arch-full

build-arch-empty:
	docker buildx build \
		--platform linux/$(ARCH) \
		$(BUILD_ARGS) \
		--progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty \
		--load .

build-arch-duck:
	docker buildx build \
		--platform linux/$(ARCH) \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck \
		--load .

build-arch-full:
	docker buildx build \
		--platform linux/$(ARCH) \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full \
		-t $(REGISTRY):latest \
		--load .

build-amd64:
	$(MAKE) build-arch ARCH=amd64

build-arm64:
	$(MAKE) build-arch ARCH=arm64

# Build and push multi-arch manifest lists for every variant. The duck and full
# steps pull the just-pushed parent manifest, so they must run in order.
# Requires the buildx builder created by `make builder`.
build-multi: build-multi-empty build-multi-duck build-multi-full

build-multi-empty:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLATFORMS) \
		$(BUILD_ARGS) \
		--progress=plain \
		-f opencode/Dockerfile.empty \
		-t $(REGISTRY):empty \
		--push .

build-multi-duck:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLATFORMS) \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--progress=plain \
		-f opencode/Dockerfile.duck \
		-t $(REGISTRY):duck \
		--push .

build-multi-full:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLATFORMS) \
		$(BUILD_ARGS) \
		--build-arg OPENCODE_BASE_URL=$(REGISTRY) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f opencode/Dockerfile.full \
		-t $(REGISTRY):full \
		-t $(REGISTRY):latest \
		--push .

publish-multi: build-multi

pipeline: build
	docker push $(REGISTRY):empty
	docker push $(REGISTRY):duck
	docker push $(REGISTRY):full
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
	shellcheck scripts/launcher.sh && \
		shfmt -i 2 -w scripts/launcher.sh

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