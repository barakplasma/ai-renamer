#!/bin/sh
# Run inside an Ubuntu 24.04 development machine or container.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bend_home=${1:-${BEND_HOME:-$HOME/.local/share/ai-renamer/bend}}

apt() {
    if [ "$(id -u)" = 0 ]; then
        apt-get "$@"
    else
        sudo apt-get "$@"
    fi
}

apt update
apt install -y --no-install-recommends \
    ca-certificates clang curl ffmpeg git libcurl4-openssl-dev libssl-dev \
    make perl poppler-utils python3

sh "$repo/ci/install-bend.sh" "$bend_home"
