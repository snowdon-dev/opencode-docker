#!/bin/bash
# Resolve the newest published opencode version for ONE major line (v1, v2, ...).
#
# The source of truth is the upstream container registry, not git tags: every
# image this repo builds does `FROM ghcr.io/anomalyco/opencode:<version>`, so
# a version is only buildable once its image is published. A git tag is pushed
# before the image is (a release tag can exist for hours before its image
# lands in the registry), so resolving from tags alone can pick a version
# whose FROM fails.
#
# Only tags on the requested major line are considered, so asking for v1 can
# never return a 2.x version: each major is its own independent line, and this
# script deliberately does not know or care what the other lines are doing.
#
# Usage:
#   resolve-opencode-version.sh <major> [image]
#   resolve-opencode-version.sh --majors [image]
#
#   <major>   the line to resolve, with or without the leading v (1, v2)
#   --majors  print every major line with published images, lowest first
#   [image]   upstream registry image (default: ghcr.io/anomalyco/opencode)
#
# Writes the resolved version (e.g. "1.18.34") to stdout, without the leading v,
# matching the tag names the opencode images are published under on ghcr.io.
#
# Exit status:
#   0  resolved; the version is on stdout
#   1  the registry publishes no images on this major line (nothing to build)
#   2  usage error
#   3  the registry could not be queried (network, auth, unexpected response)
set -u -o pipefail

readonly DEFAULT_IMAGE="ghcr.io/anomalyco/opencode"

# die <message> [code]: diagnostic on stderr, then exit. Lookup failures
# default to 3; pass 2 for usage errors.
die() {
    printf 'Error: %s\n' "$1" >&2
    exit "${2:-3}"
}

# A pull token for the registry, obtained from the ghcr.io token endpoint.
#
# On a GitHub Actions runner the job's GITHUB_TOKEN is exchanged for the pull
# token when the workflows provide it: anonymous ghcr.io requests share a small
# per-IP rate limit bucket with every other job on the shared runner, and an
# authenticated request avoids it. A public package needs no packages:read
# permission for this, so the workflows need no permission changes. Anywhere
# else the anonymous endpoint is used, which needs no credentials at all.
registry_token() {
    local image="$1"
    local token=""

    if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_ACTOR:-}" ]]; then
        token="$(
            curl -fsS --max-time 30 \
                -u "${GITHUB_ACTOR}:${GITHUB_TOKEN}" \
                "https://ghcr.io/token?scope=repository:${image}:pull&service=ghcr.io" 2>/dev/null |
                sed -E 's/.*"token":"([^"]+)".*/\1/'
        )" || true
    fi

    # Anonymous fallback: the token endpoint needs no credentials for a public
    # package. This is also the only path outside Actions, where neither
    # variable is set, and a fallback when the exchange above is rejected (a
    # stale token exported outside Actions, say).
    if [[ ! "$token" =~ ^[A-Za-z0-9._=-]+$ ]]; then
        token="$(
            curl -fsS --max-time 30 \
                "https://ghcr.io/token?scope=repository:${image}:pull&service=ghcr.io" 2>/dev/null |
                sed -E 's/.*"token":"([^"]+)".*/\1/'
        )" || return 3
    fi

    # A response that is not the expected JSON passes through sed unchanged;
    # anything without the shape of a token is rejected here rather than sent.
    # The class is base64 plus padding: ghcr.io tokens are base64 ("djE6…=").
    [[ "$token" =~ ^[A-Za-z0-9._=-]+$ ]] || return 3

    printf '%s\n' "$token"
}

# Every published opencode version in the registry, one per line, without the
# leading v. Registry tags are already bare ("1.18.34"), unlike the git tags.
# Non-semver tags are dropped here: the registry also carries :latest,
# 0.0.0-dev-* and similar, none of which are buildable opencode versions.
#
# Returns 3 when the registry cannot be queried at all. An empty result with
# exit 0 means the registry publishes no semver tags, which is a different
# outcome and callers must not conflate the two.
published_versions() {
    local image="$1"
    local token response url link page all=""

    token="$(registry_token "$image")" || return 3

    # ghcr.io paginates tags/list (its default page holds ~100 of the ~3000
    # tags published here), so follow the Link header until it is absent.
    local hdr
    hdr="$(mktemp)"
    url="https://ghcr.io/v2/${image}/tags/list?n=1000"
    while :; do
        response="$(
            curl -fsS --max-time 30 \
                -H "Authorization: Bearer $token" \
                -D "$hdr" "$url" 2>/dev/null
        )" || { rm -f "$hdr"; return 3; }

        [[ -n "$response" ]] || { rm -f "$hdr"; return 3; }

        # The only quoted strings in the response are the package name and the
        # tags, so extracting every quoted semver drops both the name and the
        # non-version tags. `|| true` covers a page holding no semver tags.
        page="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' <<<"$response" |
            tr -d '"' || true)"
        all+="$page"$'\n'

        link="$(grep -i '^link:' "$hdr" 2>/dev/null |
            sed -E 's/.*<([^>]+)>; rel="next".*/\1/' || true)"
        [[ -n "$link" ]] || break
        url="https://ghcr.io$link"
    done
    rm -f "$hdr"

    printf '%s\n' "$all"
}

main() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        printf 'Usage: %s <major>|--majors [image]\n' "$(basename "$0")" >&2
        exit 2
    fi

    local image="${2:-$DEFAULT_IMAGE}"

    if [[ "$1" == "--majors" ]]; then
        local all found
        all="$(published_versions "$image")" || exit 3

        found="$(printf '%s\n' "$all" | awk -F. '{print $1}' | sort -nu)"

        [[ -n "$found" ]] || die "no published version tags found in $image" 1

        printf '%s\n' "$found"
        exit 0
    fi

    local major="${1#v}"

    [[ "$major" =~ ^[0-9]+$ ]] || die "not a major version: $1" 2

    local all versions
    all="$(published_versions "$image")" || exit 3

    versions="$(printf '%s\n' "$all" | grep -E "^${major}\." || true)"

    [[ -n "$versions" ]] || die "no published v${major} images in $image" 1

    # Highest by minor then patch. The major is constant across the filtered
    # set, so it is not part of the comparison. sort -V is not available in
    # every environment this runs in (busybox sort has no version-sort), so the
    # components are zero-padded into a fixed-width sort key, and the winning
    # line is re-split back into a version. The un-padding is done by awk on
    # named fields rather than by sed, so a leading zero in a component is
    # stripped from each component independently instead of being glued to the
    # next one.
    local latest
    latest="$(printf '%s\n' "$versions" |
        awk -F. '
            { printf "%04d%04d\t%s\n", $2, $3, $0 }
        ' |
        sort |
        tail -1 |
        awk -F'\t' '{
            split($2, v, ".")
            printf "%d.%d.%d\n", v[1], v[2], v[3]
        }')"

    [[ -n "$latest" ]] || die "could not determine the latest v${major} version in $image" 3

    printf '%s\n' "$latest"
}

main "$@"
