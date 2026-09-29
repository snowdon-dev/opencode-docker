ARG OPENCODE_IMAGE_URL=devsnowdon/opencode-docker:full-v1
FROM ${OPENCODE_IMAGE_URL}
ARG PROJECT_WORKSPACE
ARG PROJECT_WORKSPACE_PARENT=""
LABEL dev.snowdon.opencode.workspace="${PROJECT_WORKSPACE}"
LABEL dev.snowdon.opencode.workspace_parent="${PROJECT_WORKSPACE_PARENT}"

USER root

RUN apk add shfmt editorconfig-checker && \
    ln -s /usr/bin/ec /usr/local/bin/editorconfig-checker

USER other
