# User-defined Dockerfile extending the
# github.com/snowdon-dev/opencode-docker base image.
#
# This file is intended for local/user-specific customizations.
# To keep it ignored by Git, modify your local index:
#   git update-index --assume-unchanged Dockerfile
# If you want to start tracking the file again:
#   git update-index --no-assume-unchanged Dockerfile
#
# You can also build and use your own custom image, but be sure to extend from
# the base container or also implement the required labels.:
#   cd ~/my-custom-build
#   docker build -t my-custom-build:latest .
#   OPENCODE_IMAGE_URL="my-custom-build:latest" opencode

ARG OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:latest
FROM ${OPENCODE_IMAGE_URL}
ARG PROJECT_WORKSPACE
LABEL dev.snowdon.opencode.workspace="${PROJECT_WORKSPACE}"

#USER root
# apk add --no-cache jq
# apk add --no-cache \
#   wget yq neovim iproute2 bind-tools netcat-openbsd 
#RUN apk add shellcheck shfmt
#USER other
