# User-defined Dockerfile extending the
# github.com/snowdon-dev/opencode-docker base image.
#
# This file is intended for local/user-specific customizations.
# To keep it ignored by Git, modify your local index:
#   git update-index --assume-unchanged Dockerfile
#   git update-index --skip-worktree Dockerfile
# If you want to start tracking the file again:
#   git update-index --no-assume-unchanged Dockerfile
#
# For project specific images, point your opencode at your project the laucnher 
# will then build the container from your project workspace.
#   OPENCODE_CONTEXT=~/my-custom-build \
#       OPENCODE_DOCKERFILE=~/my-custom-build/Dockerfile.dev opencode
#
# The base image is layered: devsnowdon/opencode-docker:<variant> with variants
# full (rust, go, c, node, python), duck (node, python), and empty. Point
# OPENCODE_IMAGE_URL at the prebuilt variant you want (e.g. :duck) to build the
# compose image on top of a slimmer base.
#
# You can also build and use your own custom image, but be sure to extend from
# the base container or also implement the required labels.:
#   cd ~/my-custom-build
#   docker build -t my-custom-build:latest .
#   OPENCODE_IMAGE_URL="my-custom-build:latest" opencode

ARG OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:full
FROM ${OPENCODE_IMAGE_URL}
ARG PROJECT_WORKSPACE
LABEL dev.snowdon.opencode.workspace="${PROJECT_WORKSPACE}"

#USER root
# apk add --no-cache jq
# apk add --no-cache \
#   wget yq neovim iproute2 bind-tools netcat-openbsd 
#RUN apk add shellcheck shfmt
USER other
