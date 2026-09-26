ARG OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:full
FROM ${OPENCODE_IMAGE_URL}
ARG PROJECT_WORKSPACE
LABEL dev.snowdon.opencode.workspace="${PROJECT_WORKSPACE}"

USER root
# apk add --no-cache jq
# apk add --no-cache \
#   wget yq neovim iproute2 bind-tools netcat-openbsd 
RUN apk add shellcheck shfmt editorconfig-checker && \
    ln -s /usr/bin/ec /usr/local/bin/editorconfig-checker
USER other
