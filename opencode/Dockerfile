ARG OPENCODE_VERSION=latest
FROM ghcr.io/anomalyco/opencode:${OPENCODE_VERSION} AS opencode
FROM alpine:3.24
ARG OPENCODE_VERSION=latest
ARG DEVCONTAINER_VERSION
LABEL dev.snowdon.image.opencode.version="${OPENCODE_VERSION}"
LABEL dev.snowdon.image.opencode.devcontainer="${DEVCONTAINER_VERSION}"

## TODO: handle any files left in /root from the opencode base

# Build argument — disabled by default
ARG INSTALL_RUST=false

ENV TERM=xterm-256color
ENV COLORTERM=truecolor
ARG USERNAME=other
ARG USER_UID=1000
ARG USER_GID=1000

# ------------------------------------------------------------
# User setup
# ------------------------------------------------------------
# Define build arguments for your host user

# Create the group and user inside the container
RUN addgroup -g $USER_GID $USERNAME \
    && adduser -D -u $USER_UID -G $USERNAME $USERNAME \
    && mkdir -p \
        /home/$USERNAME/go/bin \
        /home/$USERNAME/go/pkg/mod \
        /home/$USERNAME/.cache/go-build \
        /home/$USERNAME/.local/state \
        /home/$USERNAME/.local/share \
        /home/$USERNAME/.config \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME

# ------------------------------------------------------------
# Packages setup
# ------------------------------------------------------------
RUN apk add --no-cache \
    python3=3.14.7-r1 \
    py3-pip=26.1.2-r0 \
    go=1.26.3-r0 \
    nodejs=24.18.1-r0 \
    npm=11.12.1-r0 \
    git=2.54.0-r0 \
    curl=8.22.0-r0 \
    make=4.4.1-r4 \
    libpcap-dev=1.10.6-r1 \
    bash=5.3.9-r1 \
    ripgrep=15.1.0-r0 \
    libgcc=15.2.0-r5 \
    libstdc++=15.2.0-r5

# Smoke tests for system packages
RUN python3 --version \
    && go version \
    && node --version \
    && npm --version \
    && git --version \
    && curl --version \
    && make --version \
    && rg --version \
    && bash --version

RUN if [ "$INSTALL_RUST" = "true" ]; then \
        apk add --no-cache \
            build-base=0.5-r4 \
            pkgconf=2.5.1-r0 \
            openssl-dev=3.5.8-r0 \
            openssl-libs-static=3.5.8-r0 \
            clang=22.1.3-r2 \
            lld=22.1.3-r0 \
            mold=2.39.1-r0 \
            cmake=4.2.3-r0 \
            unzip=6.0-r16 \
            wayland-dev=1.25.0-r0 \
            alsa-lib-dev=1.2.15.3-r0 \
            eudev-dev=3.2.14-r6; \
    fi


# ------------------------------------------------------------
# Start user config
# ------------------------------------------------------------
# Switch to the non-root user
USER $USERNAME


# ------------------------------------------------------------
# Go environment
# ------------------------------------------------------------
ENV GOPATH=/home/$USERNAME/go
ENV PATH=$PATH:$GOPATH/bin
ENV GOCACHE=/home/$USERNAME/.cache/go-build
ENV GOMODCACHE=/home/$USERNAME/go/pkg/mod

RUN mkdir -p $GOPATH/src $GOPATH/bin

RUN go install golang.org/x/tools/gopls@v0.21.1 \
    && go install github.com/go-delve/delve/cmd/dlv@v1.27.1 \
    && go install github.com/swaggo/swag/cmd/swag@v1.16.4 \
    && curl -sSfL https://golangci-lint.run/install.sh \
        | sh -s -- -b "$GOPATH/bin" v2.11.4 \
    && go clean -cache -modcache

# Smoke tests for Go tools
RUN gopls version \
    && dlv version \
    && swag --version \
    && golangci-lint version

# ------------------------------------------------------------
# Optional Rust environment
# ------------------------------------------------------------

# TODO: install the bins in a from stage, and copy into container

# Rust lives in the user's home directory
ENV PATH="/home/${USERNAME}/.cargo/bin:${PATH}"

# sccache cache directory
ENV SCCACHE_DIR="/home/${USERNAME}/.cache/sccache"

# Install Rust only when requested
# rustup-init is downloaded at a pinned version from the static.rust-lang.org
# archive instead of piping sh.rustup.rs, so the install is reproducible.
ARG TARGETARCH
RUN if [ "$INSTALL_RUST" = "true" ]; then \
        case "${TARGETARCH:-$(uname -m)}" in \
            amd64|x86_64) RUSTUP_TRIPLE="x86_64-unknown-linux-musl" ;; \
            arm64|aarch64) RUSTUP_TRIPLE="aarch64-unknown-linux-musl" ;; \
            *) echo "Unsupported architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
        esac; \
        curl -fsSL \
            "https://static.rust-lang.org/rustup/archive/1.29.0/${RUSTUP_TRIPLE}/rustup-init" \
            -o /tmp/rustup-init \
        && chmod +x /tmp/rustup-init \
        && /tmp/rustup-init \
            -y \
            --default-toolchain 1.98.0 \
            --no-update-default-toolchain \
            --no-modify-path \
        && rm -f /tmp/rustup-init; \
    fi

# Use mold linker for faster builds
ENV RUSTFLAGS="-C link-arg=-fuse-ld=mold"

# Install Rust components and tools only when requested
#
# IMPORTANT:
# Do not set RUSTC_WRAPPER until sccache has been installed.
RUN if [ "$INSTALL_RUST" = "true" ]; then \
        rustup component add rustfmt clippy && \
        env -u RUSTC_WRAPPER cargo install sccache --version 0.17.0 \
        && rm -rf \
            /home/$USERNAME/.cargo/registry/cache \
            /home/$USERNAME/.cargo/registry/src \
            /home/$USERNAME/.cargo/git/checkouts \
            /home/$USERNAME/.cargo/git/db; \
    fi

# Smoke tests for Rust tools (only when installed)
RUN if [ "$INSTALL_RUST" = "true" ]; then \
        rustup --version \
        && rustc --version \
        && cargo --version \
        && sccache --version; \
    fi

# Configure sccache AFTER it has been installed
ENV RUSTC_WRAPPER="/home/${USERNAME}/.cargo/bin/sccache"

# ------------------------------------------------------------
# End
# ------------------------------------------------------------

ENV HOME="/home/${USERNAME}"
ENV XDG_STATE_HOME="/home/${USERNAME}/.local/state"
ENV XDG_DATA_HOME="/home/${USERNAME}/.local/share"
ENV XDG_CACHE_HOME="/home/${USERNAME}/.cache"
ENV XDG_CONFIG_HOME="/home/${USERNAME}/.config"

# Workspace used by opencode
WORKDIR /workspace
ENV HOME=/home/$USERNAME

# opencode
ARG BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
ENV BUN_RUNTIME_TRANSPILER_CACHE_PATH=${BUN_RUNTIME_TRANSPILER_CACHE_PATH}

RUN mkdir -p /home/${USERNAME}/.config/opencode
COPY --chown=${USERNAME}:${USERNAME} opencode/agent.md /home/${USERNAME}/.config/opencode/AGENTS.md

USER root
COPY --from=opencode /usr/local/bin/opencode /usr/local/bin/opencode
RUN chmod +x /usr/local/bin/opencode
USER $USERNAME
RUN opencode --version

ENTRYPOINT ["opencode"]

