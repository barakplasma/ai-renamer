#!/bin/sh
set -eu
version=2.0.40
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  target=linux-x64;    checksum=c9ff8d67bd903fb6ad9a26b43d8a62c01021de82a44d55ce4a3dcd4732113d6b ;;
  Linux/aarch64) target=linux-arm64;  checksum=2f42a6fa34ecdaa71ae105e5fa734f9a07e129d333e45448ab6d2ff03a837570 ;;
  Darwin/x86_64) target=darwin-x64;   checksum=9229c8bdd0a93f63fa45cc5af5e9e56389ebb620d655920915daf966c6ca561c ;;
  Darwin/arm64)  target=darwin-arm64; checksum=b2be003b041eb6cfc65326be18f79eb2e0bae2189be79a18c507e661b4b6900b ;;
  *) echo "Unsupported Bend platform" >&2; exit 1 ;;
esac

output=$1
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fsSL --retry 4 "https://github.com/bendlang/bend/releases/download/v$version/bend-$version-$target.tar.gz" -o "$archive"
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c
mkdir -p "$output"
tar -xzf "$archive" -C "$output" --strip-components=1
BEND_HOME="$output" "$output/bin/bend" version
