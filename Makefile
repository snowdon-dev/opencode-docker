.PHONY: build build-arch build-amd64 build-arm64 build-multi publish-multi pipeline builder tag-major tag-minor tag-patch test

REGISTRY ?= registry.lan:5000/snowdon-dev/opencode
DOCKERFILE ?= ./opencode/Dockerfile
ARCH ?= amd64
PLATFORMS ?= linux/amd64,linux/arm64
RUST ?= true
BUILDER := snowdon-multiarch
SVU ?= svu

build:
	docker build \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f $(DOCKERFILE) \
		-t $(REGISTRY) .

# Build for a single architecture and load it into the local docker daemon.
# Select the arch with the variable: make build-arch ARCH=arm64
build-arch:
	docker buildx build \
		--platform linux/$(ARCH) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f $(DOCKERFILE) \
		-t $(REGISTRY):$(ARCH) \
		--load .

build-amd64:
	$(MAKE) build-arch ARCH=amd64

build-arm64:
	$(MAKE) build-arch ARCH=arm64

# Build and push a multi-arch manifest list (both PLATFORMS) in one shot.
# Requires the buildx builder created by `make builder`.
build-multi:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLATFORMS) \
		--build-arg INSTALL_RUST=$(RUST) \
		--progress=plain \
		-f $(DOCKERFILE) \
		-t $(REGISTRY):latest \
		--push .

publish-multi: build-multi

pipeline: build
	docker push $(REGISTRY):latest

# Ensure the docker-container builder used for multi-arch builds exists.
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER) --driver docker-container --bootstrap --use

# Run the launcher unit tests against a mocked docker (no docker required).
test:
	./tests/run_tests.sh

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
