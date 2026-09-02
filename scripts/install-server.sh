#!/bin/sh
# The `build` step of the plugin spec.
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

tag=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$tag" ]; then
  build_from_source
  exit 0
fi

base="${CHATORA_RELEASE_BASE:-https://github.com/qaynam/chatora/releases/download}/$tag"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL -o "$tmp/main.js" "$base/main.js" ||
  ! curl -fsSL -o "$tmp/main.js.sha256" "$base/main.js.sha256"; then
  echo "chatora: no published server for $tag" >&2
  build_from_source
  exit 0
fi

if [ "$(sha256_of "$tmp/main.js")" != "$(cut -d' ' -f1 <"$tmp/main.js.sha256")" ]; then
  echo "chatora: checksum mismatch for $tag" >&2
  build_from_source
  exit 0
fi

mkdir -p "$dist"
mv "$tmp/main.js" "$target"
echo "chatora: installed the server published for $tag" >&2
