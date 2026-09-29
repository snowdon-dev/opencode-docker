#!/bin/bash
# Decide whether the opencode version in a published image is out of date.
#
# Each major line (v1, v2, ...) is independent: v1 images carry the v1 CLI and
# v2 images carry the v2 CLI, so an upstream release on one line says nothing
# about the other. This script compares the newest version on ONE line against
# the version recorded in that line's own image, and never compares across
# lines. Comparing the latest release of any line against a single image tag
# is what made a v1-only bump invisible to the update workflow.
#
# The newest version comes from the upstream container registry, not git tags:
# the version layers are built `FROM ghcr.io/anomalyco/opencode:<version>`, so
# a version with no published image cannot be built whatever the tags say.
#
# The current version is read from the image label Dockerfile.v<N> sets at
# build time, not from the :latest alias: :latest tracks one specific
# variant/line, so the v1 images must be compared against the v1 image.
#
# Usage:
#   compare-opencode-version.sh <major> <image> [version]
#
#   <major>    the line being checked (1, v2)
#   <image>    the published image whose label holds the current version
#   [version]  the current version, skipping the registry lookup entirely
#
# Exits 0 when the line needs a rebuild (the version to build on stdout), 1
# when it is already current, 2 on a usage or lookup error, and 3 when the
# upstream registry publishes no images on this line yet.
#
# The version to build goes to stdout on its own, so a caller can capture it
# with a command substitution; the human-readable reasoning goes to stderr and
# shows up in the workflow log either way.
set -u

readonly DEFAULT_IMAGE="ghcr.io/anomalyco/opencode"
readonly LABEL="dev.snowdon.image.opencode.version"

# The sibling resolver, located relative to this script so the caller does not
# have to be running from the repository root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOLVER="$SCRIPT_DIR/resolve-opencode-version.sh"

info() {
    printf '%s\n' "$*" >&2
}

die() {
    info "Error: $*"
    exit 2
}

# Reduce a recorded version to bare major.minor.patch, or fail if it is not a
# version. The label is whatever OPENCODE_VERSION the image was built with, so
# it can arrive v-prefixed (from a tag name) or not be a version at all (a local
# build's "latest", or docker's "<no value>" for a missing label). None of those
# may be compared as if they were numbers.
normalize() {
    local version="${1#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$version"
}

# Read the opencode version label from a published image. Prints nothing and
# returns non-zero when the image or the label is unavailable.
image_version() {
    local image="$1"

    # Only the config is needed, so pull the image and read the label rather
    # than fetching the manifest: `docker pull` is already required by the
    # build and keeps this to a single registry interaction.
    docker image pull --quiet "$image" >/dev/null 2>&1 || return 1

    normalize "$(
        docker image inspect --format "{{ index .Config.Labels \"$LABEL\" }}" \
            "$image" 2>/dev/null || true
    )"
}

# Exit 0 when $1 is strictly newer than $2. Components are compared as decimal
# numbers, not as strings, so 1.10.0 sorts above 1.9.0.
is_newer() {
    local a="$1" b="$2"
    awk -v a="$a" -v b="$b" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 > y[i] + 0) { exit 0 }
            if (x[i] + 0 < y[i] + 0) { exit 1 }
        }
        exit 1
    }'
}

main() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        printf 'Usage: %s <major> <image> [version]\n' "$(basename "$0")" >&2
        exit 2
    fi

    local major="${1#v}"
    local image="$2"
    local recorded="${3:-}"
    local upstream="${OPENCODE_IMAGE:-$DEFAULT_IMAGE}"
    local latest current rc

    [[ "$major" =~ ^[0-9]+$ ]] || die "not a major version: $1"
    [[ -n "$image" ]] || die "no image given"

    rc=0
    latest="$("$RESOLVER" "$major" "$upstream")" || rc=$?

    # No published images on the line is not a lookup failure: the line has
    # nothing to build yet, and the caller skips it rather than failing.
    if [[ "$rc" -eq 1 ]]; then
        info "No published v${major} images in ${upstream}: nothing to build."
        exit 3
    fi
    [[ "$rc" -eq 0 ]] || die "could not resolve the latest v${major} version from ${upstream}"

    # A resolved version on the wrong line means the two sources disagree about
    # what this line is; building it would produce a mislabelled image.
    [[ "${latest%%.*}" == "$major" ]] ||
        die "resolved v${major} as $latest, which is not a v${major} version"

    # The version the line already carries: the argument when the caller knows
    # it, otherwise the published image's label. Anything unreadable counts as
    # unrecorded, so a line whose version cannot be read is rebuilt rather than
    # assumed current.
    current=""
    if [[ -n "$recorded" ]]; then
        current="$(normalize "$recorded" || true)"
    else
        current="$(image_version "$image" || true)"
    fi

    if [[ -z "$current" ]]; then
        info "No published version recorded for v${major} in ${image}: building it."
        printf '%s\n' "$latest"
        exit 0
    fi

    if is_newer "$latest" "$current"; then
        info "v${major}: ${current} -> ${latest} (update)"
        printf '%s\n' "$latest"
        exit 0
    fi

    info "v${major}: ${current} is current (latest ${latest})"
    exit 1
}

main "$@"