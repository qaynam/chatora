#!/bin/sh
# The `build` step of the plugin spec.
#
# A release carries the LSP server already built, so installing chatora at a tag is a
# download rather than a toolchain: no bun, no node version to be old enough, nothing to go
# wrong that has not gone wrong before the release was published. Anything else — a branch, a
# local checkout, a tag whose asset is missing — is built from source, which needs bun.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

dist=packages/server/dist
target=$dist/main.js

build_from_source() {
  echo "chatora: building the server from source" >&2
  bun install --frozen-lockfile
  bun run build
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Only an exact tag names a release. A branch checkout is whatever was pushed last, and no
# published asset can be said to match it.
tag=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$tag" ]; then
  build_from_source
  exit 0
fi

# CHATORA_RELEASE_BASE is the seam the tests use; there is no reason to set it otherwise.
base="${CHATORA_RELEASE_BASE:-https://github.com/qaynam/chatora/releases/download}/$tag"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL -o "$tmp/main.js" "$base/main.js" ||
  ! curl -fsSL -o "$tmp/main.js.sha256" "$base/main.js.sha256"; then
  echo "chatora: no published server for $tag" >&2
  build_from_source
  exit 0
fi

# The file is about to be executed by node on every page the reader opens; a truncated
# download or a mirror in the middle should stop here rather than there.
if [ "$(sha256_of "$tmp/main.js")" != "$(cut -d' ' -f1 <"$tmp/main.js.sha256")" ]; then
  echo "chatora: checksum mismatch for $tag" >&2
  build_from_source
  exit 0
fi

mkdir -p "$dist"
mv "$tmp/main.js" "$target"
echo "chatora: installed the server published for $tag" >&2
